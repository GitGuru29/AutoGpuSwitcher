#include "hyprland_ipc_bridge.hpp"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace titan {

std::string HyprlandIpcBridge::find_socket_path() {
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    if (!runtime) runtime = "/tmp";

    std::error_code ec;
    const char* hypr = std::getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (hypr && *hypr) {
        auto socket = std::filesystem::path(runtime) / "hypr" / hypr / ".socket2.sock";
        if (std::filesystem::exists(socket, ec)) return socket.string();
    }

    // Fallback for session-less starts (e.g. systemd --user units that do not
    // inherit HYPRLAND_INSTANCE_SIGNATURE): pick the most recently used
    // instance socket under $XDG_RUNTIME_DIR/hypr/.
    auto hypr_dir = std::filesystem::path(runtime) / "hypr";
    if (!std::filesystem::is_directory(hypr_dir, ec)) return {};

    std::filesystem::path best;
    std::filesystem::file_time_type best_time{};
    std::filesystem::directory_iterator it(hypr_dir, ec);
    if (ec) return {};

    for (; it != std::filesystem::directory_iterator(); it.increment(ec)) {
        if (ec) return {};
        if (!it->is_directory(ec) || ec) continue;

        auto socket = it->path() / ".socket2.sock";
        if (!std::filesystem::exists(socket, ec) || ec) continue;

        auto written = std::filesystem::last_write_time(socket, ec);
        if (ec) continue;

        if (best.empty() || written > best_time) {
            best = socket;
            best_time = written;
        }
    }

    return best.empty() ? std::string{} : best.string();
}

bool HyprlandIpcBridge::connect() {
    auto path = find_socket_path();
    if (path.empty()) {
        std::cerr << "[hyprland_ipc] no Hyprland instance socket found\n";
        return false;
    }

    if (path.size() >= sizeof(sockaddr_un::sun_path)) {
        std::cerr << "[hyprland_ipc] socket path too long: " << path << "\n";
        return false;
    }

    fd_ = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd_ < 0) {
        std::cerr << "[hyprland_ipc] socket() failed\n";
        return false;
    }

    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path, path.c_str(), path.size() + 1);

    if (::connect(fd_, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
        std::cerr << "[hyprland_ipc] connect to " << path << " failed\n";
        close(fd_);
        fd_ = -1;
        return false;
    }

    recv_buffer_.clear();
    had_connection_ = true;
    std::cout << "[hyprland_ipc] connected to " << path << "\n";
    return true;
}

void HyprlandIpcBridge::disconnect() {
    if (fd_ >= 0) {
        close(fd_);
        fd_ = -1;
    }
    recv_buffer_.clear();
}

bool HyprlandIpcBridge::poll(int timeout_ms) {
    if (fd_ < 0) {
        if (reconnect_cooldown_ > 0) {
            reconnect_cooldown_--;
            return false;
        }

        const bool was_connected = had_connection_;
        if (connect()) {
            std::cout << "[hyprland_ipc] " << (was_connected ? "reconnected" : "connected") << "\n";
            if (was_connected && reconnect_cb_) {
                reconnect_cb_();
            }
        if (reconnect_cooldown_-- > 0) return false;
        if (connect()) {
            std::cout << "[hyprland_ipc] reconnected\n";
            reconnect_cooldown_ = 0;
            pending_.clear();
        } else {
            reconnect_cooldown_ = 10;
        }
        return false;
    }

    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(fd_, &fds);

    struct timeval tv{};
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;

    int ret = select(fd_ + 1, &fds, nullptr, nullptr, &tv);
    if (ret < 0) {
        if (errno == EINTR) return false;
        disconnect();
        return false;
    }
    if (ret == 0) return false;

    // Drain until EAGAIN (was: single 4KB read per poll, could miss events)
    bool got_data = false;
    std::array<char, 4096> buf{};
    ssize_t n = recv(fd_, buf.data(), buf.size(), MSG_DONTWAIT);
    if (n == 0) {
        std::cerr << "[hyprland_ipc] connection closed by compositor\n";
        disconnect();
        return false;
    }
    if (n < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return false;
        std::cerr << "[hyprland_ipc] recv failed: " << std::strerror(errno) << "\n";
        disconnect();
        return false;
    }

    feed(std::string(buf.data(), static_cast<size_t>(n)));

    return true;
}

void HyprlandIpcBridge::dispatch_lines() {
    size_t start = 0;
    while (true) {
        auto nl = recv_buffer_.find('\n', start);
        if (nl == std::string::npos) break;
    while (true) {
        ssize_t n = recv(fd_, buf.data(), buf.size() - 1, MSG_DONTWAIT);
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            // Real error — close and mark for reconnect
            disconnect();
            return false;
        }
        if (n == 0) {
            // Peer closed (compositor restart) — mark for reconnect.
            // Was: returned false while fd_ >= 0, so reconnect branch
            // was never entered and window tracking died permanently.
            std::cerr << "[hyprland_ipc] connection closed by peer\n";
            disconnect();
            return false;
        }
        got_data = true;
        pending_.append(buf.data(), static_cast<size_t>(n));
    }

    if (!got_data) return false;

    // Process complete lines; carry partial line to next poll
    size_t pos = 0;
    while (true) {
        auto nl = pending_.find('\n', pos);
        if (nl == std::string::npos) break;
        auto event = pending_.substr(pos, nl - pos);
        pos = nl + 1;
        if (!event.empty()) {
            parse_event(event);
        }
    }
    pending_.erase(0, pos);  // keep incomplete tail

        auto event = recv_buffer_.substr(start, nl - start);
        start = nl + 1;
        if (!event.empty() && event.back() == '\r') event.pop_back();
        if (!event.empty()) parse_event(event);
    }
    recv_buffer_.erase(0, start);
}

bool HyprlandIpcBridge::parse_event(const std::string& event) {
    const std::string active_prefix = "activewindowv2>>";
    const std::string close_prefix = "closewindow>>";

    if (event.substr(0, active_prefix.size()) == active_prefix) {
        auto payload = event.substr(active_prefix.size());
        auto first_comma = payload.find(',');
        auto second_comma = payload.find(',', first_comma + 1);
        auto third_comma = payload.find(',', second_comma + 1);

        WindowEvent we;
        we.type = WindowEventType::Active;
        if (first_comma != std::string::npos) {
            we.addr = payload.substr(0, first_comma);
        }
        if (first_comma != std::string::npos && second_comma != std::string::npos) {
            we.pid = payload.substr(first_comma + 1, second_comma - first_comma - 1);
        }
        if (second_comma != std::string::npos) {
            if (third_comma != std::string::npos) {
                we.wm_class = payload.substr(second_comma + 1, third_comma - second_comma - 1);
            } else {
                we.wm_class = payload.substr(second_comma + 1);
            }
        }
        if (third_comma != std::string::npos) {
            we.title = payload.substr(third_comma + 1);
        }

        if (callback_ && !we.wm_class.empty()) {
            callback_(we);
        }
        return true;
    } else if (event.substr(0, close_prefix.size()) == close_prefix) {
        auto addr = event.substr(close_prefix.size());
        while (!addr.empty() && (addr.back() == '\r' || addr.back() == '\n' || addr.back() == ' '))
            addr.pop_back();

        WindowEvent we;
        we.type = WindowEventType::Closed;
        we.addr = addr;

        if (callback_ && !we.addr.empty()) {
            callback_(we);
        }
        return true;
    }

    return false;
}

}  // namespace titan
