#!/usr/bin/env bash
# Cross-compile nncase's compiler (K210 + cpu targets, no Vulkan, no TFLite
# importer, no Python bindings, no runtime) to wasm32-emscripten, producing a
# `ncc.js` + `ncc.wasm` that does a real ONNX -> kmodel compile (import, PTQ
# calibration, target codegen -- see this branch's own commits for what
# changed and why). Runnable from both Node and a browser page: see "browser
# vs. Node" below. See .github/workflows/build-wasm.yml for how this gets run
# and published; this script has no CI-specific logic of its own so it also
# just works as a local rebuild.
#
# No conan: by the time opencv/flatbuffers/spdlog/zlib/libzippp/inja/shaderc
# are all gone (see this branch's earlier commits), what's left is seven
# header-only libraries (vendored directly under third_party/, see
# cmake/wasm-deps.cmake) plus fmt and protobuf, which this script builds
# itself with plain emcmake + ninja + `cmake --install` into
# NNCASE_WASM_DEPS_PREFIX. Nearly every real problem hit getting this build
# working the first time was conan 1.x's own machinery (the sunnycase
# remote's broken search endpoint, settings.yml's compiler-version enum, the
# two-profile cross-compilation dance, a local HTTP server to substitute
# source tarballs) rather than the dependencies themselves -- once the
# dependency graph is this small, going straight to each project's own
# upstream CMakeLists.txt is both less code and less fragile.
#
# No sudo/apt-get install either, and no deb-src toggle: both were a real
# problem in a sandboxed environment with no passwordless sudo (apt-get
# install/`sed`-ing sources.list.d needs root; a restricted CI runner or dev
# container can easily have the same limitation). `apt-get download` -- a
# plain fetch of a .deb into the cwd -- needs no root at all, so protoc and
# its two runtime libs (libprotoc/libprotobuf, both versioned .so files
# protoc dlopens) come from there instead, extracted with `dpkg-deb -x`
# (also no root). fmt/protobuf's actual *source* (built for wasm32 below)
# comes straight from each project's own GitHub release tarball rather than
# `apt-get source`, pinned to the exact versions the protoc/libprotobuf .debs
# above are (so protoc's generated-code conventions still match the
# wasm32-compiled libprotobuf runtime exactly) -- bump PROTOBUF_DEB_VERSION/
# PROTOBUF_SRC_VERSION/FMT_VERSION together if the target Ubuntu release's
# protobuf-compiler package version ever moves.
#
# Two other real gaps this still works around, neither sudo/conan-specific:
# - protoc, run at build time to generate C++ from third_party/onnx/onnx.proto,
#   must be a *native* binary (it runs during the build, on the build
#   machine) even though libprotobuf itself is cross-compiled for wasm32.
# - Emscripten builds static-only by default (no real ELF-style shared
#   objects), which this branch's own commits already adapt nncase's
#   target-plugin loading for (see "Register k210/cpu targets statically").
#
# Browser vs. Node: this build intentionally does NOT use `-sNODERAWFS=1`
# (which was here in an earlier revision of this script) -- that mode makes
# the compiled module read/write the *host* filesystem directly through
# Node's own `fs`, which only exists in Node and can't run in a browser at
# all. Without it, `ncc.js`/`ncc.wasm` use Emscripten's normal in-memory FS
# (MEMFS) and behave identically in both environments: the caller writes the
# input ONNX (and optional calibration dataset) into that virtual FS with
# `Module.FS.writeFile(...)`, drives the existing CLI via
# `Module.callMain(["compile", "-i", "onnx", ...])` exactly as documented in
# `ncc --help`, and reads the output kmodel back with `Module.FS.readFile(...)`.
# `FS`/`callMain` don't need `-sNODERAWFS` but aren't attached to the
# returned Module object by default either (as of this emsdk version) --
# `-sFORCE_FILESYSTEM=1` alone builds MEMFS in but doesn't export it, hence
# the explicit `-sEXPORTED_RUNTIME_METHODS=FS,callMain,getExceptionMessage`.
# `getExceptionMessage` + `-sASSERTIONS=1` matter for real debugging: without
# them, an uncaught C++ exception (e.g. a malformed ONNX input) surfaces to
# JS as a bare pointer integer instead of the actual `what()` string --
# confirmed directly while testing this build against a real ONNX file that
# was missing shape-inference `value_info` (a real, separately-documented
# nncase importer requirement, not a wasm-specific issue -- see
# onnxsim/onnxsim's scripts/onnx_to_kmodel.py).
# -- see tools/onnx-k210-flash/web/ncc_wasm.mjs in onnxsim/onnxsim for the
# wrapper that does this from a real page, and its own README for what's
# been verified this way so far.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)
WORK_DIR=$(mkdir -p "${WASM_BUILD_WORK_DIR:-$REPO_ROOT/.wasm-build}" && cd "${WASM_BUILD_WORK_DIR:-$REPO_ROOT/.wasm-build}" && pwd)
BUILD_DIR="$REPO_ROOT/build-wasm"
DEPS_PREFIX="$WORK_DIR/deps-prefix"
EMSCRIPTEN_VERSION=${EMSCRIPTEN_VERSION:-5.0.0}

# Must match the actual protobuf-compiler/libprotoc/libprotobuf package
# version available via `apt-get download` on the build machine (checked
# directly against a real Ubuntu apt-cache when this was written -- see the
# comment block above).
PROTOBUF_DEB_VERSION=${PROTOBUF_DEB_VERSION:-3.21.12-15ubuntu1}
# The source tarball's own version string (embedded in the archive's
# filename and top-level directory) vs. the GitHub release tag that hosts
# it -- protobuf's releases page names the tag "v21.12" but keeps the
# legacy "protobuf-cpp-3.21.12.tar.gz" filename/dirname for this era of
# releases; these two must both match PROTOBUF_DEB_VERSION's "3.21.12" above.
PROTOBUF_SRC_VERSION=${PROTOBUF_SRC_VERSION:-3.21.12}
PROTOBUF_RELEASE_TAG=${PROTOBUF_RELEASE_TAG:-v21.12}
# NOT the apt candidate version (10.1.1) an earlier revision of this script
# used -- that version's FMT_STRING/basic_format_string consteval machinery
# fails to compile under this build's emsdk-provided clang (resolves to a
# pre-release "23.0.0git" snapshot as of this writing): "call to consteval
# function ... is not a constant expression", inside fmt's own src/os.cc and
# format-inl.h, before nncase's code is even reached. Confirmed by trying
# the apt version first and hitting this for real, not assumed. 11.1.4 is
# well past fmt's own consteval-related fixes (see fmt's CHANGES.rst) and
# builds cleanly against the same toolchain.
FMT_VERSION=${FMT_VERSION:-11.1.4}

echo "== emsdk $EMSCRIPTEN_VERSION =="
if [ ! -d "$WORK_DIR/emsdk" ]; then
    git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$WORK_DIR/emsdk"
fi
"$WORK_DIR/emsdk/emsdk" install "$EMSCRIPTEN_VERSION"
"$WORK_DIR/emsdk/emsdk" activate "$EMSCRIPTEN_VERSION"
# shellcheck disable=SC1091
source "$WORK_DIR/emsdk/emsdk_env.sh"

echo "== native protoc (no sudo: apt-get download + dpkg-deb -x, not apt-get install) =="
APT_DL_DIR="$WORK_DIR/apt-dl"
mkdir -p "$APT_DL_DIR"
(
    cd "$APT_DL_DIR"
    for pkg in protobuf-compiler libprotoc32t64 libprotobuf32t64; do
        [ -f "${pkg}_${PROTOBUF_DEB_VERSION}_amd64.deb" ] || apt-get download "${pkg}=${PROTOBUF_DEB_VERSION}"
        dpkg-deb -x "${pkg}_${PROTOBUF_DEB_VERSION}_amd64.deb" extracted
    done
)
PROTOC="$APT_DL_DIR/extracted/usr/bin/protoc"
PROTOC_LIBDIR="$APT_DL_DIR/extracted/usr/lib/x86_64-linux-gnu"
export LD_LIBRARY_PATH="$PROTOC_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
echo "native protoc: $PROTOC ($("$PROTOC" --version))"

SRC_DL_DIR="$WORK_DIR/src-dl"
mkdir -p "$SRC_DL_DIR"
fetch_tarball() {
    # fetch_tarball <url> <dest-dir> -- GitHub release/archive tarballs
    # unpack to a single top-level directory, like apt source tarballs did.
    local url="$1" dest="$2"
    local tarball="$SRC_DL_DIR/$(basename "$url")"
    [ -f "$tarball" ] || curl -sL -o "$tarball" "$url"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar xf "$tarball" -C "$dest" --strip-components=1
}

mkdir -p "$DEPS_PREFIX"

echo "== fmt =="
FMT_SRC="$WORK_DIR/fmt-src"
FMT_BUILD="$WORK_DIR/fmt-build"
fetch_tarball "https://github.com/fmtlib/fmt/archive/refs/tags/${FMT_VERSION}.tar.gz" "$FMT_SRC"
# Real bug in fmt ${FMT_VERSION} itself, confirmed directly (not assumed):
# format.h's detail::allocator uses bare malloc/free but only includes
# base.h, which -- checked directly -- declares neither; some other fmt
# header (std.h) does '#include <cstdlib>' but format.h never pulls it in.
# This compiles by accident wherever some other already-included standard
# header happens to transitively drag in <cstdlib> (true of most libstdc++
# setups); Emscripten's libc++ headers here don't do that, so it fails
# outright: "use of undeclared identifier 'malloc'". Patch it directly
# rather than work around it elsewhere, since the fix is this obviously
# correct and upstream-appropriate.
grep -q '#include <cstdlib>' "$FMT_SRC/include/fmt/format.h" || \
    sed -i '0,/#include "base.h"/s//#include <cstdlib>\n#include "base.h"/' "$FMT_SRC/include/fmt/format.h"
rm -rf "$FMT_BUILD"
emcmake cmake -S "$FMT_SRC" -B "$FMT_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=20 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DFMT_DOC=OFF -DFMT_TEST=OFF -DFMT_INSTALL=ON -DFMT_OS=ON \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX"
ninja -C "$FMT_BUILD"
cmake --install "$FMT_BUILD"

echo "== protobuf (native protoc already extracted above; this build is libprotobuf only) =="
PROTOBUF_SRC="$WORK_DIR/protobuf-src"
PROTOBUF_BUILD="$WORK_DIR/protobuf-build"
fetch_tarball "https://github.com/protocolbuffers/protobuf/releases/download/${PROTOBUF_RELEASE_TAG}/protobuf-cpp-${PROTOBUF_SRC_VERSION}.tar.gz" "$PROTOBUF_SRC"
rm -rf "$PROTOBUF_BUILD"
emcmake cmake -S "$PROTOBUF_SRC" -B "$PROTOBUF_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=20 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=OFF -Dprotobuf_BUILD_TESTS=OFF \
    -Dprotobuf_BUILD_PROTOC_BINARIES=ON -Dprotobuf_DISABLE_RTTI=OFF \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX"
ninja -C "$PROTOBUF_BUILD"
cmake --install "$PROTOBUF_BUILD"

echo "== configure nncase =="
mkdir -p "$BUILD_DIR"
emcmake cmake -G Ninja \
    -DNNCASE_NO_CONAN=ON \
    -DNNCASE_WASM_DEPS_PREFIX="$DEPS_PREFIX" \
    -DBUILDING_RUNTIME=OFF \
    -DENABLE_OPENMP=OFF \
    -DENABLE_HALIDE=OFF \
    -DBUILD_PYTHON_BINDING=OFF \
    -DENABLE_VULKAN_COMPILER=OFF \
    -DENABLE_TFLITE_IMPORTER=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_BENCHMARK=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=20 \
    -DProtobuf_PROTOC_EXECUTABLE="$PROTOC" \
    -DCMAKE_EXE_LINKER_FLAGS="-sNO_DISABLE_EXCEPTION_CATCHING -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=4294967296 -sEXIT_RUNTIME=0 -sFORCE_FILESYSTEM=1 -sMODULARIZE=1 -s'EXPORT_NAME=\"create_ncc\"' -sINVOKE_RUN=0 -sEXPORTED_RUNTIME_METHODS=FS,callMain,getExceptionMessage -sASSERTIONS=1" \
    -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$BUILD_DIR/bin" \
    -S "$REPO_ROOT" -B "$BUILD_DIR"

echo "== build =="
ninja -C "$BUILD_DIR" ncc

echo "== done: $BUILD_DIR/bin/ncc.js + $BUILD_DIR/bin/ncc.wasm =="
