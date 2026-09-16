/* Copyright 2019-2021 Canaan Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "caffe/caffe_importer.h"
#include "onnx/onnx_importer.h"
#ifdef NNCASE_ENABLE_TFLITE_IMPORTER
#include "tflite/tflite_importer.h"
#endif
#include <nncase/importer/importer.h>
#include <stdexcept>

using namespace nncase;
using namespace nncase::importer;
using namespace nncase::ir;

// patched locally: TFLite import (flatbuffers-based) is optional -- see the
// ENABLE_TFLITE_IMPORTER option comment in the top-level CMakeLists.txt
#ifdef NNCASE_ENABLE_TFLITE_IMPORTER
void nncase::importer::import_tflite(ir::graph &graph, std::span<const uint8_t> model, const import_options &options, std::string &real_inlayout, std::string &real_outlayout)
{
    tflite_importer(model, graph).import(options, real_inlayout, real_outlayout);
}
#else
void nncase::importer::import_tflite(ir::graph &, std::span<const uint8_t>, const import_options &, std::string &, std::string &)
{
    throw std::runtime_error("TFLite import is disabled in this build (ENABLE_TFLITE_IMPORTER=OFF)");
}
#endif

void nncase::importer::import_onnx(ir::graph &graph, std::span<const uint8_t> model, const import_options &options, std::string &real_inlayout, std::string &real_outlayout)
{
    onnx_importer(model, graph).import(options, real_inlayout, real_outlayout);
}

void nncase::importer::import_caffe(ir::graph &graph, std::span<const uint8_t> model, std::span<const uint8_t> prototxt, std::string &real_inlayout, std::string &real_outlayout)
{
    caffe_importer(model, prototxt, graph).import(real_inlayout, real_outlayout);
}