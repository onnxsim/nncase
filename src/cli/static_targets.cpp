/* patched locally: registers the k210 target directly instead of relying on
 * plugin_loader's dlopen-based plugin discovery, which has no equivalent on a
 * statically-linked WASM build. See the register_static_target() comment in
 * include/nncase/plugin_loader.h for why. Only linked in for Emscripten builds
 * (see src/cli/CMakeLists.txt).
 */
#include <cpu_target.h>
#include <k210_target.h>
#include <nncase/plugin_loader.h>
#include <nncase/targets/target.h>

namespace
{
struct static_target_registrar
{
    static_target_registrar()
    {
        nncase::plugin_loader::register_static_target("k210", []() -> nncase::target * {
            return new nncase::targets::k210_target();
        });
        nncase::plugin_loader::register_static_target("cpu", []() -> nncase::target * {
            return new nncase::targets::cpu_target();
        });
    }
} g_static_target_registrar;
}
