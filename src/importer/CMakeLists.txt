cmake_minimum_required (VERSION 3.8)

if (ENABLE_TFLITE_IMPORTER)  # patched locally: see the top-level CMakeLists.txt option comment
    add_subdirectory(tflite)
endif ()
add_subdirectory(onnx)
add_subdirectory(caffe)

add_library(importer OBJECT importer.cpp)
target_include_directories(importer PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/include)

if (ENABLE_TFLITE_IMPORTER)
    target_link_libraries(importer PUBLIC tflite_importer)
    target_compile_definitions(importer PUBLIC -DNNCASE_ENABLE_TFLITE_IMPORTER)
endif ()
target_link_libraries(importer PUBLIC onnx_proto onnx_importer caffe_importer)
set_target_properties(importer PROPERTIES POSITION_INDEPENDENT_CODE ON)