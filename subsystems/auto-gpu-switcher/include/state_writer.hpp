#pragma once

#include <filesystem>
#include <string>

#include "gpu_detector.hpp"
#include "power_manager.hpp"
#include "workload_classifier.hpp"

namespace titan {

class StateWriter {
public:
    void write(const GpuDetector& detector,
               const PowerManager& power,
               GpuTarget current_target,
               const std::string& active_app);

    static std::filesystem::path state_path();

private:
    static const char* power_source_str(PowerSource ps);
    std::string last_content_;
};

}  // namespace titan
