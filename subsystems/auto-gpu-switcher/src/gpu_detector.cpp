#include "gpu_detector.hpp"

#include <dirent.h>
#include <sys/stat.h>

#include <algorithm>
#include <fstream>
#include <iostream>
#include <sstream>

namespace titan {

GpuVendor GpuDetector::parse_vendor(const std::string& vendor_id) {
    std::string v = vendor_id;
    while (!v.empty() && (v.front() == '0' || v.front() == 'x')) v.erase(v.begin());
    try {
        auto val = static_cast<uint16_t>(std::stoul(v, nullptr, 16));
        return static_cast<GpuVendor>(val);
    } catch (...) {
        return GpuVendor::Unknown;
    }
}

std::string GpuDetector::vendor_to_string(GpuVendor v) {
    switch (v) {
        case GpuVendor::Intel:  return "Intel";
        case GpuVendor::NVIDIA: return "NVIDIA";
        case GpuVendor::AMD:    return "AMD";
        default:                return "Unknown";
    }
}

static std::string read_file_str(const std::filesystem::path& p) {
    std::ifstream f(p);
    if (!f.is_open()) return {};
    std::string content((std::istreambuf_iterator<char>(f)),
                        std::istreambuf_iterator<char>());
    while (!content.empty() && (content.back() == '\n' || content.back() == '\r'))
        content.pop_back();
    return content;
}

bool GpuDetector::scan() {
    gpus_.clear();

    const char* drm_env = std::getenv("TITAN_DRM_PATH");
    const std::string drm_path = drm_env ? drm_env : "/sys/class/drm";
    DIR* dir = opendir(drm_path.c_str());
    if (!dir) {
        std::cerr << "[gpu_detector] cannot open " << drm_path << "\n";
        return false;
    }

    std::vector<std::string> card_dirs;
    struct dirent* ent;
    while ((ent = readdir(dir)) != nullptr) {
        std::string name = ent->d_name;
        if (name.substr(0, 4) == "card" && name.find('-') == std::string::npos) {
            card_dirs.push_back(name);
        }
    }
    closedir(dir);

    std::sort(card_dirs.begin(), card_dirs.end());

    for (const auto& card_name : card_dirs) {
        auto card_dir = std::filesystem::path(drm_path) / card_name;

        auto vendor_str = read_file_str(card_dir / "device" / "vendor");
        if (vendor_str.empty()) continue;

        GpuInfo info;
        info.card_path = card_dir.string();
        info.vendor = parse_vendor(vendor_str);
        info.vendor_name = vendor_to_string(info.vendor);

        auto uevent = read_file_str(card_dir / "device" / "uevent");
        if (!uevent.empty()) {
            std::istringstream ss(uevent);
            std::string line;
            while (std::getline(ss, line)) {
                if (line.substr(0, 14) == "PCI_SLOT_NAME=") {
                    info.pci_addr = line.substr(14);
                }
            }
        }

        auto status = read_file_str(card_dir / "status");
        info.is_connected = (status == "connected");

        auto render_dir = card_dir / "device" / "drm";
        if (std::filesystem::exists(render_dir)) {
            for (const auto& render_entry : std::filesystem::directory_iterator(render_dir)) {
                auto fname = render_entry.path().filename().string();
                if (fname.substr(0, 6) == "render") {
                    const char* dri_env = std::getenv("TITAN_DRI_PATH");
                    info.render_node = std::string(dri_env ? dri_env : "/dev/dri") + "/" + fname;
                    break;
                }
            }
        }

        if (info.render_node.empty()) {
            int idx = static_cast<int>(gpus_.size());
            const char* dri_env = std::getenv("TITAN_DRI_PATH");
            info.render_node = std::string(dri_env ? dri_env : "/dev/dri") + "/renderD" + std::to_string(128 + idx);
        }

        if (info.vendor == GpuVendor::NVIDIA) {
            struct stat st;
            if (stat("/proc/driver/nvidia/version", &st) == 0) {
                info.has_nvidia_driver = true;
            }
        }

        gpus_.push_back(std::move(info));
    }

    std::cout << "[gpu_detector] found " << gpus_.size() << " GPU(s)\n";
    for (const auto& g : gpus_) {
        std::cout << "  " << g.vendor_name << " " << g.pci_addr
                  << " render=" << g.render_node
                  << " connected=" << (g.is_connected ? "yes" : "no") << "\n";
    }

    return !gpus_.empty();
}

const GpuInfo* GpuDetector::find_igpu() const {
    for (const auto& g : gpus_) {
        if (g.vendor == GpuVendor::Intel) return &g;
    }
    return nullptr;
}

const GpuInfo* GpuDetector::find_dgpu() const {
    for (const auto& g : gpus_) {
        if (g.vendor == GpuVendor::NVIDIA) return &g;
    }
    return nullptr;
}

std::string GpuDetector::render_node_for_vendor(GpuVendor vendor) const {
    for (const auto& g : gpus_) {
        if (g.vendor == vendor) return g.render_node;
    }
    return {};
}

}  // namespace titan
