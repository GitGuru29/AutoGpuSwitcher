#pragma once

#include <cstdlib>
#include <iostream>

namespace titan {

// Per-focus/per-event logging gate. Default OFF to avoid journald churn
// (every Alt-Tab used to emit 4+ lines). Enable with TITAN_DEBUG=1.
inline bool debug_enabled() {
    static const bool enabled = [] {
        const char* v = std::getenv("TITAN_DEBUG");
        return v && *v && *v != '0';
    }();
    return enabled;
}

}  // namespace titan

// Logs only when TITAN_DEBUG=1 (hot path / per-focus events)
#define TITAN_DEBUG_LOG(msg)                     \
    do {                                         \
        if (::titan::debug_enabled()) {          \
            std::cout << msg;                    \
        }                                        \
    } while (0)

// Always logs (lifecycle, power transitions, errors)
#define TITAN_LOG(msg) std::cout << msg
