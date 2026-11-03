# Interceptor — Launch-Time dGPU Offload Launcher

C++17 launcher that intercepts application execution and applies NVIDIA
PRIME Render Offload environment variables for detected heavy apps.

## How It Works

```
User runs:  autogpuswitcher-launcher steam
                │
                ▼
        ┌──────────────────┐
        │ is_heavy_app()?  │──┐
        └──────────────────┘  │
              │               │ reads heavy_apps.list
              ▼               │ (3 match strategies:
     ┌──────────────┐         │  path, basename, app-name)
     │  HEAVY?      │         │
     └──────┬───────┘         │
       yes  │  no             │
        ┌───┴───┐             │
        ▼       ▼             │
   apply env   default GPU    │
        │       │             │
        └───┬───┘             │
            ▼                 │
       execvp(cmd, args)  ◄───┘
       (process replaced,
        inherits env vars)
```

## Environment Variables Applied (heavy apps only)

| Variable | Value | Purpose |
|----------|-------|---------|
| `__NV_PRIME_RENDER_OFFLOAD` | `1` | Enable PRIME render offload |
| `__GLX_VENDOR_LIBRARY_NAME` | `nvidia` | Force GLX to use NVIDIA |
| `__VK_LAYER_NV_optimus` | `NVIDIA_only` | Force Vulkan to use NVIDIA |
| `QT_QPA_PLATFORM` | `xcb` | Qt apps: use XCB instead of Wayland (Wayland+XCB → XCB) |

## Build

```bash
cmake -B build -S interceptor
cmake --build build -j$(nproc)
```

Binary: `interceptor/build/autogpuswitcher-launcher`

## Install

```bash
# Via the installer (recommended)
sudo ./setup/install_phase1.sh

# Or manually
sudo install -m 0755 interceptor/build/autogpuswitcher-launcher /usr/bin/
```

## Usage

```bash
# Basic — decides based on heavy_apps.list
autogpuswitcher-launcher <command> [args...]

# Force dGPU regardless of list
autogpuswitcher-launcher --force-dgpu <command> [args...]

# Dry-run — show decision without executing
autogpuswitcher-launcher --dry-run <command> [args...]

# Examples
autogpuswitcher-launcher steam
autogpuswitcher-launcher --force-dgpu blender --factory-startup
autogpuswitcher-launcher --dry-run glxinfo | grep "OpenGL renderer"
```

## Decision Logging

Every launch decision is logged to `/tmp/autogpuswitcher-launcher.log`:

```
2026-10-07 13:00:12 | app=/usr/bin/steam | decision=dGPU | reason=heavy
2026-10-07 13:00:15 | app=/usr/bin/vim | decision=iGPU | reason=standard
```

Override log path with `AUTOGPUSWITCHER_LOG_FILE` env var.

## Heavy App List Lookup

Reads `heavy_apps.list` (record format: `package|app|/path`) from:

1. `$AUTOGPUSWITCHER_HEAVY_LIST_FILE` env var
2. `/var/lib/autogpuswitcher/heavy_apps.list` (system install)
3. `state/heavy_apps.list` (dev checkout)

Three match strategies (in priority order):
1. **Exact path match** — `/usr/bin/steam`
2. **Basename vs binary path** — `steam` in `/usr/bin/steam`
3. **Basename vs app name** — `steam` in record's app field

## Testing

```bash
# Dry-run test
./interceptor/build/autogpuswitcher-launcher --dry-run /usr/bin/env

# Force dGPU test
./interceptor/build/autogpuswitcher-launcher --force-dgpu --dry-run /usr/bin/env

# Missing list fallback test
AUTOGPUSWITCHER_HEAVY_LIST_FILE=/nonexistent ./interceptor/build/autogpuswitcher-launcher --dry-run /usr/bin/ls

# Run full test suite (includes interceptor cases 8, 11-18)
bash tests/run_all_scenarios.sh
```
