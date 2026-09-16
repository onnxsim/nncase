find_package(mpark_variant REQUIRED)
find_package(gsl-lite REQUIRED)
if (ENABLE_OPENMP)
    find_package(OpenMP COMPONENTS CXX REQUIRED)
endif ()

if (ENABLE_VULKAN_RUNTIME)  # patched locally: matches conanfile.py's equivalent fix -- see its comment
    find_package(Vulkan REQUIRED)
endif ()

if (NOT BUILDING_RUNTIME)
    if (ENABLE_TFLITE_IMPORTER)  # patched locally: see the top-level CMakeLists.txt option comment -- flatbuffers is only used to parse .tflite; ONNX import (protobuf) and kmodel's own hand-rolled writer never touch it
        find_package(flatbuffers REQUIRED)
        if(NOT CONAN_EXPORTED)
            set(FLATBUFFERS_FLATC_EXECUTABLE ${flatbuffers_LIB_DIRS}/../bin/flatc)
        endif()
    endif ()
    find_package(fmt REQUIRED)
    find_package(lyra REQUIRED)
    find_package(magic_enum REQUIRED)
    find_package(nlohmann_json REQUIRED)
    # patched locally: OpenCV dropped -- src/data/dataset.cpp now uses vendored
    # stb_image/stb_image_resize instead (see that file's own comment)
    find_package(Protobuf REQUIRED)
    find_package(xtensor REQUIRED)
    # patched locally: spdlog dropped -- see conanfile.py's matching comment
    if (ENABLE_VULKAN_COMPILER)  # patched locally: see the top-level CMakeLists.txt option comment -- these three (and libzip, transitively via libzippp) are only used by modules/vulkan/src/codegen/templates
        find_package(libzip REQUIRED)
        if(NOT CONAN_EXPORTED)
            set(LIBZIP_ZIPTOOL_EXECUTABLE ${libzip_zip_LIB_DIRS}/../bin/ziptool)
        endif()
        find_package(libzippp REQUIRED)
        find_package(inja REQUIRED)
        find_package(shaderc REQUIRED)
    endif ()
endif ()

if (BUILD_TESTING)
    find_package(GTest REQUIRED)
endif ()

if (ENABLE_HALIDE)
    find_package(hkg REQUIRED)
endif ()