#include "heavy_app_db.hpp"

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <vector>

static std::string repo_state_list_path() {
    // Resolve <repo>/interceptor/build/autogpuswitcher-launcher back to
    // <repo>/state/heavy_apps.list. Using the executable path instead of the
    // current working directory means game launchers and desktop entries work
    // even when they change into their own install directory first.
    std::error_code ec;
    const auto exe = std::filesystem::read_symlink("/proc/self/exe", ec);
    if (ec || exe.empty()) return {};

    const auto repo_root = exe.parent_path().parent_path().parent_path();
    const auto candidate = repo_root / "state" / "heavy_apps.list";
    if (std::filesystem::exists(candidate, ec)) {
        return candidate.string();
    }
    return {};
}

std::string get_heavy_list_path() {
    const char* env = std::getenv("AUTOGPUSWITCHER_HEAVY_LIST_FILE");
    if (env && *env) return env;

    if (std::filesystem::exists("/var/lib/autogpuswitcher/heavy_apps.list")) {
        return "/var/lib/autogpuswitcher/heavy_apps.list";
    }

    const std::string repo_list = repo_state_list_path();
    if (!repo_list.empty()) return repo_list;

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
