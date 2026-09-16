cmake_minimum_required (VERSION 3.8)

set(SRCS cli.cpp
         compile.cpp
         inference.cpp)

# patched locally: Emscripten builds statically only, so target plugins (normally
# separate .so files dlopen'd by name -- see plugin_loader.cpp) must be linked directly
# into the final binary and registered explicitly instead. See src/cli/static_targets.cpp
# and the register_static_target() comment in include/nncase/plugin_loader.h.
if (EMSCRIPTEN)
    list(APPEND SRCS static_targets.cpp)
endif ()

add_executable (ncc ${SRCS})
target_link_libraries(ncc PRIVATE nncase bfg::lyra)
if (EMSCRIPTEN)
    target_include_directories(ncc PRIVATE ${CMAKE_SOURCE_DIR}/targets/k210 ${CMAKE_SOURCE_DIR}/targets/cpu)
    target_link_libraries(ncc PRIVATE nncase_targets_k210 nncase_modules_k210 nncase_targets_cpu)
endif ()
if (APPLE)
    set_target_properties(ncc PROPERTIES INSTALL_RPATH "@loader_path/../lib")
else()
    set_target_properties(ncc PROPERTIES INSTALL_RPATH "$ORIGIN/../lib")
endif()
install(TARGETS ncc)
