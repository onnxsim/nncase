#!/usr/bin/env bash
# Cross-compile nncase's compiler (K210 + cpu targets, no Vulkan, no TFLite
# importer, no Python bindings, no runtime) to wasm32-emscripten, producing a
# Node.js-runnable `ncc.js` + `ncc.wasm` that does a real ONNX -> kmodel
# compile (import, PTQ calibration, target codegen -- see this branch's own
# commits for what changed and why). See .github/workflows/build-wasm.yml for
# how this gets run and published; this script has no CI-specific logic of
# its own so it also just works as a local rebuild.
#
# Three real, evidence-checked build gaps this works around -- see
# scripts/wasm/patch_conan.py's own docstring for the conan/source-fetching
# ones, this comment covers the rest:
#
# - protoc, run at build time to generate C++ from third_party/onnx/onnx.proto,
#   must be a *native* binary (it runs during the build, on the build
#   machine) even though libprotobuf itself is cross-compiled for wasm32 --
#   conan would otherwise hand CMake a wasm32 protoc that can't execute
#   outside a WASM runtime. `apt install protobuf-compiler` gives a native
#   one at the exact same version (3.21.12) substituted in as protobuf's
#   source below, so generated-code conventions match exactly.
# - Emscripten builds static-only by default (no real ELF-style shared
#   objects), which this branch's own commits already adapt nncase's
#   target-plugin loading for (see "Register k210/cpu targets statically").
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)
WORK_DIR=$(mkdir -p "${WASM_BUILD_WORK_DIR:-$REPO_ROOT/.wasm-build}" && cd "${WASM_BUILD_WORK_DIR:-$REPO_ROOT/.wasm-build}" && pwd)
BUILD_DIR="$REPO_ROOT/build-wasm"
EMSCRIPTEN_VERSION=${EMSCRIPTEN_VERSION:-5.0.0}
HTTP_PORT=${WASM_BUILD_HTTP_PORT:-8931}

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

# `em++ --version`'s "5.0.0" etc. is Emscripten's own release version, not
# clang's -- `-v` additionally prints the real "clang version X.Y.Z" line.
CLANG_VERSION=$(em++ -v 2>&1 | grep -oE '^clang version [0-9]+' | grep -oE '[0-9]+$')
if [ -z "$CLANG_VERSION" ]; then
    echo "could not detect emscripten's bundled clang version from 'em++ -v'" >&2
    exit 1
fi
echo "emscripten's bundled clang major version: $CLANG_VERSION"

echo "== conan (isolated venv) =="
if [ ! -d "$WORK_DIR/conan-venv" ]; then
    python3 -m venv "$WORK_DIR/conan-venv"
fi
# shellcheck disable=SC1091
source "$WORK_DIR/conan-venv/bin/activate"
pip install --quiet "conan==1.66.0" "pyyaml"
CONAN_HOME=$(conan config home)

echo "== apt sources: native protoc + fmt/protobuf/spdlog upstream tarballs =="
# deb-src isn't enabled by default on Ubuntu's newer deb822-format sources list.
if ! apt-cache policy 2>/dev/null | grep -q deb-src; then
    $SUDO sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
    $SUDO apt-get update -qq
fi
$SUDO apt-get install -y --no-install-recommends protobuf-compiler
PROTOC=$(command -v protoc)
echo "native protoc: $PROTOC ($("$PROTOC" --version))"

APT_SRC_DIR="$WORK_DIR/apt-src"
mkdir -p "$APT_SRC_DIR"
(cd "$APT_SRC_DIR" && apt-get source --download-only fmtlib protobuf spdlog)

echo "== patching conan for a wasm32 compiler build =="
for ref in "fmt/7.1.3@" "protobuf/3.17.1@" "spdlog/1.8.2@"; do
    conan download "$ref" -r conancenter --recipe
done
python3 "$SCRIPT_DIR/wasm/patch_conan.py" \
    --conan-home "$CONAN_HOME" \
    --clang-version "$CLANG_VERSION" \
    --apt-src-dir "$APT_SRC_DIR" \
    --http-port "$HTTP_PORT" \
    --spdlog-tarball-out "$WORK_DIR/spdlog-patched.tar.xz"

echo "== serving apt sources on 127.0.0.1:$HTTP_PORT =="
python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory "$APT_SRC_DIR" &
HTTP_SERVER_PID=$!
trap 'kill "$HTTP_SERVER_PID" 2>/dev/null || true' EXIT
sleep 1

PROFILE="$WORK_DIR/emscripten.profile"
sed "s/@CLANG_VERSION@/$CLANG_VERSION/" "$SCRIPT_DIR/wasm/emscripten.profile" > "$PROFILE"

echo "== conan install =="
mkdir -p "$BUILD_DIR"
conan install "$REPO_ROOT" \
    -pr:b default -pr:h "$PROFILE" \
    -o runtime=False -o tests=False -o halide=False -o python=False \
    -o vulkan_runtime=False -o vulkan_compiler=False -o tflite_importer=False -o openmp=False \
    --build=missing \
    --install-folder "$BUILD_DIR"

echo "== configure =="
cd "$BUILD_DIR"
emcmake cmake \
    -DCONAN_EXPORTED=1 \
    -DBUILDING_RUNTIME=OFF \
    -DENABLE_OPENMP=OFF \
    -DENABLE_HALIDE=OFF \
    -DBUILD_PYTHON_BINDING=OFF \
    -DENABLE_VULKAN_COMPILER=OFF \
    -DENABLE_TFLITE_IMPORTER=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_BENCHMARK=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DProtobuf_PROTOC_EXECUTABLE="$PROTOC" \
    -DCMAKE_EXE_LINKER_FLAGS="-sNO_DISABLE_EXCEPTION_CATCHING -sNODERAWFS=1" \
    "$REPO_ROOT"

echo "== build =="
ninja -C "$BUILD_DIR" ncc

echo "== done: $BUILD_DIR/bin/ncc.js + $BUILD_DIR/bin/ncc.wasm =="
