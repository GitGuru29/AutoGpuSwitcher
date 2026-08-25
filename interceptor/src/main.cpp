#include <unistd.h>

#include <cstring>
#include <iostream>
#include <vector>

#include "env_policy.hpp"
#include "heavy_app_db.hpp"

void print_usage(const char* prog) {
    std::cout << "Usage:\n"
              << "  " << prog << " [--force-dgpu] [--dry-run] <binary_path_or_cmd> [args...]\n";
}

int main(int argc, char** argv) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    bool force_dgpu = false;
    bool dry_run = false;
    int target_idx = 1;

    while (target_idx < argc && argv[target_idx][0] == '-') {
        if (std::strcmp(argv[target_idx], "--force-dgpu") == 0) {
            force_dgpu = true;
            target_idx++;
        } else if (std::strcmp(argv[target_idx], "--dry-run") == 0) {
            dry_run = true;
            target_idx++;
        } else if (std::strcmp(argv[target_idx], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else {
            break;
        }
    }

    if (target_idx >= argc) {
        std::cerr << "[launcher] Error: no target application specified.\n";
        print_usage(argv[0]);
        return 1;
    }

    const char* target_cmd = argv[target_idx];
    bool heavy = force_dgpu || is_heavy_app(target_cmd);

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
