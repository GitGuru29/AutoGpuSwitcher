#include "gpu_enforcer.hpp"

#include <iostream>

#include "config.hpp"
#include "debug_log.hpp"

namespace titan {

GpuEnforcer::GpuEnforcer(GpuDetector& detector, PowerManager& power)
    : detector_(detector), power_(power) {}

EnforcementResult GpuEnforcer::enforce_for_app(const std::string& wm_class) {
    auto& cfg = Config::instance();
    auto rule = cfg.classify_app(wm_class);

    Classifier classifier;
    auto target = classifier.classify_with_power(
        Classifier::string_to_target(rule), power_.is_on_battery());

    return enforce_target(target);
}

EnforcementResult GpuEnforcer::enforce_for_app_window(const std::string& wm_class, const std::string& window_addr) {
    auto& cfg = Config::instance();
    auto rule = cfg.classify_app(wm_class);

    Classifier classifier;
    auto target = classifier.classify_with_power(
        Classifier::string_to_target(rule), power_.is_on_battery());

    return enforce_target_window(target, window_addr);
}

EnforcementResult GpuEnforcer::enforce_target(GpuTarget target, bool idempotent) {
    EnforcementResult result;
    result.target = target;

    if (target == GpuTarget::DGPU) {
        if (!has_active_dgpu_clients()) {
            auto dgpu = detector_.find_dgpu();
            if (dgpu) {
                result.power_transitioned = power_.power_on_dgpu(dgpu->pci_addr);
            }
        }
        if (idempotent) {
            // Set semantics: `set dgpu` twice must not double-count.
            if (active_dgpu_clients_ == 0) active_dgpu_clients_ = 1;
        } else {
            active_dgpu_clients_++;
        }
    } else if (target == GpuTarget::IGPU) {
        if (idempotent) {
            // Set semantics: clear entirely (window set handled separately)
            bool had_clients = has_active_dgpu_clients();
            active_dgpu_clients_ = 0;
            if (had_clients && active_dgpu_windows_.empty()) {
                auto dgpu = detector_.find_dgpu();
                if (dgpu) {
                    result.power_transitioned = power_.power_auto_dgpu(dgpu->pci_addr);
                }
            }
        } else if (has_active_dgpu_clients()) {
            decrement_dgpu_clients();
            if (!has_active_dgpu_clients()) {
                auto dgpu = detector_.find_dgpu();
                if (dgpu) {
                    result.power_transitioned = power_.power_auto_dgpu(dgpu->pci_addr);
                }
            }
        }
    }

    TITAN_DEBUG_LOG("[enforcer] app -> " << Classifier::target_to_string(target) << "\n");
    return result;
}

EnforcementResult GpuEnforcer::enforce_target_window(GpuTarget target, const std::string& window_addr) {
    if (window_addr.empty()) {
        return enforce_target(target);
    }

    EnforcementResult result;
    result.target = target;

    if (target == GpuTarget::DGPU) {
        if (!has_active_dgpu_clients()) {
            auto dgpu = detector_.find_dgpu();
            if (dgpu) {
                result.power_transitioned = power_.power_on_dgpu(dgpu->pci_addr);
            }
        }
        active_dgpu_windows_.insert(window_addr);
    } else if (target == GpuTarget::IGPU) {
        if (active_dgpu_windows_.erase(window_addr) > 0) {
            if (!has_active_dgpu_clients()) {
                auto dgpu = detector_.find_dgpu();
                if (dgpu) {
                    result.power_transitioned = power_.power_auto_dgpu(dgpu->pci_addr);
                }
            }
        }
    }

    TITAN_DEBUG_LOG("[enforcer] app (" << window_addr << ") -> " << Classifier::target_to_string(target) << "\n");
    return result;
}

void GpuEnforcer::remove_dgpu_window(const std::string& window_addr) {
    if (window_addr.empty()) return;
    if (active_dgpu_windows_.erase(window_addr) > 0) {
        if (!has_active_dgpu_clients()) {
            auto dgpu = detector_.find_dgpu();
            if (dgpu) {
                power_.power_auto_dgpu(dgpu->pci_addr);
            }
        }
    }
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

void GpuEnforcer::decrement_dgpu_clients() {
    if (active_dgpu_clients_ > 0) active_dgpu_clients_--;
}

}  // namespace titan
