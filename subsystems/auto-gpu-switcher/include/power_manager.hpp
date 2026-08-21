#pragma once

#include <cstdint>
#include <filesystem>
#include <string>

namespace titan {

enum class PowerState : uint8_t {
    On,
    Auto,
    Off,
};

enum class PowerSource : uint8_t {
    AC,
    Battery,
    Unknown,
};

class PowerManager {
public:
    bool init();

    PowerSource current_source() const;
    bool is_on_battery() const;

    bool set_pci_power(const std::string& pci_addr, PowerState state);
    PowerState get_pci_power(const std::string& pci_addr) const;

    bool power_on_dgpu(const std::string& pci_addr);
    bool power_off_dgpu(const std::string& pci_addr);
    bool power_auto_dgpu(const std::string& pci_addr);

private:
    static std::string power_state_to_str(PowerState s);
    static PowerState str_to_power_state(const std::string& s);
    std::string ac_path_;
};

}  // namespace titan
