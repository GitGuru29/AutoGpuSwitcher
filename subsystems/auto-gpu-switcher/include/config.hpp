#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <unordered_map>

namespace titan {

struct PowerConfig {
    std::string default_profile = "balanced";
    std::string battery_profile = "saver";
    uint32_t dgpu_idle_timeout_sec = 30;
    uint32_t power_transition_timeout_ms = 1000;
};

struct DetectorConfig {
    std::string nvidia_driver = "auto";
    std::string render_node_igpu;
    std::string render_node_dgpu;
};

struct AppConfig {
    std::string gpu_target = "auto";
};

class Config {
public:
    bool load(const std::filesystem::path& path);
    bool reload();

    const PowerConfig& power() const { return power_; }
    const DetectorConfig& detector() const { return detector_; }
    const std::unordered_map<std::string, AppConfig>& apps() const { return apps_; }
    const std::unordered_map<std::string, std::string>& patterns() const { return patterns_; }

    std::string classify_app(const std::string& wm_class) const;

    static Config& instance();
    static std::filesystem::path default_path();

private:
    Config() = default;
    bool parse_line(const std::string& line, std::string& section);

    PowerConfig power_;
    DetectorConfig detector_;
    std::unordered_map<std::string, AppConfig> apps_;
    std::unordered_map<std::string, std::string> patterns_;
    std::filesystem::path config_path_;
};

}  // namespace titan
