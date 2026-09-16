#!/usr/bin/env bash
# Cross-compile nncase's compiler (K210 + cpu targets, no Vulkan, no TFLite
# importer, no Python bindings, no runtime) to wasm32-emscripten, producing a
# Node.js-runnable `ncc.js` + `ncc.wasm` that does a real ONNX -> kmodel
# compile (import, PTQ calibration, target codegen -- see this branch's own
# commits for what changed and why). See .github/workflows/build-wasm.yml for
# how this gets run and published; this script has no CI-specific logic of
# its own so it also just works as a local rebuild.
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
# Two other real gaps this still works around, neither conan-specific:
# - protoc, run at build time to generate C++ from third_party/onnx/onnx.proto,
#   must be a *native* binary (it runs during the build, on the build
#   machine) even though libprotobuf itself is cross-compiled for wasm32.
#   `apt install protobuf-compiler` gives a native one at the exact same
#   version (3.21.12) substituted in as protobuf's source below, so
#   generated-code conventions match exactly.
# - Emscripten builds static-only by default (no real ELF-style shared
#   objects), which this branch's own commits already adapt nncase's
#   target-plugin loading for (see "Register k210/cpu targets statically").
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)
WORK_DIR=$(mkdir -p "${WASM_BUILD_WORK_DIR:-$REPO_ROOT/.wasm-build}" && cd "${WASM_BUILD_WORK_DIR:-$REPO_ROOT/.wasm-build}" && pwd)
BUILD_DIR="$REPO_ROOT/build-wasm"
DEPS_PREFIX="$WORK_DIR/deps-prefix"
EMSCRIPTEN_VERSION=${EMSCRIPTEN_VERSION:-5.0.0}

SUDO=""
if [ "$(id -u)" != "0" ]; then
    SUDO="sudo"
fi

echo "== emsdk $EMSCRIPTEN_VERSION =="
if [ ! -d "$WORK_DIR/emsdk" ]; then
    git clone --depth 1 https://github.com/emscripten-core/emsdk.git "$WORK_DIR/emsdk"
fi
"$WORK_DIR/emsdk/emsdk" install "$EMSCRIPTEN_VERSION"
"$WORK_DIR/emsdk/emsdk" activate "$EMSCRIPTEN_VERSION"
# shellcheck disable=SC1091
source "$WORK_DIR/emsdk/emsdk_env.sh"

echo "== apt sources: native protoc + fmt/protobuf upstream tarballs =="
if ! apt-cache policy 2>/dev/null | grep -q deb-src; then
    $SUDO sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
    $SUDO apt-get update -qq
fi
$SUDO apt-get install -y --no-install-recommends protobuf-compiler
PROTOC=$(command -v protoc)
echo "native protoc: $PROTOC ($("$PROTOC" --version))"

APT_SRC_DIR="$WORK_DIR/apt-src"
mkdir -p "$APT_SRC_DIR"
(cd "$APT_SRC_DIR" && apt-get source --download-only fmtlib protobuf)

extract_one() {
    # extract_one <glob-pattern> <dest-dir> -- apt source tarballs unpack to
    # a single top-level directory already named <name>-<version>.
    local pattern="$1" dest="$2"
    rm -rf "$dest"
    mkdir -p "$dest"
    local tarball
    tarball=$(compgen -G "$APT_SRC_DIR/$pattern" | head -1)
    tar xf "$tarball" -C "$dest" --strip-components=1
}

mkdir -p "$DEPS_PREFIX"

echo "== fmt =="
FMT_SRC="$WORK_DIR/fmt-src"
FMT_BUILD="$WORK_DIR/fmt-build"
extract_one 'fmtlib_*.orig.tar*' "$FMT_SRC"
rm -rf "$FMT_BUILD"
emcmake cmake -S "$FMT_SRC" -B "$FMT_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=20 -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DFMT_DOC=OFF -DFMT_TEST=OFF -DFMT_INSTALL=ON -DFMT_OS=ON \
    -DCMAKE_INSTALL_PREFIX="$DEPS_PREFIX"
ninja -C "$FMT_BUILD"
cmake --install "$FMT_BUILD"

echo "== protobuf (native protoc already installed above; this build is libprotobuf/libprotoc only) =="
PROTOBUF_SRC="$WORK_DIR/protobuf-src"
PROTOBUF_BUILD="$WORK_DIR/protobuf-build"
extract_one 'protobuf_*.orig.tar*' "$PROTOBUF_SRC"
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
emcmake cmake \
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
    -DCMAKE_EXE_LINKER_FLAGS="-sNO_DISABLE_EXCEPTION_CATCHING -sNODERAWFS=1" \
    -DCMAKE_RUNTIME_OUTPUT_DIRECTORY="$BUILD_DIR/bin" \
    -S "$REPO_ROOT" -B "$BUILD_DIR"

echo "== build =="
ninja -C "$BUILD_DIR" ncc

echo "== done: $BUILD_DIR/bin/ncc.js + $BUILD_DIR/bin/ncc.wasm =="
