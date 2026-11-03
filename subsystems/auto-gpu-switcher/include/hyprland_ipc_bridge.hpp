#pragma once

#include <cstdint>
#include <functional>
#include <string>

namespace titan {

enum class WindowEventType {
    Active,
    Closed,
};

struct WindowEvent {
    WindowEventType type = WindowEventType::Active;
    std::string addr;
    std::string pid;
    std::string wm_class;
    std::string title;
};

using WindowCallback = std::function<void(const WindowEvent&)>;
using ReconnectCallback = std::function<void()>;

class HyprlandIpcBridge {
public:
    bool connect();
    void disconnect();
    bool is_connected() const { return fd_ >= 0; }

    bool poll(int timeout_ms);
    void set_callback(WindowCallback cb) { callback_ = std::move(cb); }
    void set_reconnect_callback(ReconnectCallback cb) { reconnect_cb_ = std::move(cb); }
    bool parse_event(const std::string& event);

    // Feeds raw socket bytes through the line dispatcher; used by poll() and tests.
    void feed(const std::string& data) {
        recv_buffer_.append(data);
        dispatch_lines();
    }

private:
    std::string find_socket_path();
    void dispatch_lines();

    int fd_ = -1;
    int reconnect_cooldown_ = 0;
    bool had_connection_ = false;
    std::string recv_buffer_;
    WindowCallback callback_;
    ReconnectCallback reconnect_cb_;
};

}  // namespace titan
