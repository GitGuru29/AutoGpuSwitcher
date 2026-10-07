#include "workload_classifier.hpp"

#include <algorithm>
#include <iostream>

#include "debug_log.hpp"

namespace titan {

GpuTarget Classifier::classify(const std::string& wm_class) const {
    return Classifier::string_to_target(wm_class);
}

GpuTarget Classifier::classify_with_power(GpuTarget rule_result, bool on_battery) const {
    if (rule_result == GpuTarget::Auto) {
        if (on_battery) {
            TITAN_DEBUG_LOG("[classifier] auto -> iGPU (battery)\n");
            return GpuTarget::IGPU;
        }
        TITAN_DEBUG_LOG("[classifier] auto -> dGPU (AC)\n");
        return GpuTarget::DGPU;
    }
    return rule_result;
}

const char* Classifier::target_to_string(GpuTarget t) {
    switch (t) {
        case GpuTarget::IGPU: return "igpu";
        case GpuTarget::DGPU: return "dgpu";
        case GpuTarget::Auto: return "auto";
    }
    return "unknown";
}

GpuTarget Classifier::string_to_target(const std::string& s) {
    std::string lower = s;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (lower == "igpu") return GpuTarget::IGPU;
    if (lower == "dgpu") return GpuTarget::DGPU;
    return GpuTarget::Auto;
}

}  // namespace titan
