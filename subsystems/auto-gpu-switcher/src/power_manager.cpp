#include "power_manager.hpp"

#include <dirent.h>

#include <cstdlib>
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

    const char* base_env = std::getenv("TITAN_POWER_SUPPLY_PATH");
    const std::filesystem::path base = (base_env && *base_env)
        ? std::filesystem::path(base_env)
        : std::filesystem::path("/sys/class/power_supply");

    // Preferred: find the mains supply by its type instead of assuming a
    // well-known name. Laptops use AC, ACAD, ADP0, ADP1, AC0, ...
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(base, ec)) {
        const auto type_path = entry.path() / "type";
        const auto online_path = entry.path() / "online";

        std::ifstream type_file(type_path);
        std::string type;
        if (!(type_file >> type) || type != "Mains") continue;
        if (!std::filesystem::exists(online_path)) continue;

        ac_path_ = online_path.string();
        return true;
    }

    // Fallback for sysfs layouts that do not expose a type attribute.
    const std::vector<std::string> candidates = {
        (base / "AC" / "online").string(),
        (base / "ACAD" / "online").string(),
        (base / "ADP1" / "online").string(),
        (base / "AC0" / "online").string(),
    };

    for (const auto& candidate : candidates) {
        if (std::filesystem::exists(candidate)) {
            ac_path_ = candidate;
            return true;
        }
    }

    ac_path_ = (base / "AC" / "online").string();
    return true;
}

PowerSource PowerManager::current_source() const {
    std::ifstream f(ac_path_);
    if (!f.is_open()) return PowerSource::Unknown;

    int val = -1;
    f >> val;
    if (val == 1) return PowerSource::AC;
    if (val == 0) return PowerSource::Battery;
    return PowerSource::Unknown;
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
