cmake_minimum_required (VERSION 3.8)

set(SRCS compiler.cpp
         simulator.cpp)

add_library(nncase SHARED ${SRCS})
target_link_libraries(nncase PRIVATE data ir kernels evaluator importer schedule codegen codegen_stackvm transforms targets simulator simulator_stackvm plugin)
if (ENABLE_TFLITE_IMPORTER)  # patched locally: see the top-level CMakeLists.txt option comment
    target_link_libraries(nncase PRIVATE tflite_importer)
endif ()
target_link_libraries(nncase PUBLIC gsl::gsl-lite xtensor::xtensor mpark_variant::mpark_variant)
target_compile_definitions(nncase PRIVATE -DNNCASE_DLL)
target_compile_definitions(nncase PUBLIC -DNNCASE_SHARED_LIBS)
target_link_libraries(nncase PRIVATE magic_enum::magic_enum fmt::fmt)

# patched locally: dropped EXPORT nncaseTargets / the installed cmake package config --
# this build only ever consumes the `nncase` target in-tree (our own WASM/embind wrapper
# links against it directly in the same CMake project), and exporting it would require
# every OBJECT library it privately links (data/ir/kernels/...) to also be in the export
# set, which only became a hard error once Emscripten forced this from SHARED to STATIC
install(TARGETS nncase
        COMPONENT nncase-runtime
        ARCHIVE DESTINATION lib
        LIBRARY DESTINATION lib
        RUNTIME DESTINATION bin
        INCLUDES DESTINATION include
)
