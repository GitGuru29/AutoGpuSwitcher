#include "cli.hpp"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>

#include "config.hpp"
#include "gpu_detector.hpp"
#include "power_manager.hpp"
#include "workload_classifier.hpp"

namespace titan {

static std::string get_socket_path() {
    const char* env = std::getenv("TITAN_SOCKET_PATH");
    return env ? std::string(env) : "/tmp/titan-gpu-daemon.sock";
}

static bool send_command(const std::string& cmd) {
    auto socket_path = get_socket_path();
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        std::cerr << "cannot create socket\n";
        return false;
    }

    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, socket_path.c_str(), sizeof(addr.sun_path) - 1);

    if (::connect(fd, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
        std::cerr << "daemon not running (socket: " << socket_path << ")\n";
        close(fd);
        return false;
    }

    send(fd, cmd.c_str(), cmd.size(), 0);

    char buf[4096]{};
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    close(fd);

    if (n > 0) {
        std::cout.write(buf, n);
        return true;
    }
    return false;
}

static void print_usage() {
    std::cout << "titan-gpu — GPU switching CLI\n\n"
              << "Commands:\n"
              << "  status              Show GPU status\n"
              << "  set <igpu|dgpu|auto>  Manual GPU override\n"
              << "  power <on|off|auto>   Force dGPU power state\n"
              << "  profile <name>        Switch power profile\n"
              << "  reload                Reload daemon config\n"
              << "\n";
}

static void local_status() {
    GpuDetector det;
    det.scan();

    PowerManager pm;
    pm.init();

    Config::instance().load(Config::default_path());

    auto dgpu = det.find_dgpu();

    std::cout << "GPUs:\n";
    for (const auto& g : det.gpus()) {
        std::cout << "  " << g.vendor_name << " [" << g.pci_addr << "]"
                  << " render=" << g.render_node
                  << " connected=" << (g.is_connected ? "yes" : "no") << "\n";
    }

    std::cout << "\nPower source: " << (pm.is_on_battery() ? "battery" : "AC") << "\n";

    if (dgpu) {
        auto ps = pm.get_pci_power(dgpu->pci_addr);
        const char* ps_str = ps == PowerState::On ? "on" : ps == PowerState::Off ? "off" : "auto";
        std::cout << "dGPU power: " << ps_str << "\n";
    } else {
        std::cout << "dGPU: not found (iGPU only)\n";
    }
}

int cli_main(int argc, char** argv) {
    if (argc < 2) {
        print_usage();
        return 0;
    }

    std::string cmd = argv[1];

    if (cmd == "status") {
        if (!send_command("status\n")) {
            local_status();
        }
        return 0;
    }

    if (cmd == "set" && argc >= 3) {
        std::string msg = "set " + std::string(argv[2]) + "\n";
        if (!send_command(msg)) {
            std::cerr << "failed to communicate with daemon\n";
            return 1;
        }
        return 0;
    }

    if (cmd == "power" && argc >= 3) {
        std::string msg = "power " + std::string(argv[2]) + "\n";
        if (!send_command(msg)) {
            std::cerr << "failed to communicate with daemon\n";
            return 1;
        }
        return 0;
    }

    if (cmd == "profile" && argc >= 3) {
        std::string msg = "profile " + std::string(argv[2]) + "\n";
        if (!send_command(msg)) {
            std::cerr << "failed to communicate with daemon\n";
            return 1;
        }
        return 0;
    }

    if (cmd == "reload") {
        if (!send_command("reload\n")) {
            std::cerr << "failed to communicate with daemon\n";
            return 1;
        }
        return 0;
    }

    print_usage();
    return 1;
}

}  // namespace titan
