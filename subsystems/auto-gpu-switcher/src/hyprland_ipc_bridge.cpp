#include "hyprland_ipc_bridge.hpp"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>

namespace titan {

std::string HyprlandIpcBridge::find_socket_path() {
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    if (!runtime) runtime = "/tmp";

    const char* hypr = std::getenv("HYPRLAND_INSTANCE_SIGNATURE");
    if (!hypr) return {};

    return std::string(runtime) + "/hypr/" + hypr + "/.socket2.sock";
}

bool HyprlandIpcBridge::connect() {
    auto path = find_socket_path();
    if (path.empty()) {
        std::cerr << "[hyprland_ipc] HYPRLAND_INSTANCE_SIGNATURE not set\n";
        return false;
    }

    fd_ = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd_ < 0) {
        std::cerr << "[hyprland_ipc] socket() failed\n";
        return false;
    }

    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

    if (::connect(fd_, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
        std::cerr << "[hyprland_ipc] connect to " << path << " failed\n";
        close(fd_);
        fd_ = -1;
        return false;
    }

    std::cout << "[hyprland_ipc] connected to " << path << "\n";
    return true;
}

void HyprlandIpcBridge::disconnect() {
    if (fd_ >= 0) {
        close(fd_);
        fd_ = -1;
    }
}

bool HyprlandIpcBridge::poll(int timeout_ms) {
    if (fd_ < 0) {
        static int reconnect_cooldown = 0;
        if (reconnect_cooldown-- > 0) return false;
        if (connect()) {
            std::cout << "[hyprland_ipc] reconnected\n";
            reconnect_cooldown = 0;
        } else {
            reconnect_cooldown = 10;
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
    if (ret <= 0) return false;

    std::array<char, 4096> buf{};
    ssize_t n = recv(fd_, buf.data(), buf.size() - 1, MSG_DONTWAIT);
    if (n <= 0) return false;

    std::string data(buf.data(), static_cast<size_t>(n));

    size_t pos = 0;
    while (pos < data.size()) {
        auto nl = data.find('\n', pos);
        if (nl == std::string::npos) nl = data.size();
        auto event = data.substr(pos, nl - pos);
        pos = nl + 1;

        if (!event.empty()) {
            parse_event(event);
        }
    }

    return true;
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
