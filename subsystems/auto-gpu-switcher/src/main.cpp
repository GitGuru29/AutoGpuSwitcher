#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <signal.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>

#include "cli.hpp"
#include "config.hpp"
#include "debug_log.hpp"
#include "gpu_detector.hpp"
#include "gpu_enforcer.hpp"
#include "hyprland_ipc_bridge.hpp"
#include "power_manager.hpp"
#include "state_writer.hpp"
#include "workload_classifier.hpp"
#include "workload_analyzer.hpp"

static std::atomic<bool> g_running{true};
static std::atomic<bool> g_reload{false};

static void handle_signal(int sig) {
    if (sig == SIGTERM || sig == SIGINT) g_running = false;
    if (sig == SIGHUP) g_reload = true;
}

static std::string get_socket_path() {
    const char* env = std::getenv("TITAN_SOCKET_PATH");
    if (env) return std::string(env);
    // Prefer systemd RuntimeDirectory; fall back to /tmp only if /run unavailable
    if (std::filesystem::exists("/run/titan-gpu")) {
        return "/run/titan-gpu/daemon.sock";
    }
    return "/tmp/titan-gpu-daemon.sock";
}

class Daemon {
public:
    bool init() {
        auto& cfg = titan::Config::instance();
        if (!cfg.load(titan::Config::default_path())) {
            std::cerr << "[daemon] using defaults (config not found)\n";
        }

        if (!detector_.scan()) {
            std::cerr << "[daemon] no GPUs detected, running in iGPU-only mode\n";
        }

        if (!power_.init()) {
            std::cerr << "[daemon] power manager init failed\n";
        }

        profile_idle_timeout_ = cfg.power().dgpu_idle_timeout_sec;
        enforcer_ = std::make_unique<titan::GpuEnforcer>(detector_, power_);

        if (!setup_socket()) {
            std::cerr << "[daemon] socket setup failed\n";
            return false;
        }

        if (!ipc_.connect()) {
            std::cerr << "[daemon] hyprland IPC unavailable, window tracking disabled\n";
        }

        ipc_.set_callback([this](const titan::WindowEvent& ev) {
            on_window_change(ev);
        });

        // Initialize workload analyzer (replaces Python gpu_auto_switcher.py)
        std::string hist_path;
        if (const char* env = std::getenv("TITAN_HISTORY_PATH")) {
            hist_path = env;
        } else if (std::filesystem::exists("/var/lib/autogpuswitcher")) {
            hist_path = "/var/lib/autogpuswitcher/workload_history.dat";
        } else {
            // Per-user fallback
            const char* home = std::getenv("HOME");
            hist_path = std::string(home ? home : "/tmp") +
                        "/.titan-gpu/workload_history.dat";
            std::filesystem::create_directories(
                std::filesystem::path(hist_path).parent_path());
        }
        workload_ = std::make_unique<titan::WorkloadAnalyzer>(hist_path);

        state_writer_.write(detector_, power_, current_target_, active_app_);
        return true;
    }

    void run() {
        std::cout << "[daemon] running (pid=" << getpid() << ")\n";

        auto last_activity = std::chrono::steady_clock::now();
        auto last_workload_scan = std::chrono::steady_clock::now() -
                                  std::chrono::hours(1);  // scan immediately
        auto& cfg = titan::Config::instance();

        while (g_running) {
            if (g_reload) {
                g_reload = false;
                cfg.reload();
                // Re-apply current profile with new config defaults
                apply_profile(current_profile_);
                std::cout << "[daemon] config reloaded\n";
            }

            ipc_.poll(500);

            // Workload-based auto-switching (runs every 5 minutes)
            auto now = std::chrono::steady_clock::now();
            auto since_scan = std::chrono::duration_cast<std::chrono::seconds>(
                now - last_workload_scan).count();
            if (since_scan >= 300) {
                last_workload_scan = now;
                run_workload_cycle();
            }

            if (enforcer_->has_active_dgpu_clients()) {
                last_activity = std::chrono::steady_clock::now();
            } else {
                auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                    std::chrono::steady_clock::now() - last_activity).count();
                if (static_cast<uint32_t>(elapsed) >= profile_idle_timeout_) {
                    enforcer_->idle_power_off(profile_idle_timeout_);
                    last_activity = std::chrono::steady_clock::now();
                }
            }

            state_writer_.write(detector_, power_, current_target_, active_app_);
            handle_commands();
        }

        cleanup();
        std::cout << "[daemon] shut down\n";
    }

private:
    // Periodic workload analysis cycle (replaces Python gpu_auto_switcher.py)
    void run_workload_cycle() {
        if (!workload_) return;

        int tracked = workload_->scan_processes();
        titan::GpuTarget decision = workload_->analyze();
        titan::GpuTarget tod = workload_->predict_time_of_day();

        std::cout << "[workload] tracked=" << tracked
                  << " decision=" << titan::Classifier::target_to_string(decision)
                  << " tod=" << titan::Classifier::target_to_string(tod)
                  << "\n";

        // Time-of-day breaks ties when workload window is inconclusive
        if (decision == titan::GpuTarget::Auto &&
            tod != titan::GpuTarget::Auto) {
            decision = tod;
            std::cout << "[workload] using time-of-day: "
                      << titan::Classifier::target_to_string(decision) << "\n";
        }

        // Power-aware bias: on battery with high drain, prefer iGPU
        if (decision == titan::GpuTarget::Auto &&
            workload_->on_ac_power() == 0) {
            double drain = workload_->drain_rate_watts();
            if (drain > 25.0) {
                decision = titan::GpuTarget::IGPU;
                std::cout << "[workload] battery drain " << drain
                          << "W > 25W, biasing to iGPU\n";
            }
        }

        // Don't override manual overrides or active window enforcement
        if (manual_override_active_) return;
        if (enforcer_->has_active_dgpu_clients()) return;

        if (decision == titan::GpuTarget::DGPU &&
            current_target_ != titan::GpuTarget::DGPU) {
            auto result = enforcer_->enforce_target(titan::GpuTarget::DGPU, /*idempotent=*/true);
            current_target_ = result.target;
            std::cout << "[workload] switched to dGPU\n";
        } else if (decision == titan::GpuTarget::IGPU &&
                   current_target_ != titan::GpuTarget::IGPU) {
            auto result = enforcer_->enforce_target(titan::GpuTarget::IGPU, /*idempotent=*/true);
            current_target_ = result.target;
            std::cout << "[workload] switched to iGPU\n";
        }
    }

    void on_window_change(const titan::WindowEvent& ev) {
        if (ev.type == titan::WindowEventType::Closed) {
            TITAN_DEBUG_LOG("[ipc] window closed: addr=" << ev.addr << "\n");
            enforcer_->remove_dgpu_window(ev.addr);
            return;
        }

        TITAN_DEBUG_LOG("[ipc] active window: " << ev.wm_class << " (" << ev.title << ") addr=" << ev.addr << "\n");
        active_app_ = ev.wm_class;

        titan::EnforcementResult result;
        if (manual_override_active_) {
            result = enforcer_->enforce_target_window(manual_override_, ev.addr);
        } else {
            result = enforcer_->enforce_for_app_window(ev.wm_class, ev.addr);
        }
        current_target_ = result.target;

        if (result.power_transitioned) {
            std::cout << "[ipc] power transitioned for " << ev.wm_class << "\n";
        }
    }

    bool setup_socket() {
        auto socket_path = get_socket_path();
        ::unlink(socket_path.c_str());

        listen_fd_ = socket(AF_UNIX, SOCK_STREAM, 0);
        if (listen_fd_ < 0) {
            std::cerr << "[daemon] socket() failed: " << std::strerror(errno) << "\n";
            return false;
        }

        struct sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        std::strncpy(addr.sun_path, socket_path.c_str(), sizeof(addr.sun_path) - 1);

        if (::bind(listen_fd_, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
            std::cerr << "[daemon] bind() failed: " << std::strerror(errno) << "\n";
            close(listen_fd_);
            listen_fd_ = -1;
            return false;
        }

        // Restrict socket access: owner rw, group r — prevents world-writable IPC
        ::chmod(socket_path.c_str(), 0660);

        if (listen(listen_fd_, 5) < 0) {
            std::cerr << "[daemon] listen() failed: " << std::strerror(errno) << "\n";
            close(listen_fd_);
            listen_fd_ = -1;
            return false;
        }

        std::cout << "[daemon] listening on " << socket_path << "\n";
        return true;
    }

    void handle_commands() {
        if (listen_fd_ < 0) return;

        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(listen_fd_, &fds);

        struct timeval tv{};
        tv.tv_sec = 0;
        tv.tv_usec = 100000;

        int ret = select(listen_fd_ + 1, &fds, nullptr, nullptr, &tv);
        if (ret <= 0) return;

        int client_fd = accept(listen_fd_, nullptr, nullptr);
        if (client_fd < 0) return;

        // Verify client credentials: only root or same UID may send commands
        struct ucred cred{};
        socklen_t cred_len = sizeof(cred);
        if (getsockopt(client_fd, SOL_SOCKET, SO_PEERCRED, &cred, &cred_len) == 0) {
            if (cred.uid != 0 && cred.uid != getuid()) {
                const char* denied = "error: permission denied\n";
                send(client_fd, denied, strlen(denied), 0);
                close(client_fd);
                return;
            }
        }

        char buf[256]{};
        ssize_t n = recv(client_fd, buf, sizeof(buf) - 1, 0);
        if (n > 0) {
            std::string cmd(buf, static_cast<size_t>(n));
            auto response = process_command(cmd);
            send(client_fd, response.c_str(), response.size(), 0);
        }
        close(client_fd);
    }

    std::string process_command(const std::string& raw) {
        std::string cmd = raw;
        while (!cmd.empty() && cmd.back() == '\n') cmd.pop_back();

        if (cmd == "status") {
            return get_status();
        }

        if (cmd.substr(0, 4) == "set ") {
            auto target_str = cmd.substr(4);
            auto target = titan::Classifier::string_to_target(target_str);
            if (target == titan::GpuTarget::Auto && target_str != "auto") {
                return "error: invalid target (igpu, dgpu, auto)\n";
            }
            manual_override_ = target;
            manual_override_active_ = (target != titan::GpuTarget::Auto);
            auto result = enforcer_->enforce_target(target, /*idempotent=*/true);
            current_target_ = result.target;
            return std::string("set -> ") + titan::Classifier::target_to_string(target) + "\n";
        }

        if (cmd.substr(0, 6) == "power ") {
            auto state_str = cmd.substr(6);
            auto dgpu = detector_.find_dgpu();
            if (!dgpu) return "error: no dGPU found\n";

            if (state_str == "on") {
                power_.power_on_dgpu(dgpu->pci_addr);
                return "dGPU power -> on\n";
            } else if (state_str == "off") {
                power_.power_off_dgpu(dgpu->pci_addr);
                return "dGPU power -> off\n";
            } else if (state_str == "auto") {
                power_.power_auto_dgpu(dgpu->pci_addr);
                return "dGPU power -> auto\n";
            }
            return "error: invalid power state (on, off, auto)\n";
        }

        if (cmd == "reload") {
            titan::Config::instance().reload();
            return "config reloaded\n";
        }

        if (cmd.substr(0, 8) == "profile ") {
            auto profile = cmd.substr(8);
            if (profile == "balanced" || profile == "saver" || profile == "performance") {
                current_profile_ = profile;
                apply_profile(profile);
                return "profile -> " + profile + "\n";
            }
            return "error: invalid profile (balanced, saver, performance)\n";
        }

        if (cmd == "workload") {
            if (workload_) return workload_->status_report();
            return "error: workload analyzer not initialized\n";
        }

        if (cmd == "workload-rescan") {
            if (!workload_) return "error: workload analyzer not initialized\n";
            int n = workload_->scan_processes();
            return "scanned " + std::to_string(n) + " processes\n";
        }

        return "error: unknown command\n";
    }

    std::string get_status() {
        std::string out;
        out += "GPUs:\n";
        for (const auto& g : detector_.gpus()) {
            out += "  " + g.vendor_name + " [" + g.pci_addr + "]"
                   + " render=" + g.render_node
                   + " connected=" + (g.is_connected ? "yes" : "no") + "\n";
        }
        out += "Power: " + std::string(power_.is_on_battery() ? "battery" : "AC") + "\n";
        out += "Target: " + std::string(titan::Classifier::target_to_string(current_target_)) + "\n";
        out += "Active: " + active_app_ + "\n";
        out += "Profile: " + current_profile_ + "\n";

        auto dgpu = detector_.find_dgpu();
        if (dgpu) {
            auto ps = power_.get_pci_power(dgpu->pci_addr);
            out += "dGPU power: " + std::string(ps == titan::PowerState::On ? "on" : ps == titan::PowerState::Off ? "off" : "auto") + "\n";
        }

        if (manual_override_active_) {
            out += "Manual override: " + std::string(titan::Classifier::target_to_string(manual_override_)) + "\n";
        }

        return out;
    }

    void apply_profile(const std::string& profile) {
        auto& cfg = titan::Config::instance();
        // Profile controls idle power-off aggressiveness:
        //   saver       -> off immediately when idle (0s grace)
        //   balanced    -> config default idle timeout
        //   performance -> keep dGPU warm for 120s after last use
        uint32_t base_timeout = cfg.power().dgpu_idle_timeout_sec;
        if (profile == "saver") {
            profile_idle_timeout_ = 0;
        } else if (profile == "performance") {
            profile_idle_timeout_ = 120;
        } else {
            profile_idle_timeout_ = base_timeout;
        }

        // On saver profile, force iGPU when no explicit dGPU client
        if (profile == "saver" && !enforcer_->has_active_dgpu_clients()) {
            enforcer_->enforce_target(titan::GpuTarget::IGPU, /*idempotent=*/true);
            current_target_ = titan::GpuTarget::IGPU;
        } else if (profile == "performance" && !manual_override_active_) {
            enforcer_->enforce_target(titan::GpuTarget::DGPU, /*idempotent=*/true);
            current_target_ = titan::GpuTarget::DGPU;
        }

        std::cout << "[daemon] profile applied: " << profile
                  << " (idle_timeout=" << profile_idle_timeout_ << "s)\n";
    }

    void cleanup() {
        ipc_.disconnect();
        if (listen_fd_ >= 0) {
            close(listen_fd_);
            listen_fd_ = -1;
        }
        auto socket_path = get_socket_path();
        ::unlink(socket_path.c_str());

        auto dgpu = detector_.find_dgpu();
        if (dgpu) {
            power_.power_auto_dgpu(dgpu->pci_addr);
        }
    }

    titan::GpuDetector detector_;
    titan::PowerManager power_;
    std::unique_ptr<titan::GpuEnforcer> enforcer_;
    titan::HyprlandIpcBridge ipc_;
    titan::StateWriter state_writer_;
    std::unique_ptr<titan::WorkloadAnalyzer> workload_;

    titan::GpuTarget current_target_ = titan::GpuTarget::Auto;
    std::string active_app_;
    titan::GpuTarget manual_override_ = titan::GpuTarget::Auto;
    bool manual_override_active_ = false;
    std::string current_profile_ = "balanced";
    uint32_t profile_idle_timeout_ = 0;

    int listen_fd_ = -1;
};

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;

    struct sigaction sa{};
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGTERM, &sa, nullptr);
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGHUP, &sa, nullptr);

    Daemon daemon;
    if (!daemon.init()) {
        std::cerr << "[daemon] initialization failed\n";
        return 1;
    }

    daemon.run();
    return 0;
}
