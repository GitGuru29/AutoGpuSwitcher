#include "env_policy.hpp"

#include <cstdlib>
#include <iostream>
#include <string>

void apply_dgpu_environment() {
    setenv("__NV_PRIME_RENDER_OFFLOAD", "1", 1);
    setenv("__GLX_VENDOR_LIBRARY_NAME", "nvidia", 1);
    setenv("__VK_LAYER_NV_optimus", "NVIDIA_only", 1);

    const char* qt_plat = std::getenv("QT_QPA_PLATFORM");
    if (qt_plat && std::string(qt_plat) == "wayland;xcb") {
        setenv("QT_QPA_PLATFORM", "xcb", 1);
    }
}
