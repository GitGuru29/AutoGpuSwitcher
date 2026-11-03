#pragma once

#include <cstdlib>
#include <string>

namespace titan {

inline std::string get_socket_path() {
    const char* env = std::getenv("TITAN_SOCKET_PATH");
    return env ? std::string(env) : "/tmp/titan-gpu-daemon.sock";
}

}  // namespace titan
