#pragma once

#include <string>

#include "gpu_detector.hpp"
#include "power_manager.hpp"
#include "workload_classifier.hpp"

namespace titan {

struct EnforcementResult {
    GpuTarget target = GpuTarget::Auto;
    bool power_transitioned = false;
};

class GpuEnforcer {
public:
    GpuEnforcer(GpuDetector& detector, PowerManager& power);

    EnforcementResult enforce_for_app(const std::string& wm_class);
    EnforcementResult enforce_target(GpuTarget target);

    void idle_power_off(uint32_t idle_timeout_sec);

    bool has_active_dgpu_clients() const { return active_dgpu_clients_ > 0; }
    void increment_dgpu_clients() { active_dgpu_clients_++; }
    void decrement_dgpu_clients();
    void reset_dgpu_clients() { active_dgpu_clients_ = 0; }

private:
    GpuDetector& detector_;
    PowerManager& power_;
    int active_dgpu_clients_ = 0;
};

}  // namespace titan
