# AutoGpuSwitcher

Automatic GPU selection for Arch Linux hybrid graphics (Intel iGPU + NVIDIA dGPU).

AutoGpuSwitcher detects GPU-heavy applications, routes them to the discrete GPU,
and automatically powers the dGPU on/off based on workload patterns — saving
battery life without manual intervention.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    AutoGpuSwitcher                              │
│                                                                 │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐    │
│  │  Phase 1     │   │  Phase 2     │   │  Phase 3         │    │
│  │  Detection   │──►│  Interceptor │──►│  Integration     │    │
│  │  Pipeline    │   │  Launcher    │   │  Desktop/Shell   │    │
│  └──────────────┘   └──────────────┘   │  Systemd         │    │
│        │                                └──────────────────┘    │
│        ▼                                       │                │
│  heavy_apps.list ──────────────────────────────┘                │
│        │                                                        │
│        ▼                                                        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  Titan Daemon (subsystems/)                              │   │
│  │  • Hyprland IPC window tracking                          │   │
│  │  • PCI runtime power management                          │   │
│  │  • AC/Battery power heuristics                           │   │
│  │  • Unix socket CLI (titan-gpu)                           │   │
│  └──────────────────────────────────────────────────────────┘   │
│        ▲                                                        │
│        │  IPC delegation                                        │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  gpu_auto_switcher.py (workload history)                 │   │
│  │  • /proc scanning + nvidia-smi polling                   │   │
│  │  • Per-process GPU usage history                         │   │
│  │  • Time-of-day workload patterns                         │   │
│  │  • Auto-switch via Titan daemon → prime-select fallback  │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Phases

### Phase 1: Detection Pipeline (Bash)
- **pacman hook** — triggers on every package install/upgrade
- **ELF analyzer** — `ldd` + library matching against `heavy_libs.conf`
- **First-run scan** — scans all pre-installed packages
- **Persistent state** — `state/heavy_apps.list` (`pkg|app|/path`)

### Phase 2: Launch Interceptor (C++17)
- **`autogpuswitcher-launcher`** — wraps app execution
- Reads `heavy_apps.list`, applies NVIDIA PRIME env vars for heavy apps
- Supports `--force-dgpu`, `--dry-run` flags
- Logs every decision to `/tmp/autogpuswitcher-launcher.log`

### Phase 3: System Integration
- **Desktop** — generates `.desktop` entries for heavy apps
- **Shell** — Bash/Fish aliases + universal `autogpu-run` wrapper
- **Systemd** — timer for auto-switcher + daemon service

### Titan Daemon (C++17, independent subsystem)
- Monitors Hyprland window focus via IPC
- Powers dGPU on/off per window with reference counting
- AC/Battery power heuristics (`auto` → iGPU on battery, dGPU on AC)
- `titan-gpu` CLI over unix socket
- Waybar status module included
- 68 GTest tests

### Workload Auto-Switcher (Python 3)
- Scans `/proc` for user processes with GPU activity
- Polls `nvidia-smi` for real utilization + compute app PIDs
- Tracks per-process GPU usage history (rolling 100 observations)
- Learns time-of-day patterns for predictive switching
- Delegates to Titan daemon via IPC (falls back to prime-select/bbswitch)
- Runs via systemd timer every 5 minutes

## Quick Start

```bash
# 1. Build everything
cmake -B build -S subsystems/auto-gpu-switcher && cmake --build build
cmake -B interceptor/build -S interceptor && cmake --build interceptor/build

# 2. Run tests
./build/titan-gpu-tests
bash tests/run_all_scenarios.sh

# 3. Install system-wide
sudo ./setup/install_phase1.sh

# 4. Initial scan of existing packages
sudo ./setup/first_run.sh --yes --verbose

# 5. Enable auto-switching timer
sudo systemctl enable --now autogpuswitcher.timer

# 6. Start the Titan daemon (for window-based power management)
sudo systemctl enable --now titan-gpu-switcherd

# 7. Verify
autogpuswitcher-launcher --dry-run glxinfo
titan-gpu status
```

## Key Entrypoints

| Command | Purpose |
|---------|---------|
| `setup/first_run.sh` | Initial heavy-app scan |
| `setup/install_phase1.sh` | System-wide install (all phases) |
| `autogpuswitcher-launcher` | Launch app with dGPU offload |
| `titan-gpu status` | Show GPU/daemon status |
| `titan-gpu set igpu\|dgpu\|auto` | Manual GPU switch |
| `titan-gpu profile balanced\|saver\|performance` | Power profile |
| `python3 gpu_auto_switcher.py` | Run workload analysis cycle |

## Configuration

| File | Purpose |
|------|---------|
| `/etc/autogpuswitcher/autogpuswitcher.conf` | Analyzer paths and state |
| `/etc/titan-gpu/config` | Titan daemon rules (INI) |
| `analyzer/config/heavy_libs.conf` | GPU library patterns |
| `state/heavy_apps.list` | Detected heavy apps |

## Testing

```bash
# Full test suite (55 scenarios)
bash tests/run_all_scenarios.sh

# GTest unit tests (68 tests)
./build/titan-gpu-tests

# Sandbox test (mock sysfs + Hyprland)
bash subsystems/auto-gpu-switcher/tests/sandbox_test.sh

# Benchmark
bash subsystems/auto-gpu-switcher/tests/benchmark.sh
```

## Requirements

- Arch Linux (pacman, libalpm hooks)
- NVIDIA proprietary driver with PRIME support
- CMake ≥ 3.16, C++17 compiler (GCC or Clang)
- GoogleTest (for tests)
- Python 3 (stdlib only)
- Hyprland (for Titan daemon window tracking)
- Optional: Waybar (status module), bbswitch, prime-select

## Documentation

- [`docs/classification-mechanism.md`](docs/classification-mechanism.md) — full classification system reference
- [`docs/architecture.md`](docs/architecture.md) — Phase 1 architecture
- [`interceptor/README.md`](interceptor/README.md) — launcher build/usage
- [`integration/systemd/README.md`](integration/systemd/README.md) — service setup
- [`integration/shell/README.md`](integration/shell/README.md) — shell aliases
- [`integration/desktop/README.md`](integration/desktop/README.md) — desktop entries

## License

Apache 2.0
