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
#pragma once
#include <memory>
#include <nncase/targets/target.h>
#include <string_view>

namespace nncase::plugin_loader
{
typedef target *(*target_activator_t)();

#define TARGET_ACTIVATOR_NAME create_target

NNCASE_API std::unique_ptr<target> create_target(std::string_view name);

// patched locally: dlopen-based plugin loading has no equivalent on a statically-linked
// WASM build (each target module is meant to be a separate .so, but Emscripten builds
// static-only by default, and two targets' identically-named extern "C" create_target()
// can't both be linked into one binary anyway). This registry lets whatever final
// executable/binding links a target's object code directly (see targets/k210/k210_target.h)
// register a name -> activator mapping instead of relying on dlopen; create_target() checks
// it first and only falls back to the real dlopen path if nothing was registered.
NNCASE_API void register_static_target(std::string_view name, target_activator_t activator);
}
