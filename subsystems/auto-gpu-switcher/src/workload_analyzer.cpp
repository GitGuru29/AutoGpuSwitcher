#include "workload_analyzer.hpp"

#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <set>

namespace titan {

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

static std::string now_iso() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
    localtime_r(&t, &tm);
    char buf[32];
    std::strftime(buf, sizeof(buf), "%Y-%m-%dT%H:%M:%S", &tm);
    return buf;
}

static int64_t iso_hour(const std::string& iso) {
    // "2026-10-07T13:00:00" -> 13
    auto pos = iso.find('T');
    if (pos == std::string::npos || pos + 2 >= iso.size()) return -1;
    try {
        return std::stoi(iso.substr(pos + 1, 2));
    } catch (...) {
        return -1;
    }
}

// Parse ISO timestamp to epoch seconds (approximate, local time)
static int64_t iso_to_epoch(const std::string& iso) {
    std::tm tm{};
    if (strptime(iso.c_str(), "%Y-%m-%dT%H:%M:%S", &tm) == nullptr) return 0;
    return mktime(&tm);
}

static std::string read_file(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open()) return "";
    std::stringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

// Run a command and return stdout (empty on failure).
static std::string run_cmd(const std::vector<std::string>& args,
                           int timeout_sec = 5) {
    int pipefd[2];
    if (pipe(pipefd) != 0) return "";

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return "";
    }

    if (pid == 0) {
        // Child
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);
        std::vector<char*> argv;
        for (auto& a : args) argv.push_back(const_cast<char*>(a.c_str()));
        argv.push_back(nullptr);
        execvp(argv[0], argv.data());
        _exit(127);
    }

    // Parent
    close(pipefd[1]);
    std::string output;
    std::array<char, 4096> buf{};
    // Set alarm-based timeout
    alarm(timeout_sec);
    ssize_t n;
    while ((n = read(pipefd[0], buf.data(), buf.size())) > 0) {
        output.append(buf.data(), static_cast<size_t>(n));
    }
    alarm(0);
    close(pipefd[0]);
    int status;
    waitpid(pid, &status, 0);
    return output;
}

// ---------------------------------------------------------------------------
// History file format (line-based, one process per line)
//
// Format:  count|last_gpu|last_seen|gpu:time,gpu:time,...
// Header:  # titan-workload-history v1
// ---------------------------------------------------------------------------

WorkloadAnalyzer::WorkloadAnalyzer(const std::string& history_path)
    : history_path_(history_path) {
    load_history();
}

void WorkloadAnalyzer::load_history() {
    history_.clear();
    std::ifstream f(history_path_);
    if (!f.is_open()) return;

    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;

        // Split by first 3 '|'
        std::vector<std::string> parts;
        size_t start = 0;
        while (start < line.size() && parts.size() < 3) {
            size_t pos = line.find('|', start);
            if (pos == std::string::npos) break;
            parts.push_back(line.substr(start, pos - start));
            start = pos + 1;
        }
        if (parts.size() < 3) continue;

        std::string proc_name = parts[0];
        ProcessEntry entry;
        try {
            entry.count = std::stoull(parts[1]);
        } catch (...) { continue; }
        entry.last_gpu = parts[2];

        // Remaining after 3rd '|'
        size_t third = line.find('|');
        third = line.find('|', third + 1);
        third = line.find('|', third + 1);
        if (third != std::string::npos) {
            std::string rest = line.substr(third + 1);
            // last_seen is the 4th field
            size_t pipe_pos = rest.find('|');
            std::string obs_str;
            if (pipe_pos != std::string::npos) {
                entry.last_seen = rest.substr(0, pipe_pos);
                obs_str = rest.substr(pipe_pos + 1);
            } else {
                entry.last_seen = rest;
            }
            // Parse observations: "intel:2026-10-07T13:00:00,nvidia:..."
            std::istringstream iss(obs_str);
            std::string token;
            while (std::getline(iss, token, ',')) {
                auto colon = token.find(':');
                if (colon == std::string::npos) continue;
                ProcessObservation obs;
                obs.gpu = token.substr(0, colon);
                obs.time = token.substr(colon + 1);
                entry.observations.push_back(obs);
            }
            // Trim to last 100
            if (entry.observations.size() > 100) {
                entry.observations.erase(
                    entry.observations.begin(),
                    entry.observations.end() - 100);
            }
        }

        history_[proc_name] = entry;
    }
}

void WorkloadAnalyzer::save_history() const {
    // Atomic write: temp + rename
    std::string tmp = history_path_ + ".tmp";
    std::ofstream f(tmp, std::ios::trunc);
    if (!f.is_open()) return;

    f << "# titan-workload-history v1\n";
    for (const auto& [name, entry] : history_) {
        // Escape '|' in process name (replace with '_')
        std::string safe_name = name;
        std::replace(safe_name.begin(), safe_name.end(), '|', '_');

        f << safe_name << '|'
          << entry.count << '|'
          << entry.last_gpu << '|'
          << entry.last_seen << '|';

        // Observations: gpu:time,gpu:time
        bool first = true;
        for (const auto& obs : entry.observations) {
            if (!first) f << ',';
            f << obs.gpu << ':' << obs.time;
            first = false;
        }
        f << '\n';
    }
    f.close();
    std::rename(tmp.c_str(), history_path_.c_str());
}

void WorkloadAnalyzer::reload() {
    load_history();
}

void WorkloadAnalyzer::update_entry(const std::string& proc_name,
                                     const std::string& gpu) {
    auto& entry = history_[proc_name];
    entry.count++;
    entry.last_gpu = gpu;
    entry.last_seen = now_iso();
    entry.observations.push_back({gpu, entry.last_seen});
    if (entry.observations.size() > 100) {
        entry.observations.erase(entry.observations.begin());
    }
}

// ---------------------------------------------------------------------------
// /proc scanning
// ---------------------------------------------------------------------------

int64_t WorkloadAnalyzer::process_age_sec(int pid) const {
    // Read /proc/<pid>/stat, parse from last ')'
    std::string stat = read_file("/proc/" + std::to_string(pid) + "/stat");
    if (stat.empty()) return -1;

    size_t rparen = stat.rfind(')');
    if (rparen == std::string::npos) return -1;

    // After ")", fields are space-separated. starttime is field index 19
    // (0-based after removing pid and comm).
    std::istringstream iss(stat.substr(rparen + 1));
    std::string token;
    for (int i = 0; i < 20; i++) {
        if (!(iss >> token)) return -1;
    }
    // token now holds starttime (jiffies since boot)
    long long starttime = 0;
    try {
        starttime = std::stoll(token);
    } catch (...) { return -1; }

    // Read uptime
    std::string uptime_str = read_file("/proc/uptime");
    if (uptime_str.empty()) return -1;
    double uptime = 0;
    try {
        uptime = std::stod(uptime_str);
    } catch (...) { return -1; }

    long hertz = sysconf(_SC_CLK_TCK);
    if (hertz <= 0) hertz = 100;

    double start_sec = static_cast<double>(starttime) / hertz;
    double age = uptime - start_sec;
    return age >= 0 ? static_cast<int64_t>(age) : 0;
}

std::string WorkloadAnalyzer::read_cmdline(int pid) const {
    std::string path = "/proc/" + std::to_string(pid) + "/cmdline";
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) return "";
    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf));
    close(fd);
    if (n <= 0) return "";
    std::string result(buf, static_cast<size_t>(n));
    // Replace null separators with spaces
    std::replace(result.begin(), result.end(), '\0', ' ');
    return result;
}

std::string WorkloadAnalyzer::detect_process_gpu(
        int pid, const std::string& cmdline_lower) const {
    // Check nvidia-smi compute apps (done once by caller and passed in via
    // cmdline_lower prefix? No — we check nvidia_pids externally.)

    // Check environment for PRIME offload markers
    std::string env = read_file("/proc/" + std::to_string(pid) + "/environ");
    if (env.find("__NV_PRIME_RENDER_OFFLOAD") != std::string::npos ||
        env.find("__VK_LAYER_NV_optimus") != std::string::npos) {
        return "nvidia";
    }

    // Check for offload wrappers in cmdline
    static const std::vector<std::string> wrappers = {
        "optirun", "primusrun", "prime-run"
    };
    for (const auto& w : wrappers) {
        if (cmdline_lower.find(w) != std::string::npos) return "nvidia";
    }

    // Check for heavy app keywords in the basename
    static const std::vector<std::string> heavy_kw = {
        "steam", "lutris", "blender", "3dsmax", "maya", "unreal",
        "godot", "obs", "kdenlive", "davinci", "cad", "render",
        "nvidia", "cuda", "gpgpu", "hashcat", "opencv"
    };
    // Extract first token (binary path) basename
    auto space_pos = cmdline_lower.find(' ');
    std::string first = cmdline_lower.substr(
        0, space_pos == std::string::npos ? std::string::npos : space_pos);
    auto slash_pos = first.rfind('/');
    std::string base = (slash_pos != std::string::npos)
        ? first.substr(slash_pos + 1) : first;
    for (const auto& kw : heavy_kw) {
        if (base.find(kw) != std::string::npos) return "nvidia";
    }

    return "intel";
}

int WorkloadAnalyzer::scan_processes() {
    // Get nvidia-smi compute PIDs once
    std::set<int> nvidia_pids;
    {
        auto out = run_cmd({"nvidia-smi",
                            "--query-compute-apps=pid",
                            "--format=csv,noheader,nounits"});
        std::istringstream iss(out);
        std::string line;
        while (std::getline(iss, line)) {
            try { nvidia_pids.insert(std::stoi(line)); } catch (...) {}
        }
    }

    uid_t my_uid = getuid();
    DIR* proc = opendir("/proc");
    if (!proc) return 0;

    int tracked = 0;
    struct dirent* ent;
    while ((ent = readdir(proc)) != nullptr) {
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9') continue;
        int pid = atoi(ent->d_name);
        if (pid <= 0 || pid == getpid()) continue;

        // Only current user's processes
        struct stat st{};
        std::string proc_path = "/proc/" + std::to_string(pid);
        if (stat(proc_path.c_str(), &st) != 0) continue;
        if (st.st_uid != my_uid) continue;

        // Age filter
        int64_t age = process_age_sec(pid);
        if (age < 0 || age < 10) continue;  // MIN_PROCESS_AGE_SEC = 10

        // Read cmdline once
        std::string cmdline = read_cmdline(pid);
        if (cmdline.empty()) continue;

        std::string lower = cmdline;
        std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);

        // Detect GPU
        std::string gpu;
        if (nvidia_pids.count(pid)) {
            gpu = "nvidia";
        } else {
            gpu = detect_process_gpu(pid, lower);
        }

        // Process key: first 50 chars of cmdline
        std::string key = cmdline.substr(0, 50);
        // Trim trailing spaces
        while (!key.empty() && key.back() == ' ') key.pop_back();
        if (key.empty()) continue;

        update_entry(key, gpu);
        tracked++;
    }
    closedir(proc);

    save_history();
    return tracked;
}

// ---------------------------------------------------------------------------
// Workload analysis
// ---------------------------------------------------------------------------

GpuTarget WorkloadAnalyzer::analyze() const {
    // Score-based analysis over a 600-second window
    const int64_t window_sec = 600;
    const int min_apps = 4;
    const double ratio = 1.5;

    int64_t now = std::time(nullptr);
    int intel_score = 0;
    int nvidia_score = 0;
    int total_apps = 0;

    for (const auto& [name, entry] : history_) {
        int64_t last_epoch = iso_to_epoch(entry.last_seen);
        if (now - last_epoch > window_sec) continue;

        total_apps++;
        if (entry.last_gpu == "nvidia") {
            nvidia_score += static_cast<int>(entry.count);
        } else {
            intel_score += static_cast<int>(entry.count);
        }
    }

    if (total_apps < min_apps) return GpuTarget::Auto;
    if (nvidia_score > intel_score * ratio) return GpuTarget::DGPU;
    if (intel_score > nvidia_score * ratio) return GpuTarget::IGPU;
    return GpuTarget::Auto;
}

GpuTarget WorkloadAnalyzer::predict_time_of_day() const {
    const int window_days = 14;
    const int min_samples = 5;

    int64_t now = std::time(nullptr);
    int64_t cutoff = now - window_days * 86400;
    int current_hour = 0;
    {
        std::time_t t = std::time(nullptr);
        std::tm tm{};
        localtime_r(&t, &tm);
        current_hour = tm.tm_hour;
    }

    int hour_nvidia = 0;
    int hour_intel = 0;
    int total = 0;

    for (const auto& [name, entry] : history_) {
        for (const auto& obs : entry.observations) {
            int64_t epoch = iso_to_epoch(obs.time);
            if (epoch < cutoff) continue;
            int hour = static_cast<int>(iso_hour(obs.time));
            if (hour < 0) continue;

            // Same hour or ±1 hour tolerance (wrap midnight)
            int diff = std::abs(hour - current_hour);
            if (diff > 1 && !(current_hour == 23 && hour == 0) &&
                !(current_hour == 0 && hour == 23)) continue;

            total++;
            if (obs.gpu == "nvidia") hour_nvidia++;
            else hour_intel++;
        }
    }

    if (total < min_samples) return GpuTarget::Auto;
    if (hour_nvidia > hour_intel * 1.3) return GpuTarget::DGPU;
    if (hour_intel > hour_nvidia * 1.3) return GpuTarget::IGPU;
    return GpuTarget::Auto;
}

// ---------------------------------------------------------------------------
// Power monitoring
// ---------------------------------------------------------------------------

static bool read_sysfs_int(const std::string& path, long& out) {
    std::string s = read_file(path);
    if (s.empty()) return false;
    try {
        out = std::stol(s);
        return true;
    } catch (...) { return false; }
}

int WorkloadAnalyzer::battery_capacity() const {
    // Check BAT0, BAT1, etc.
    for (const char* bat : {"/sys/class/power_supply/BAT0",
                            "/sys/class/power_supply/BAT1"}) {
        long val;
        if (read_sysfs_int(std::string(bat) + "/capacity", val)) {
            return static_cast<int>(val);
        }
    }
    return -1;
}

int WorkloadAnalyzer::on_ac_power() const {
    for (const char* ac : {"/sys/class/power_supply/AC",
                           "/sys/class/power_supply/ACAD",
                           "/sys/class/power_supply/ADP1"}) {
        long val;
        if (read_sysfs_int(std::string(ac) + "/online", val)) {
            return val == 1 ? 1 : 0;
        }
    }
    // Fallback: check battery status
    std::string status = read_file(
        "/sys/class/power_supply/BAT0/status");
    if (status.empty()) return -1;
    if (status.find("Discharging") != std::string::npos) return 0;
    return 1;
}

double WorkloadAnalyzer::drain_rate_watts() const {
    // Read instantaneous power
    for (const char* bat : {"/sys/class/power_supply/BAT0",
                            "/sys/class/power_supply/BAT1"}) {
        long power_uw;
        if (read_sysfs_int(std::string(bat) + "/power_now", power_uw)) {
            return power_uw / 1'000'000.0;
        }
        // Fallback: voltage * current
        long volt, curr;
        if (read_sysfs_int(std::string(bat) + "/voltage_now", volt) &&
            read_sysfs_int(std::string(bat) + "/current_now", curr)) {
            return std::abs(static_cast<double>(volt) * curr) / 1e12;
        }
    }
    return -1.0;
}

// ---------------------------------------------------------------------------
// Status report
// ---------------------------------------------------------------------------

std::string WorkloadAnalyzer::status_report() const {
    std::ostringstream ss;
    GpuTarget decision = analyze();
    GpuTarget tod = predict_time_of_day();

    ss << "Tracked apps:      " << history_.size() << "\n";
    ss << "Workload decision: " << Classifier::target_to_string(decision) << "\n";
    ss << "Time-of-day pred:  " << Classifier::target_to_string(tod);
    if (tod == GpuTarget::Auto) ss << " (insufficient data)";
    ss << "\n";

    int cap = battery_capacity();
    int ac = on_ac_power();
    double drain = drain_rate_watts();
    if (cap >= 0) {
        ss << "Power:             ";
        if (drain >= 0) {
            ss << std::fixed << std::setprecision(1) << drain << "W ";
        }
        ss << "capacity=" << cap << "% "
           << "AC=" << (ac == 1 ? "yes" : ac == 0 ? "no" : "?") << "\n";
    }

    return ss.str();
}

}  // namespace titan
