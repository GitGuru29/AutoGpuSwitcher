#include <unistd.h>

#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <vector>

#include "env_policy.hpp"
#include "heavy_app_db.hpp"

void print_usage(const char* prog) {
    std::cout << "Usage:\n"
              << "  " << prog << " [--force-dgpu] [--dry-run] [--] <binary_path_or_cmd> [args...]\n"
              << "\n"
              << "Options:\n"
              << "  --force-dgpu  Apply the dGPU environment regardless of the heavy app list\n"
              << "  --dry-run     Report the decision without executing anything\n"
              << "  --help        Show this help\n";
}

int main(int argc, char** argv) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    bool force_dgpu = false;
    bool dry_run = false;
    int target_idx = 1;

    for (; target_idx < argc; ++target_idx) {
        const char* arg = argv[target_idx];

        if (arg[0] != '-' || arg[1] == '\0') break;  // target, not an option
        if (std::strcmp(arg, "--") == 0) {
            ++target_idx;
            break;
        }
        if (std::strcmp(arg, "--force-dgpu") == 0) {
            force_dgpu = true;
        } else if (std::strcmp(arg, "--dry-run") == 0) {
            dry_run = true;
        } else if (std::strcmp(arg, "--help") == 0 || std::strcmp(arg, "-h") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            std::cerr << "[launcher] Error: unknown option " << arg << "\n";
            print_usage(argv[0]);
            return 2;
        }
    }

    if (target_idx >= argc) {
        std::cerr << "[launcher] Error: no target application specified.\n";
        print_usage(argv[0]);
        return 1;
    }

    const char* target_cmd = argv[target_idx];

    if (!force_dgpu && !std::filesystem::exists(get_heavy_list_path())) {
        std::cerr << "[launcher] warning: heavy app list not found at "
                  << get_heavy_list_path() << " (treating apps as non-heavy)\n";
    }

    const bool heavy = force_dgpu || is_heavy_app(target_cmd);

    if (heavy) {
        apply_dgpu_environment();
        std::cout << "[launcher] heavy app detected (" << target_cmd
                  << ") -> applied NVIDIA PRIME offload environment\n";
    } else {
        std::cout << "[launcher] standard app detected (" << target_cmd
                  << ") -> running on default GPU\n";
    }

    if (dry_run) {
        std::cout << "[launcher] dry-run complete for " << target_cmd << "\n";
        return 0;
    }

    std::vector<char*> exec_args;
    for (int i = target_idx; i < argc; i++) {
        exec_args.push_back(argv[i]);
    }
    exec_args.push_back(nullptr);

    execvp(exec_args[0], exec_args.data());

    std::cerr << "[launcher] Error: failed to execute " << target_cmd << ": "
              << std::strerror(errno) << "\n";
    return 127;
}
