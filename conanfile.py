# Copyright 2019-2021 Canaan Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# pylint: disable=invalid-name, unused-argument, import-outside-toplevel

from conans import ConanFile, CMake, tools


class nncaseConan(ConanFile):
    settings = "os", "compiler", "build_type", "arch"
    generators = "cmake", "cmake_find_package", "cmake_paths"
    options = {
        "shared": [True, False],
        "fPIC": [True, False],
        "runtime": [True, False],
        "tests": [True, False],
        "halide": [True, False],
        "python": [True, False],
        "vulkan_runtime": [True, False],
        "vulkan_compiler": [True, False],  # patched locally: gates libzippp/inja/shaderc (and transitively glslang/spirv-*), which src/ only uses from modules/vulkan/src/codegen/templates -- unused by the k210/cpu compiler path
        "tflite_importer": [True, False],  # patched locally: gates flatbuffers, which src/ only uses to parse .tflite -- ONNX import (protobuf) and kmodel's own hand-rolled writer never touch it
        "openmp": [True, False]
    }
    default_options = {
        "shared": False,
        "fPIC": True,
        "runtime": False,
        "tests": False,
        "halide": True,
        "python": True,
        "vulkan_runtime": True,
        "vulkan_compiler": True,
        "tflite_importer": True,
        "openmp": True
    }

    def requirements(self):
        self.requires('gsl-lite/0.37.0')
        self.requires('mpark-variant/1.4.0')
        if self.options.halide:
            self.requires('hkg/0.0.1')  # patched locally: not on any reachable remote, and unused for k210 (verified: zero usages under src/, and halide auto-disables for non-x86_64 in configure() below anyway)
        if self.options.tests:
            self.requires('gtest/1.10.0')

        if self.options.python:
            self.requires('pybind11/2.6.1')

        if not self.options.runtime:
            if self.options.tflite_importer:  # patched locally: see the tflite_importer option comment above
                self.requires('flatbuffers/2.0.0')
            self.requires('fmt/7.1.3')
            self.requires('lyra/1.5.0')
            self.requires('magic_enum/0.9.6')  # patched locally: 0.7.0's is_valid() SFINAE trips an ill-formed-non-type-template-argument error on out-of-range enum values under Clang 23's stricter converted-constant-expression rules; header-only API is unchanged, so just taking a modern release sidesteps the bug
            self.requires('nlohmann_json/3.9.1')
            # patched locally: opencv dropped -- src/data/dataset.cpp now uses vendored
            # stb_image/stb_image_resize instead of opencv's imgcodecs/imgproc, which also
            # drops opencv's own from-source dependency chain (libjpeg-turbo/libpng/jasper)
            self.requires('protobuf/3.17.1')
            self.requires('xtensor/0.21.5')
            self.requires('spdlog/1.8.2')
            # patched locally: zlib dropped -- verified zero direct usages under src/include/modules/targets;
            # it was an unused direct requirement (dependencies.cmake never calls find_package(ZLIB) either)
            if self.options.vulkan_compiler:  # patched locally: see the vulkan_compiler option comment above
                self.requires('libzippp/5.0-1.8.0')
                self.requires('inja/3.2.0')
                self.requires('shaderc/2021.1')
            if self.options.tests:
                self.requires('gtest/1.10.0')

        if self.options.vulkan_runtime:  # patched locally: vulkan-loader has no wasm32 build and (verified: zero usages under src/) nncase's own compiler code never calls into Vulkan directly -- only its (disabled here) vulkan_runtime backend does
            self.requires('vulkan-headers/1.2.182')
            self.requires('vulkan-loader/1.2.182')

    def build_requirements(self):
        pass

    def configure(self):
        min_cppstd = "14" if self.options.runtime else "20"
        tools.check_min_cppstd(self, min_cppstd)

        if self.settings.arch not in ("x86_64",):
            self.options.halide = False

        if not self.options.runtime:
            self.options["xtensor"].xsimd = False
            self.options["protobuf"].with_zlib = False  # patched locally: only needed for protobuf's gzip stream helpers, which nncase's ONNX import (plain ParseFromArray) never calls; drops zlib entirely now that opencv is gone too
            if self.options.vulkan_compiler:  # patched locally: libzip only enters the graph via libzippp now
                self.options["libzip"].with_bzip2 = False
                self.options["libzip"].with_zstd = False
                self.options["libzip"].crypto = False

        if self.options.vulkan_runtime:  # patched locally: vulkan-loader has no wasm32 build and (verified: zero usages under src/) nncase's own compiler code never calls into Vulkan directly -- only its (disabled here) vulkan_runtime backend does
            if self.settings.os == 'Linux':
                self.options["vulkan-loader"].with_wsi_xcb = False
                self.options["vulkan-loader"].with_wsi_xlib = False
                self.options["vulkan-loader"].with_wsi_wayland = False
                self.options["vulkan-loader"].with_wsi_directfb = False

    def cmake_configure(self):
        cmake = CMake(self)
        cmake.definitions['BUILDING_RUNTIME'] = self.options.runtime
        cmake.definitions['ENABLE_OPENMP'] = self.options.openmp
        cmake.definitions['ENABLE_VULKAN'] = self.options.vulkan
        cmake.definitions['ENABLE_HALIDE'] = self.options.halide
        cmake.definitions['BUILD_PYTHON_BINDING'] = self.options.python
        if self.options.runtime:
            cmake.definitions["CMAKE_CXX_STANDARD"] = 17
        cmake.configure()
        return cmake

    def build(self):
        cmake = self.cmake_configure()
        cmake.build()
