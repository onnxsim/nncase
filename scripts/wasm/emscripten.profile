[settings]
os=Emscripten
arch=wasm
compiler=clang
compiler.version=@CLANG_VERSION@
compiler.libcxx=libc++
compiler.cppstd=20
build_type=Release

[options]

[build_requires]

[env]
CC=emcc
CXX=em++
AR=emar
RANLIB=emranlib
