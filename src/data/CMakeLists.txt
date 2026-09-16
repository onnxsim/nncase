cmake_minimum_required (VERSION 3.8)

set(SRCS dataset.cpp)

add_library(data OBJECT ${SRCS})
target_link_libraries(data PUBLIC xtensor::xtensor gsl::gsl-lite)
target_compile_definitions(data PUBLIC -DNNCASE_DLL)
# patched locally: opencv (imgcodecs/imgproc) replaced by vendored stb_image/stb_image_resize --
# see dataset.cpp's own comment for why
target_include_directories(data PRIVATE ${CMAKE_SOURCE_DIR}/third_party/stb)
set_property(TARGET data PROPERTY POSITION_INDEPENDENT_CODE ON)