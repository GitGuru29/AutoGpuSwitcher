#include "power_manager.hpp"

#include <dirent.h>

#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>

namespace titan {

bool PowerManager::init() {
    const char* alt = std::getenv("AC_PATH");
    if (alt && *alt) {
        ac_path_ = alt;
        return true;
    }

    const std::vector<std::string> candidates = {
        "/sys/class/power_supply/AC/online",
        "/sys/class/power_supply/ACAD/online",
        "/sys/class/power_supply/ADP1/online",
        "/sys/class/power_supply/AC0/online"
    };

    for (const auto& candidate : candidates) {
        if (std::filesystem::exists(candidate)) {
            ac_path_ = candidate;
            return true;
        }
    }

    ac_path_ = "/sys/class/power_supply/AC/online";
    return true;
}

PowerSource PowerManager::current_source() const {
    std::ifstream f(ac_path_);
    if (!f.is_open()) return PowerSource::Unknown;
    int val = 0;
    f >> val;
    return val == 1 ? PowerSource::AC : PowerSource::Battery;
}

bool PowerManager::is_on_battery() const {
    return current_source() == PowerSource::Battery;
}

bool PowerManager::set_pci_power(const std::string& pci_addr, PowerState state) {
    const char* pci_env = std::getenv("TITAN_PCI_PATH");
    auto base = std::filesystem::path(pci_env ? pci_env : "/sys/bus/pci/devices");
    auto path = base / pci_addr / "power" / "control";
    if (!std::filesystem::exists(path)) {
        std::cerr << "[power_manager] PCI path not found: " << path << "\n";
        return false;
    }

    std::ofstream f(path);
    if (!f.is_open()) {
        std::cerr << "[power_manager] cannot write to " << path << "\n";
        return false;
    }

    f << power_state_to_str(state);
    if (!f.good()) {
        std::cerr << "[power_manager] write failed to " << path << "\n";
        return false;
    }

    std::cout << "[power_manager] set " << pci_addr << " -> " << power_state_to_str(state) << "\n";
    return true;
}

PowerState PowerManager::get_pci_power(const std::string& pci_addr) const {
    const char* pci_env = std::getenv("TITAN_PCI_PATH");
    auto base = std::filesystem::path(pci_env ? pci_env : "/sys/bus/pci/devices");
    auto path = base / pci_addr / "power" / "control";
    std::ifstream f(path);
    if (!f.is_open()) return PowerState::Auto;
    std::string val;
    f >> val;
    return str_to_power_state(val);
}

bool PowerManager::power_on_dgpu(const std::string& pci_addr) {
    return set_pci_power(pci_addr, PowerState::On);
}

bool PowerManager::power_off_dgpu(const std::string& pci_addr) {
    return set_pci_power(pci_addr, PowerState::Off);
}

bool PowerManager::power_auto_dgpu(const std::string& pci_addr) {
    return set_pci_power(pci_addr, PowerState::Auto);
}

std::string PowerManager::power_state_to_str(PowerState s) {
    switch (s) {
        case PowerState::On:   return "on";
        case PowerState::Off:  return "off";
        case PowerState::Auto: return "auto";
    }
    return "auto";
}

PowerState PowerManager::str_to_power_state(const std::string& s) {
    if (s == "on")   return PowerState::On;
    if (s == "off")  return PowerState::Off;
    return PowerState::Auto;
}

}  // namespace titan
