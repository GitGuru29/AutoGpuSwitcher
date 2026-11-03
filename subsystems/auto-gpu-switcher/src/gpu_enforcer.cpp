#include "gpu_enforcer.hpp"

#include <iostream>

#include "config.hpp"

namespace titan {

GpuEnforcer::GpuEnforcer(GpuDetector& detector, PowerManager& power)
    : detector_(detector), power_(power) {}

bool GpuEnforcer::wants_dgpu_power() const {
    if (manual_ == ManualMode::ForceDgpu) return true;
    if (manual_ == ManualMode::ForceIgpu) return false;
    return app_dgpu_hold_ || !active_dgpu_windows_.empty();
}

bool GpuEnforcer::apply_power(bool power_on) {
    auto dgpu = detector_.find_dgpu();
    if (!dgpu) return false;
    return power_on ? power_.power_on_dgpu(dgpu->pci_addr)
                    : power_.power_auto_dgpu(dgpu->pci_addr);
}

EnforcementResult GpuEnforcer::settle(EnforcementResult result, bool was_wanted) {
    const bool wanted = wants_dgpu_power();
    if (wanted != was_wanted) {
        result.power_transitioned = apply_power(wanted);
    }
    return result;
}

EnforcementResult GpuEnforcer::enforce_for_app(const std::string& wm_class) {
    auto& cfg = Config::instance();
    auto rule = cfg.classify_app(wm_class);

    Classifier classifier;
    auto target = classifier.classify_with_power(
        Classifier::string_to_target(rule), power_.is_on_battery());

    const bool was_wanted = wants_dgpu_power();
    app_dgpu_hold_ = (target == GpuTarget::DGPU);

    auto result = settle(EnforcementResult{target, false}, was_wanted);
    std::cout << "[enforcer] app -> " << Classifier::target_to_string(target) << "\n";
    return result;
}

EnforcementResult GpuEnforcer::enforce_for_app_window(const std::string& wm_class, const std::string& window_addr) {
    auto& cfg = Config::instance();
    auto rule = cfg.classify_app(wm_class);

    Classifier classifier;
    auto target = classifier.classify_with_power(
        Classifier::string_to_target(rule), power_.is_on_battery());

    return enforce_target_window(target, window_addr);
}

EnforcementResult GpuEnforcer::enforce_target(GpuTarget target) {
    const bool was_wanted = wants_dgpu_power();

    switch (target) {
        case GpuTarget::DGPU:
            manual_ = ManualMode::ForceDgpu;
            break;
        case GpuTarget::IGPU:
            manual_ = ManualMode::ForceIgpu;
            app_dgpu_hold_ = false;
            break;
        case GpuTarget::Auto:
            manual_ = ManualMode::None;
            break;
    }

    auto result = settle(EnforcementResult{target, false}, was_wanted);
    std::cout << "[enforcer] manual -> " << Classifier::target_to_string(target) << "\n";
    return result;
}

EnforcementResult GpuEnforcer::enforce_target_window(GpuTarget target, const std::string& window_addr) {
    if (window_addr.empty()) {
        return enforce_target(target);
    }

    const bool was_wanted = wants_dgpu_power();

    if (target == GpuTarget::DGPU) {
        active_dgpu_windows_.insert(window_addr);
    } else {
        active_dgpu_windows_.erase(window_addr);
    }

    auto result = settle(EnforcementResult{target, false}, was_wanted);
    std::cout << "[enforcer] app (" << window_addr << ") -> " << Classifier::target_to_string(target) << "\n";
    return result;
}

void GpuEnforcer::remove_dgpu_window(const std::string& window_addr) {
    if (window_addr.empty()) return;
    if (active_dgpu_windows_.erase(window_addr) == 0) return;

    const bool was_wanted = wants_dgpu_power();
    settle(EnforcementResult{GpuTarget::Auto, false}, was_wanted);
}

void GpuEnforcer::clear_dgpu_windows() {
    if (active_dgpu_windows_.empty()) return;

    const bool was_wanted = wants_dgpu_power();
    active_dgpu_windows_.clear();
    settle(EnforcementResult{GpuTarget::Auto, false}, was_wanted);
    std::cout << "[enforcer] cleared stale dGPU window tracking\n";
}

void GpuEnforcer::reset_dgpu_clients() {
    manual_ = ManualMode::None;
    app_dgpu_hold_ = false;
    active_dgpu_windows_.clear();
}

void GpuEnforcer::idle_power_off(uint32_t idle_timeout_sec) {
    if (has_active_dgpu_clients()) return;

    auto dgpu = detector_.find_dgpu();
    if (!dgpu) return;

    auto current = power_.get_pci_power(dgpu->pci_addr);
    if (current == PowerState::On) {
        power_.power_auto_dgpu(dgpu->pci_addr);
        std::cout << "[enforcer] idle -> auto after " << idle_timeout_sec << "s\n";
    }
}

}  // namespace titan
