#pragma once

#include <cstdint>
#include <string>

namespace titan {

enum class GpuTarget : uint8_t {
    IGPU,
    DGPU,
    Auto,
};

class Classifier {
public:
    GpuTarget classify(const std::string& wm_class) const;
    GpuTarget classify_with_power(GpuTarget rule_result, bool on_battery) const;

    static const char* target_to_string(GpuTarget t);
    static GpuTarget string_to_target(const std::string& s);
};

}  // namespace titan
