#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace titan {

enum class GpuVendor : uint16_t {
    Unknown = 0,
    Intel   = 0x8086,
    NVIDIA  = 0x10de,
    AMD     = 0x1002,
};

struct GpuInfo {
    std::string card_path;
    std::string render_node;
    std::string pci_addr;
    std::string vendor_name;
    GpuVendor vendor = GpuVendor::Unknown;
    bool is_connected = false;
    bool has_nvidia_driver = false;
};

class GpuDetector {
public:
    bool scan();
    const std::vector<GpuInfo>& gpus() const { return gpus_; }
    const GpuInfo* find_igpu() const;
    const GpuInfo* find_dgpu() const;
    std::string render_node_for_vendor(GpuVendor vendor) const;

private:
    static GpuVendor parse_vendor(const std::string& vendor_id);
    static std::string vendor_to_string(GpuVendor v);
    std::vector<GpuInfo> gpus_;
};

}  // namespace titan
