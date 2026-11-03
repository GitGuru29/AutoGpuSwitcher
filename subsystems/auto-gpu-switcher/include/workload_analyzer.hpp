#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

#include "workload_classifier.hpp"

namespace titan {

struct ProcessObservation {
    std::string gpu;   // "nvidia" or "intel"
    std::string time;  // ISO timestamp
};

struct ProcessEntry {
    uint64_t count = 0;
    std::string last_gpu;
    std::string last_seen;
    std::vector<ProcessObservation> observations;
};

// Workload analyzer: scans /proc for user GPU processes, maintains JSON
// history, analyzes workload patterns, and recommends a GPU target.
// Replaces the previous Python gpu_auto_switcher.py implementation.
class WorkloadAnalyzer {
public:
    // history_path: JSON file to persist per-process GPU observations
    explicit WorkloadAnalyzer(const std::string& history_path);

    // Scan /proc and update history. Returns number of processes tracked.
    int scan_processes();

    // Analyze history and return recommended target.
    GpuTarget analyze() const;

    // Time-of-day prediction from historical observations (or Auto if no data).
    GpuTarget predict_time_of_day() const;

    // Battery drain rate in watts over the recent window, or -1 if unknown.
    double drain_rate_watts() const;

    // Battery capacity percentage (0-100), or -1 if no battery.
    int battery_capacity() const;

    // True if AC adapter is connected, false if battery, -1 if unknown.
    int on_ac_power() const;

    // Number of tracked process entries.
    size_t entry_count() const { return history_.size(); }

    // Get readable summary for CLI status command.
    std::string status_report() const;

    // Reload history from disk.
    void reload();

private:
    void load_history();
    void save_history() const;
    void update_entry(const std::string& proc_name, const std::string& gpu);
    std::string read_cmdline(int pid) const;
    std::string detect_process_gpu(int pid,
                                   const std::string& cmdline_lower) const;
    int64_t process_age_sec(int pid) const;

    std::string history_path_;
    std::map<std::string, ProcessEntry> history_;
};

}  // namespace titan
