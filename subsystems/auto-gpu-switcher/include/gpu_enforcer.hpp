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
    enum class ManualMode { None, ForceDgpu, ForceIgpu };

    GpuEnforcer(GpuDetector& detector, PowerManager& power);

    EnforcementResult enforce_for_app(const std::string& wm_class);
    EnforcementResult enforce_for_app_window(const std::string& wm_class, const std::string& window_addr);
    EnforcementResult enforce_target(GpuTarget target);
    EnforcementResult enforce_target_window(GpuTarget target, const std::string& window_addr);

    void idle_power_off(uint32_t idle_timeout_sec);

    bool has_active_dgpu_clients() const {
        return manual_ == ManualMode::ForceDgpu || app_dgpu_hold_ || !active_dgpu_windows_.empty();
    }
    size_t active_dgpu_client_count() const {
        return (manual_ == ManualMode::ForceDgpu ? 1u : 0u)
               + (app_dgpu_hold_ ? 1u : 0u)
               + active_dgpu_windows_.size();
    }

    bool manual_override_active() const { return manual_ != ManualMode::None; }
    ManualMode manual_mode() const { return manual_; }

    void reset_dgpu_clients();
    void clear_dgpu_windows();
    void remove_dgpu_window(const std::string& window_addr);

private:
    bool wants_dgpu_power() const;
    bool apply_power(bool power_on);
    EnforcementResult settle(EnforcementResult result, bool was_wanted);

    GpuDetector& detector_;
    PowerManager& power_;
    ManualMode manual_ = ManualMode::None;
    bool app_dgpu_hold_ = false;
    std::unordered_set<std::string> active_dgpu_windows_;
};

}  // namespace titan
