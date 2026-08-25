#pragma once

#include <string>

#include "gpu_detector.hpp"
#include "power_manager.hpp"
#include "workload_classifier.hpp"

#include <unordered_set>

namespace titan {

struct EnforcementResult {
    GpuTarget target = GpuTarget::Auto;
    bool power_transitioned = false;
};

class GpuEnforcer {
public:
    GpuEnforcer(GpuDetector& detector, PowerManager& power);

    EnforcementResult enforce_for_app(const std::string& wm_class);
    EnforcementResult enforce_for_app_window(const std::string& wm_class, const std::string& window_addr);
    EnforcementResult enforce_target(GpuTarget target);
    EnforcementResult enforce_target_window(GpuTarget target, const std::string& window_addr);

    void idle_power_off(uint32_t idle_timeout_sec);

    bool has_active_dgpu_clients() const {
        return active_dgpu_clients_ > 0 || !active_dgpu_windows_.empty();
    }
    size_t active_dgpu_client_count() const {
        return static_cast<size_t>(active_dgpu_clients_) + active_dgpu_windows_.size();
    }
    void increment_dgpu_clients() { active_dgpu_clients_++; }
    void decrement_dgpu_clients();
    void remove_dgpu_window(const std::string& window_addr);
    void reset_dgpu_clients() {
        active_dgpu_clients_ = 0;
        active_dgpu_windows_.clear();
    }

private:
    GpuDetector& detector_;
    PowerManager& power_;
    int active_dgpu_clients_ = 0;
    std::unordered_set<std::string> active_dgpu_windows_;
};

}  // namespace titan
