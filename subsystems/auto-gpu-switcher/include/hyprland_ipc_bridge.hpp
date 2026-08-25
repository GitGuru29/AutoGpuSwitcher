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

class HyprlandIpcBridge {
public:
    bool connect();
    void disconnect();
    bool is_connected() const { return fd_ >= 0; }

    bool poll(int timeout_ms);
    void set_callback(WindowCallback cb) { callback_ = std::move(cb); }
    bool parse_event(const std::string& event);

private:
    std::string find_socket_path();

    int fd_ = -1;
    WindowCallback callback_;
};

}  // namespace titan
