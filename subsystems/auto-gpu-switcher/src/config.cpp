#include "config.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iostream>
#include <sstream>

namespace titan {

std::filesystem::path Config::default_path() {
    const char* env = std::getenv("TITAN_CONFIG_PATH");
    return env ? std::filesystem::path(env) : std::filesystem::path("/etc/titan-gpu/config");
}

Config& Config::instance() {
    static Config inst;
    return inst;
}

bool Config::load(const std::filesystem::path& path) {
    config_path_ = path;
    return reload();
}

bool Config::reload() {
    std::ifstream file(config_path_);
    if (!file.is_open()) {
        std::cerr << "[config] cannot open " << config_path_ << "\n";
        return false;
    }

    apps_.clear();
    patterns_.clear();
    power_ = PowerConfig{};
    detector_ = DetectorConfig{};

    std::string section;
    std::string line;
    while (std::getline(file, line)) {
        parse_line(line, section);
    }
    return true;
}

static std::string trim(const std::string& s) {
    auto start = s.find_first_not_of(" \t\r\n");
    if (start == std::string::npos) return {};
    auto end = s.find_last_not_of(" \t\r\n");
    return s.substr(start, end - start + 1);
}

static std::string to_lower(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    return s;
}

static bool glob_match(const std::string& text, const std::string& pattern) {
    size_t ti = 0, pi = 0;
    size_t star_pi = std::string::npos, star_ti = 0;

    while (ti < text.size()) {
        if (pi < pattern.size() && pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi++;
        } else if (pi < pattern.size() && (pattern[pi] == text[ti] || pattern[pi] == '?')) {
            pi++;
            ti++;
        } else if (star_pi != std::string::npos) {
            pi = star_pi + 1;
            star_ti++;
            ti = star_ti;
        } else {
            return false;
        }
    }

    while (pi < pattern.size() && pattern[pi] == '*') pi++;
    return pi == pattern.size();
}

bool Config::parse_line(const std::string& raw, std::string& section) {
    auto line = trim(raw);
    if (line.empty() || line[0] == '#') return true;

    if (line.front() == '[' && line.back() == ']') {
        section = trim(line.substr(1, line.size() - 2));
        return true;
    }

    auto eq = line.find('=');
    if (eq == std::string::npos) return true;

    auto key = trim(line.substr(0, eq));
    auto val = trim(line.substr(eq + 1));
    auto lkey = to_lower(key);

    if (section == "power") {
        if (lkey == "default_profile") power_.default_profile = val;
        else if (lkey == "battery_profile") power_.battery_profile = val;
        else if (lkey == "dgpu_idle_timeout_sec") {
            try { power_.dgpu_idle_timeout_sec = static_cast<uint32_t>(std::stoul(val)); }
            catch (...) { std::cerr << "[config] invalid dgpu_idle_timeout_sec: " << val << "\n"; }
        }
        else if (lkey == "power_transition_timeout_ms") {
            try { power_.power_transition_timeout_ms = static_cast<uint32_t>(std::stoul(val)); }
            catch (...) { std::cerr << "[config] invalid power_transition_timeout_ms: " << val << "\n"; }
        }
    } else if (section == "detector") {
        if (lkey == "nvidia_driver") detector_.nvidia_driver = val;
        else if (lkey == "render_node_igpu") detector_.render_node_igpu = val;
        else if (lkey == "render_node_dgpu") detector_.render_node_dgpu = val;
    } else if (section == "apps") {
        apps_[lkey] = AppConfig{val};
    } else if (section == "patterns") {
        patterns_[lkey] = val;
    }

    return true;
}

std::string Config::classify_app(const std::string& wm_class) const {
    auto lc = to_lower(wm_class);

    auto it = apps_.find(lc);
    if (it != apps_.end()) return it->second.gpu_target;

    for (const auto& [pat, gpu_target] : patterns_) {
        if (glob_match(lc, pat)) {
            return gpu_target;
        }
    }

    return "auto";
}

}  // namespace titan
