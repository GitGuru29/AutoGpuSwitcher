#include "heavy_app_db.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>

std::string get_heavy_list_path() {
    const char* env = std::getenv("AUTOGPUSWITCHER_HEAVY_LIST_FILE");
    if (env && *env) return env;

    if (std::filesystem::exists("/var/lib/autogpuswitcher/heavy_apps.list")) {
        return "/var/lib/autogpuswitcher/heavy_apps.list";
    }
    if (std::filesystem::exists("state/heavy_apps.list")) {
        return "state/heavy_apps.list";
    }
    return "/var/lib/autogpuswitcher/heavy_apps.list";
}

static std::string get_basename(const std::string& path) {
    auto pos = path.find_last_of('/');
    if (pos == std::string::npos) return path;
    return path.substr(pos + 1);
}

bool is_heavy_app(const char* target_path_or_name) {
    if (!target_path_or_name || !*target_path_or_name) return false;

    std::string target_str(target_path_or_name);
    std::string target_base = get_basename(target_str);

    std::string list_path = get_heavy_list_path();
    std::ifstream file(list_path);
    if (!file.is_open()) {
        return false;
    }

    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '#') continue;

        std::vector<std::string> tokens;
        std::istringstream ss(line);
        std::string token;
        while (std::getline(ss, token, '|')) {
            tokens.push_back(token);
        }

        if (tokens.empty()) continue;

        // Record format 1: package-name|app-name|/path/to/binary
        if (tokens.size() >= 3) {
            std::string app_name = tokens[1];
            std::string bin_path = tokens[2];
            if (target_str == bin_path || target_base == app_name || target_base == get_basename(bin_path)) {
                return true;
            }
        } else if (tokens.size() == 1) {
            // Record format 2: app-name or /path/to/binary
            std::string rec = tokens[0];
            if (target_str == rec || target_base == get_basename(rec)) {
                return true;
            }
        }
    }

    return false;
}
