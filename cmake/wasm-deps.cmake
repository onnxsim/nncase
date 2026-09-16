# Resolves the wasm32 compiler build's dependencies without conan. See
# scripts/build-wasm.sh's own comment for why: conan 1.x's own machinery
# (the sunnycase remote's broken search endpoint, settings.yml's compiler
# version enum, the two-profile cross-compilation dance, a local HTTP
# server to substitute source tarballs) was the actual source of nearly
# every real build issue hit getting this working -- not the dependencies
# themselves, which by this point are just seven header-only libraries plus
# fmt and protobuf.
#
# Provides the exact same target names cmake/dependencies.cmake's
# find_package() calls would have (gsl::gsl-lite, mpark_variant::mpark_variant,
# bfg::lyra, magic_enum::magic_enum, nlohmann_json::nlohmann_json,
# xtensor::xtensor, fmt::fmt, protobuf::libprotobuf, protobuf::libprotoc), so
# nothing else in the tree needs to change to use this instead. Only covers
# what BUILDING_RUNTIME=OFF with vulkan_runtime/vulkan_compiler/
# tflite_importer/halide/openmp/tests all OFF actually needs (i.e. this
# build) -- flipping any of those back on with NNCASE_NO_CONAN=ON needs
# this file extended to match, same as dependencies.cmake would.
#
# Two provisioning strategies, matching how each dependency actually got here:
# - The seven header-only libraries are vendored as source directly under
#   third_party/ -- no build step, no network fetch at configure time, just
#   a copy of upstream's own include/ directory (see each's own
#   third_party/<name>/NOTICE for provenance/license).
# - fmt and protobuf are real from-source builds, done by
#   scripts/build-wasm.sh via their own upstream CMakeLists.txt (using apt's
#   own source packages, same as when this went through conan -- just
#   without conan wrapping the same steps) and installed into
#   NNCASE_WASM_DEPS_PREFIX. protobuf specifically is wired up via CMake's
#   own bundled FindProtobuf.cmake module (pre-seeding the cache variables
#   it searches for so it uses these instead of searching the host) rather
#   than a hand-built imported target, because third_party/onnx and
#   src/importer/caffe call its protobuf_generate()/protobuf_generate_cpp()
#   helper functions, which only become defined as a side effect of that
#   module being processed.

if (NOT DEFINED NNCASE_WASM_DEPS_PREFIX)
    message(FATAL_ERROR "NNCASE_NO_CONAN requires -DNNCASE_WASM_DEPS_PREFIX=<path> (see scripts/build-wasm.sh)")
endif ()

set(_nncase_third_party ${CMAKE_CURRENT_LIST_DIR}/../third_party)

function(_nncase_header_only_target plain_name alias_name include_subdir)
    # add_library() can't create a "::"-namespaced target directly (CMake
    # reserves that syntax for ALIAS/imported targets) -- define it under a
    # plain name and alias that to the namespaced name everything else expects.
    add_library(${plain_name} INTERFACE)
    # SYSTEM (-isystem, not -I): matches how conan's own generators exposed these
    # (conan_basic_setup() used -isystem for every dependency's include dir), which
    # is load-bearing here, not cosmetic -- nncase's own -Werror trips on warnings
    # inside e.g. xtensor's headers otherwise (real, hit while testing this change).
    target_include_directories(${plain_name} SYSTEM INTERFACE ${_nncase_third_party}/${include_subdir}/include)
    add_library(${alias_name} ALIAS ${plain_name})
endfunction()

_nncase_header_only_target(gsl-lite-headers gsl::gsl-lite gsl-lite)
_nncase_header_only_target(mpark-variant-headers mpark_variant::mpark_variant mpark-variant)
_nncase_header_only_target(lyra-headers bfg::lyra lyra)
_nncase_header_only_target(magic-enum-headers magic_enum::magic_enum magic_enum)
_nncase_header_only_target(nlohmann-json-headers nlohmann_json::nlohmann_json nlohmann_json)
_nncase_header_only_target(xtl-headers xtl::xtl xtl)

add_library(xtensor-headers INTERFACE)
target_include_directories(xtensor-headers SYSTEM INTERFACE ${_nncase_third_party}/xtensor/include)
target_link_libraries(xtensor-headers INTERFACE xtl::xtl)
add_library(xtensor::xtensor ALIAS xtensor-headers)

add_library(fmt::fmt STATIC IMPORTED)
set_target_properties(fmt::fmt PROPERTIES
    IMPORTED_LOCATION ${NNCASE_WASM_DEPS_PREFIX}/lib/libfmt.a
    INTERFACE_INCLUDE_DIRECTORIES ${NNCASE_WASM_DEPS_PREFIX}/include
    INTERFACE_SYSTEM_INCLUDE_DIRECTORIES ${NNCASE_WASM_DEPS_PREFIX}/include
)

# Module (not CONFIG) mode, pre-seeded so it uses this wasm32 build instead of
# searching the host -- see this file's own header comment for why this goes
# through FindProtobuf.cmake at all instead of a plain imported target.
set(Protobuf_INCLUDE_DIR ${NNCASE_WASM_DEPS_PREFIX}/include CACHE PATH "" FORCE)
set(Protobuf_LIBRARY ${NNCASE_WASM_DEPS_PREFIX}/lib/libprotobuf.a CACHE FILEPATH "" FORCE)
set(Protobuf_PROTOC_LIBRARY ${NNCASE_WASM_DEPS_PREFIX}/lib/libprotoc.a CACHE FILEPATH "" FORCE)
# Protobuf_PROTOC_EXECUTABLE is deliberately left to the caller (-D on the
# command line, see scripts/build-wasm.sh): it must be a *native* protoc that
# can run on the build machine, not this wasm32 libprotobuf/libprotoc pair.
find_package(Protobuf REQUIRED)
