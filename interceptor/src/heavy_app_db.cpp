#include "heavy_app_db.hpp"

#include <algorithm>
#include <cctype>
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

static std::string to_lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

static std::vector<std::string> split_fields(const std::string& line) {
    std::vector<std::string> fields;
    std::string field;
    std::istringstream ss(line);
    while (std::getline(ss, field, '|')) {
        fields.push_back(field);
    }
    if (!line.empty() && line.back() == '|') {
        fields.emplace_back();
    }
    return fields;
}

static std::string trim(const std::string& value) {
    auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return {};
    auto last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}

struct HeavyRecord {
    std::string app_name;  // lowercased, never empty for valid records
    std::string bin_path;  // empty when the record carries no absolute path
};

// Accepted layouts (the analyzer writes the first one):
//   package|app-name|/path/to/binary
//   app-name|/path/to/binary
//   package|app-name
//   app-name
// The path always starts at the first field beginning with '/', so a '|'
// inside the path does not break parsing.
static bool parse_record(const std::string& raw_line, HeavyRecord& out) {
    const std::string line = trim(raw_line);
    if (line.empty() || line[0] == '#') return false;

    auto fields = split_fields(line);
    if (fields.empty()) return false;

    size_t path_idx = fields.size();
    for (size_t i = 0; i < fields.size(); ++i) {
        if (fields[i].size() > 1 && fields[i][0] == '/') {
            path_idx = i;
            break;
        }
    }

    out.app_name.clear();
    out.bin_path.clear();

    if (path_idx < fields.size()) {
        out.bin_path = fields[path_idx];
        for (size_t i = path_idx + 1; i < fields.size(); ++i) {
            out.bin_path += "|";
            out.bin_path += fields[i];
        }
        if (path_idx > 0 && !fields[path_idx - 1].empty()) {
            out.app_name = fields[path_idx - 1];
        } else {
            out.app_name = get_basename(out.bin_path);
        }
    } else {
        for (auto it = fields.rbegin(); it != fields.rend(); ++it) {
            if (!it->empty()) {
                out.app_name = *it;
                break;
            }
        }
    }

    if (out.app_name.empty()) return false;
    out.app_name = to_lower(trim(out.app_name));
    if (out.app_name.empty()) return false;
    return true;
}

bool is_heavy_app(const char* target_path_or_name) {
    if (!target_path_or_name || !*target_path_or_name) return false;

    const std::string target(target_path_or_name);
    const bool target_is_path = target.find('/') != std::string::npos;
    const std::string target_base = to_lower(get_basename(target));

    std::ifstream file(get_heavy_list_path());
    if (!file.is_open()) {
        return false;
    }

    std::string line;
    while (std::getline(file, line)) {
        HeavyRecord record;
        if (!parse_record(line, record)) continue;

        if (!record.bin_path.empty()) {
            // A record with a known install path only matches that exact path;
            // basenames like "launcher" must not match unrelated binaries.
            if (target_is_path) {
                if (target == record.bin_path) return true;
                continue;
            }
        }

        if (target_base == record.app_name) return true;
    }

    return false;
}
