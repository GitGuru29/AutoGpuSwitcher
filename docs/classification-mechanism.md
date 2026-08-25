# Classification Mechanism — How Apps Are Assigned to GPUs

AutoGpuSwitcher uses **two independent classification systems** that operate at different layers of the application lifecycle. One determines GPU assignment at install/launch time by inspecting binary library dependencies, and the other manages GPU power states at runtime based on window focus events from the Hyprland compositor.

---

## Table of Contents

1. [System 1: Library-Based Classification (Install-Time)](#system-1-library-based-classification-install-time)
   - [1.1 Rule Database](#11-rule-database)
   - [1.2 Pacman Hook Trigger](#12-pacman-hook-trigger)
   - [1.3 Package Filtering Pipeline](#13-package-filtering-pipeline)
   - [1.4 Binary Analysis (ldd)](#14-binary-analysis-ldd)
   - [1.5 Record Format and Persistence](#15-record-format-and-persistence)
   - [1.6 Launch-Time Interceptor](#16-launch-time-interceptor)
2. [System 2: Window-Class-Based Classification (Runtime)](#system-2-window-class-based-classification-runtime)
   - [2.1 Configuration Rule Database](#21-configuration-rule-database)
   - [2.2 Config Loading (INI Parser)](#22-config-loading-ini-parser)
   - [2.3 Classification Chain](#23-classification-chain)
   - [2.4 Event Source: Hyprland IPC](#24-event-source-hyprland-ipc)
   - [2.5 GPU Power Enforcement](#25-gpu-power-enforcement)
   - [2.6 Manual Override and Idle Timeout](#26-manual-override-and-idle-timeout)
3. [Hardware Detection](#hardware-detection)
4. [Decision Tree](#decision-tree)
5. [Key Files Reference](#key-files-reference)
6. [Environment Variables](#environment-variables)

---

## System 1: Library-Based Classification (Install-Time)

### 1.1 Rule Database

**File:** `analyzer/config/heavy_libs.conf`

```
libGL.so
libEGL.so
libGLESv2.so
libvulkan.so
libOpenCL.so
```

This is the **sole source of truth** for what constitutes a "heavy" (GPU-demanding) application. If any ELF binary dynamically links against any of these shared libraries, it is classified as heavy and should run on the discrete GPU (dGPU).

The libraries cover the major GPU APIs:

| Library | API |
|---------|-----|
| `libGL.so` | OpenGL (traditional desktop rendering) |
| `libEGL.so` | EGL (cross-platform GPU context management) |
| `libGLESv2.so` | OpenGL ES (embedded/mobile graphics) |
| `libvulkan.so` | Vulkan (low-level modern GPU API) |
| `libOpenCL.so` | OpenCL (GPU compute / GPGPU) |

The list is configurable — adding or removing lines in this file changes which libraries trigger classification.

### 1.2 Pacman Hook Trigger

**File:** `pacman-hook/hooks/autogpuswitcher.hook`

```ini
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = *

[Action]
Description = Queue AutoGpuSwitcher analysis for newly installed packages
When = PostTransaction
NeedsTargets
Exec = /usr/bin/env bash /usr/lib/autogpuswitcher/pacman-hook/post_transaction.sh
```

This is a **libalpm hook** that fires automatically after every `pacman -S`, `pacman -Syu`, or any install/upgrade transaction. The key behavior:

- `Target = *` — triggers for **every** package
- `When = PostTransaction` — runs **after** the transaction completes
- `NeedsTargets` — passes the list of affected package names to the script via **stdin**

**File:** `pacman-hook/post_transaction.sh`

The hook script reads package names from stdin and passes them to `analyze_package.sh --record`, which performs the actual binary analysis. All output is logged to `state/logs/pacman-hook.log`.

### 1.3 Package Filtering Pipeline

Before any binary is analyzed, it passes through a multi-stage filtering pipeline implemented in `analyzer/scripts/common.sh`:

#### Stage 1: Package Name Filtering (`is_candidate_package`)

```bash
is_candidate_package() {
    local package_name="${1:-}"
    [[ -n "${package_name}" ]] || return 1
    [[ "${package_name}" != *-headers ]] || return 1    # skip -headers packages
    [[ "${package_name}" != lib32-* ]] || return 1      # skip lib32- multilib packages
    return 0
}
```

Packages ending in `-headers` (kernel/dev headers) and starting with `lib32-` (32-bit compatibility libraries) are excluded since they don't contain launchable applications.

#### Stage 2: Path Filtering (`path_is_candidate_root`)

```bash
path_is_candidate_root() {
    local path="${1:-}"
    [[ "${path}" == /usr/bin/* ]] && return 0
    [[ "${path}" == /usr/sbin/* ]] && return 0
    [[ "${path}" == /opt/* ]] && return 0
    [[ "${path}" == /usr/lib/* ]] && return 0
    return 1
}
```

Only files under these directories are examined — the standard locations for executable binaries on Arch Linux.

#### Stage 3: File Type Filtering (`is_elf_executable` + `should_scan_path`)

The file must:
1. Exist and be executable (`-f` and `-x`)
2. Pass `path_is_candidate_root` (Stage 2)
3. Not be a debug file (`*.debug`, `/usr/lib/debug/*`)
4. Not be a shared library (`*.so`, `*.so.*`)
5. Not be a header or share file (`/usr/include/*`, `/usr/share/*`)
6. Be an ELF executable as determined by `file -Lb`:
   ```bash
   grep -Eq 'ELF .* (executable|pie executable),' <<< "${file_output}"
   ```

This ensures only actual launchable binaries are analyzed, not libraries, headers, debug symbols, or non-ELF files.

### 1.4 Binary Analysis (ldd)

**File:** `analyzer/scripts/analyze_binary.sh`

The core classification function:

```bash
binary_uses_heavy_libs() {
    local binary_path="$1"
    local ldd_output
    local pattern

    ldd_output=$(ldd "${binary_path}" 2>/dev/null || true)
    [[ -n "${ldd_output}" ]] || return 1

    for pattern in "${heavy_patterns[@]}"; do
        if grep -Fq "${pattern}" <<< "${ldd_output}"; then
            return 0
        fi
    done
    return 1
}
```

**How it works:**

1. Runs `ldd` on the target binary to list all dynamically linked shared libraries
2. Iterates through each pattern from `heavy_libs.conf`
3. Uses `grep -Fq` (fixed-string, quiet) to check if any heavy library name appears in the `ldd` output
4. If **any** match is found, the binary is classified as heavy

**Example:**
```bash
$ ldd /usr/bin/mpv
    libGL.so.1 => /usr/lib/libGL.so.1
    libEGL.so.1 => /usr/lib/libEGL.so.1
    ...
```
Both `libGL.so` and `libEGL.so` are found in the output → mpv is classified as heavy.

### 1.5 Record Format and Persistence

Classified binaries are recorded in a pipe-delimited format:

```
package-name|app-name|/full/path/to/binary
```

**Example records:**
```
mpv|mpv|/usr/bin/mpv
unknown|blender|/usr/bin/blender
steam-native-runtime|steam|/usr/bin/steam
```

The `format_heavy_app_record` function in `common.sh`:
```bash
format_heavy_app_record() {
    local package_name="${1:-unknown}"
    local app_name="${2:-}"
    local binary_path="${3:-}"
    printf '%s|%s|%s\n' "${package_name}" "${app_name}" "${binary_path}"
}
```

Records are merged into `state/heavy_apps.list` via `update_heavy_list.sh`, which **deduplicates** and **sorts** the entries. This file is the persistent database that the launcher reads at runtime.

**Current database size:** 191 entries (as of initial scan).

### 1.6 Launch-Time Interceptor

**File:** `interceptor/src/main.cpp`

When a user launches an application through the interceptor binary (`autogpuswitcher-launcher`), the following happens:

```
Usage:
  autogpuswitcher-launcher [--force-dgpu] [--dry-run] <binary_path_or_cmd> [args...]
```

**Step 1: Check if the app is heavy**

```cpp
const char* target_cmd = argv[target_idx];
bool heavy = force_dgpu || is_heavy_app(target_cmd);
```

**Step 2: Database lookup (`interceptor/src/heavy_app_db.cpp`)**

The `is_heavy_app()` function reads `state/heavy_apps.list` and performs matching:

```cpp
bool is_heavy_app(const char* target_path_or_name) {
    // ...
    while (std::getline(file, line)) {
        // Parse pipe-delimited record
        if (tokens.size() >= 3) {
            // 3-field record: package|app_name|path
            if (target_str == bin_path ||          // exact path match
                target_base == app_name ||         // basename matches app name
                target_base == get_basename(bin_path))  // basename matches binary path
                return true;
        } else if (tokens.size() == 1) {
            // 1-field record: app_name or path
            if (target_str == rec || target_base == get_basename(rec))
                return true;
        }
    }
    return false;
}
```

**Three matching strategies for 3-field records:**

| Match Type | Example | What it checks |
|------------|---------|----------------|
| Exact path | `/usr/bin/mpv` == `/usr/bin/mpv` | Full absolute path matches exactly |
| Basename vs app name | `mpv` == `mpv` | The target's basename matches the recorded app name |
| Basename vs binary path | `mpv` == `mpv` | The target's basename matches the basename of the recorded binary path |

The list file search path priority:
1. `$AUTOGPUSWITCHER_HEAVY_LIST_FILE` environment variable
2. `/var/lib/autogpuswitcher/heavy_apps.list`
3. `state/heavy_apps.list` (relative path)

**Step 3: Apply dGPU environment (`interceptor/src/env_policy.cpp`)**

If the app is heavy (or `--force-dgpu` was passed):

```cpp
void apply_dgpu_environment() {
    setenv("__NV_PRIME_RENDER_OFFLOAD", "1", 1);
    setenv("__GLX_VENDOR_LIBRARY_NAME", "nvidia", 1);
    setenv("__VK_LAYER_NV_optimus", "NVIDIA_only", 1);

    const char* qt_plat = std::getenv("QT_QPA_PLATFORM");
    if (qt_plat && std::string(qt_plat) == "wayland;xcb") {
        setenv("QT_QPA_PLATFORM", "xcb", 1);
    }
}
```

These environment variables tell **NVIDIA PRIME Render Offload** to route all rendering through the discrete GPU:

| Variable | Value | Purpose |
|----------|-------|---------|
| `__NV_PRIME_RENDER_OFFLOAD` | `1` | Enables PRIME render offloading |
| `__GLX_VENDOR_LIBRARY_NAME` | `nvidia` | Forces GLX to use the NVIDIA driver |
| `__VK_LAYER_NV_optimus` | `NVIDIA_only` | Forces Vulkan to use the NVIDIA device |
| `QT_QPA_PLATFORM` | `xcb` (override) | Qt Wayland+XCB fallback → pure XCB for dGPU compat |

**Step 4: Execute the target application**

```cpp
execvp(exec_args[0], exec_args.data());
```

The interceptor replaces itself with the target application, which now inherits the dGPU environment variables.

---

## System 2: Window-Class-Based Classification (Runtime)

### 2.1 Configuration Rule Database

**File:** `subsystems/auto-gpu-switcher/configs/titan-gpu.config.default`

```ini
[power]
default_profile = balanced
battery_profile = saver
dgpu_idle_timeout_sec = 30
power_transition_timeout_ms = 1000

[detector]
nvidia_driver = auto
render_node_igpu =
render_node_dgpu =

[apps]
steam = dgpu
lutris = dgpu
blender = dgpu
obs-studio = dgpu
mpv = dgpu
kitty = igpu
falkon = igpu
code = igpu

[patterns]
*game* = dgpu
*browser* = igpu
*editor* = igpu
*terminal* = igpu
```

This INI-style configuration is loaded from `/etc/titan-gpu/config` (or `$TITAN_CONFIG_PATH`). It has four sections:

| Section | Purpose |
|---------|---------|
| `[power]` | Idle timeout, power transition timing, power profiles |
| `[detector]` | NVIDIA driver path, render node paths |
| `[apps]` | **Exact-match rules**: window class → GPU target |
| `[patterns]` | **Glob-pattern rules**: window class pattern → GPU target |

**GPU target values:**

| Target | Meaning |
|--------|---------|
| `dgpu` | Always use the discrete GPU |
| `igpu` | Always use the integrated GPU |
| `auto` | Decide based on power source (battery → iGPU, AC → dGPU) |

### 2.2 Config Loading (INI Parser)

**File:** `subsystems/auto-gpu-switcher/src/config.cpp`

The config parser processes the INI file line by line:

```cpp
bool Config::parse_line(const std::string& raw, std::string& section) {
    auto line = trim(raw);
    if (line.empty() || line[0] == '#') return true;    // skip comments and empty lines

    if (line.front() == '[' && line.back() == ']') {    // section header
        section = trim(line.substr(1, line.size() - 2));
        return true;
    }

    auto eq = line.find('=');
    if (eq == std::string::npos) return true;            // skip malformed lines

    auto key = trim(line.substr(0, eq));
    auto val = trim(line.substr(eq + 1));
    auto lkey = to_lower(key);                           // case-insensitive keys

    if (section == "apps") {
        apps_[lkey] = AppConfig{val};                    // exact match rule
    } else if (section == "patterns") {
        patterns_[lkey] = val;                            // glob pattern rule
    }
    // ... power and detector sections
    return true;
}
```

Key behaviors:
- **Case-insensitive keys** — `Steam`, `steam`, and `STEAM` all match
- **Comments** — lines starting with `#` are ignored
- **Whitespace trimming** — surrounding spaces/tabs are stripped from keys and values
- **Reloadable** — `Config::reload()` clears and re-parses the file (triggered by `SIGHUP` or socket command)

### 2.3 Classification Chain

The classification happens in a **three-stage pipeline**:

#### Stage 1: Rule Lookup (`Config::classify_app`)

**File:** `config.cpp:124-137`

```cpp
std::string Config::classify_app(const std::string& wm_class) const {
    auto lc = to_lower(wm_class);

    // 1. Exact match in [apps] section (case-insensitive)
    auto it = apps_.find(lc);
    if (it != apps_.end()) return it->second.gpu_target;

    // 2. Glob pattern match in [patterns] section
    for (const auto& [pat, gpu_target] : patterns_) {
        if (glob_match(lc, pat)) {
            return gpu_target;
        }
    }

    // 3. Default: "auto"
    return "auto";
}
```

**Matching priority:**
1. **Exact match first** — O(1) hash map lookup in the `[apps]` section
2. **Glob pattern match second** — linear scan through `[patterns]` using a custom glob implementation
3. **Default** — if nothing matches, return `"auto"`

**Glob implementation** (`config.cpp:59-82`):

```cpp
static bool glob_match(const std::string& text, const std::string& pattern) {
    size_t ti = 0, pi = 0;
    size_t star_pi = std::string::npos, star_ti = 0;

    while (ti < text.size()) {
        if (pi < pattern.size() && pattern[pi] == '*') {
            star_pi = pi;       // remember the star's position
            star_ti = ti;       // remember current text position
            pi++;
        } else if (pi < pattern.size() && (pattern[pi] == text[ti] || pattern[pi] == '?')) {
            pi++; ti++;
        } else if (star_pi != std::string::npos) {
            pi = star_pi + 1;   // backtrack to after the star
            star_ti++;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while (pi < pattern.size() && pattern[pi] == '*') pi++;
    return pi == pattern.size();
}
```

Supports `*` (match any characters) and `?` (match single character). Example: `*game*` matches `steam-game-overlay`, `gamemode`, etc.

#### Stage 2: Power Heuristic (`Classifier::classify_with_power`)

**File:** `workload_classifier.cpp:12-22`

```cpp
GpuTarget Classifier::classify_with_power(GpuTarget rule_result, bool on_battery) const {
    if (rule_result == GpuTarget::Auto) {
        if (on_battery) {
            return GpuTarget::IGPU;   // Battery -> save power, use iGPU
        }
        return GpuTarget::DGPU;       // AC power -> use dGPU for performance
    }
    return rule_result;  // Explicit rules are never overridden
}
```

**Logic:**
- **Explicit `dgpu` or `igpu` rules** → always honored, regardless of power source
- **`auto` rule** → resolved dynamically:
  - **On battery** → iGPU (power saving)
  - **On AC power** → dGPU (performance)

Power source detection (`power_manager.cpp:37-43`):
```cpp
PowerSource PowerManager::current_source() const {
    std::ifstream f(ac_path_);    // reads /sys/class/power_supply/AC/online
    int val = 0;
    f >> val;
    return val == 1 ? PowerSource::AC : PowerSource::Battery;
}
```

#### Stage 3: GPU Target String Conversion

**File:** `workload_classifier.cpp:33-40`

```cpp
GpuTarget Classifier::string_to_target(const std::string& s) {
    std::string lower = s;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (lower == "igpu") return GpuTarget::IGPU;
    if (lower == "dgpu") return GpuTarget::DGPU;
    return GpuTarget::Auto;
}
```

Converts the string result from Stage 1 into a `GpuTarget` enum before passing to Stage 2.

### 2.4 Event Source: Hyprland IPC

**File:** `subsystems/auto-gpu-switcher/src/hyprland_ipc_bridge.cpp`

The daemon connects to Hyprland's event socket to receive real-time window events.

**Socket discovery:**
```cpp
std::string HyprlandIpcBridge::find_socket_path() {
    const char* runtime = std::getenv("XDG_RUNTIME_DIR");
    const char* hypr = std::getenv("HYPRLAND_INSTANCE_SIGNATURE");
    return std::string(runtime) + "/hypr/" + hypr + "/.socket2.sock";
}
```

**Two event types are handled:**

| Event | Format | Trigger |
|-------|--------|---------|
| `activewindowv2>>` | `addr,pid,wm_class,title` | User switches window focus |
| `closewindow>>` | `addr` | A window is closed |

**Event parsing (`parse_event`):**
```cpp
if (event.substr(0, active_prefix.size()) == active_prefix) {
    auto payload = event.substr(active_prefix.size());
    // Extract: addr, pid, wm_class, title (comma-separated)
    WindowEvent we;
    we.type = WindowEventType::Active;
    we.addr = payload.substr(0, first_comma);
    we.pid = payload.substr(first_comma + 1, second_comma - first_comma - 1);
    we.wm_class = payload.substr(second_comma + 1, third_comma - second_comma - 1);
    we.title = payload.substr(third_comma + 1);

    if (callback_ && !we.wm_class.empty()) {
        callback_(we);   // triggers classification chain
    }
}
```

The `wm_class` field is the **X11/Wayland window class name** (e.g., `steam`, `kitty`, `blender`). This is the identifier used to match against the config rules.

**Connection management:**
- Auto-reconnects with cooldown on disconnect
- Uses `select()` with configurable timeout for non-blocking polling
- Receives data in 4096-byte chunks and splits on newlines

### 2.5 GPU Power Enforcement

**File:** `subsystems/auto-gpu-switcher/src/gpu_enforcer.cpp`

After classification, the enforcer manages the physical GPU power state.

**Core enforcement function:**
```cpp
EnforcementResult GpuEnforcer::enforce_for_app_window(
    const std::string& wm_class, const std::string& window_addr) {
    
    auto& cfg = Config::instance();
    auto rule = cfg.classify_app(wm_class);              // Stage 1
    Classifier classifier;
    auto target = classifier.classify_with_power(        // Stage 2
        Classifier::string_to_target(rule), power_.is_on_battery());
    return enforce_target_window(target, window_addr);   // Stage 3
}
```

**Window-aware enforcement (`enforce_target_window`):**
```cpp
EnforcementResult GpuEnforcer::enforce_target_window(
    GpuTarget target, const std::string& window_addr) {
    
    EnforcementResult result;
    result.target = target;

    if (target == GpuTarget::DGPU) {
        if (!has_active_dgpu_clients()) {
            // First dGPU client → power on the dGPU
            auto dgpu = detector_.find_dgpu();
            if (dgpu) {
                result.power_transitioned = power_.power_on_dgpu(dgpu->pci_addr);
            }
        }
        active_dgpu_windows_.insert(window_addr);   // track this window
    } else if (target == GpuTarget::IGPU) {
        if (active_dgpu_windows_.erase(window_addr) > 0) {
            // Window removed from dGPU tracking
            if (!has_active_dgpu_clients()) {
                // No more dGPU clients → allow power off
                auto dgpu = detector_.find_dgpu();
                if (dgpu) {
                    result.power_transitioned = power_.power_auto_dgpu(dgpu->pci_addr);
                }
            }
        }
    }
    return result;
}
```

**Reference counting system:**
- `active_dgpu_windows_` — an `unordered_set<string>` tracking window addresses that need the dGPU
- `active_dgpu_clients_` — integer counter for non-window-based clients
- `has_active_dgpu_clients()` returns true if **either** the set is non-empty OR the counter > 0
- dGPU is powered on when the **first** client arrives
- dGPU returns to `auto` power (allowing runtime PM to power it off) when the **last** client is removed

**Window close handling:**
```cpp
void GpuEnforcer::remove_dgpu_window(const std::string& window_addr) {
    if (active_dgpu_windows_.erase(window_addr) > 0) {
        if (!has_active_dgpu_clients()) {
            auto dgpu = detector_.find_dgpu();
            if (dgpu) {
                power_.power_auto_dgpu(dgpu->pci_addr);
            }
        }
    }
}
```

**PCI power control** (`power_manager.cpp:49-72`):
```cpp
bool PowerManager::set_pci_power(const std::string& pci_addr, PowerState state) {
    auto path = base / pci_addr / "power" / "control";   // /sys/bus/pci/devices/{addr}/power/control
    std::ofstream f(path);
    f << power_state_to_str(state);    // writes "on", "off", or "auto"
}
```

| PCI Power State | Effect |
|-----------------|--------|
| `on` | dGPU is fully powered and available for rendering |
| `off` | dGPU is completely powered down (maximum power saving) |
| `auto` | dGPU can be powered down by the kernel's runtime PM when idle |

### 2.6 Manual Override and Idle Timeout

**Manual override** (`main.cpp:188-207`):

The daemon listens on a Unix socket at `/tmp/titan-gpu-daemon.sock` and accepts commands:

```
set dgpu     → force dGPU for all apps (bypasses classification)
set igpu     → force iGPU for all apps
set auto     → return to automatic classification
power on     → directly power on dGPU
power off    → directly power off dGPU
power auto   → set dGPU to automatic power management
reload       → reload config file
status       → show current state
```

When `manual_override_active_` is true, the classification chain is bypassed:
```cpp
if (manual_override_active_) {
    result = enforcer_->enforce_target_window(manual_override_, ev.addr);
} else {
    result = enforcer_->enforce_for_app_window(ev.wm_class, ev.addr);
}
```

**Idle timeout** (`main.cpp:86-95`):

```cpp
if (enforcer_->has_active_dgpu_clients()) {
    last_activity = std::chrono::steady_clock::now();
} else {
    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::steady_clock::now() - last_activity).count();
    if (static_cast<uint32_t>(elapsed) >= cfg.power().dgpu_idle_timeout_sec) {
        enforcer_->idle_power_off(cfg.power().dgpu_idle_timeout_sec);
        last_activity = std::chrono::steady_clock::now();
    }
}
```

If no dGPU clients exist for `dgpu_idle_timeout_sec` seconds (default: 30), the dGPU PCI power is set to `auto`, allowing the kernel to power it down.

---

## Hardware Detection

**File:** `subsystems/auto-gpu-switcher/src/gpu_detector.cpp`

The GPU detector scans `/sys/class/drm/card*` directories to identify available GPUs:

```cpp
bool GpuDetector::scan() {
    // Iterate over /sys/class/drm/card0, card1, etc.
    DIR* dir = opendir(drm_path.c_str());
    while ((ent = readdir(dir)) != nullptr) {
        // Read device/vendor file (PCI vendor ID)
        auto vendor_str = read_file_str(card_dir / "device" / "vendor");
        GpuInfo info;
        info.vendor = parse_vendor(vendor_str);

        // Read device/uevent for PCI_SLOT_NAME
        auto uevent = read_file_str(card_dir / "device" / "uevent");
        // Parse PCI_SLOT_NAME=0000:01:00.0

        // Find render node under device/drm/render*
        info.render_node = "/dev/dri/renderD128" + index;

        // Check for NVIDIA driver
        if (info.vendor == GpuVendor::NVIDIA) {
            info.has_nvidia_driver = (stat("/proc/driver/nvidia/version", &st) == 0);
        }
    }
}
```

**Vendor identification by PCI ID:**

| PCI Vendor ID | Vendor | Role |
|---------------|--------|------|
| `0x8086` | Intel | iGPU (integrated) |
| `0x10de` | NVIDIA | dGPU (discrete) |
| `0x1002` | AMD | Either (depends on system) |

**Lookup functions:**
```cpp
const GpuInfo* GpuDetector::find_igpu() const {
    for (const auto& g : gpus_) {
        if (g.vendor == GpuVendor::Intel) return &g;    // first Intel GPU
    }
    return nullptr;
}

const GpuInfo* GpuDetector::find_dgpu() const {
    for (const auto& g : gpus_) {
        if (g.vendor == GpuVendor::NVIDIA) return &g;   // first NVIDIA GPU
    }
    return nullptr;
}
```

---

## Decision Tree

```
Application Launched
│
├── PATH 1: Launch-Time (Interceptor)
│   │
│   ├── Is --force-dgpu flag set?
│   │   └── YES → Apply dGPU environment
│   │
│   └── Is the binary listed in state/heavy_apps.list?
│       │
│       ├── Match by exact path?
│       ├── Match basename against app_name?
│       └── Match basename against recorded binary path?
│       │
│       ├── YES (any match) → Apply NVIDIA PRIME env vars
│       │   ├── __NV_PRIME_RENDER_OFFLOAD=1
│       │   ├── __GLX_VENDOR_LIBRARY_NAME=nvidia
│       │   ├── __VK_LAYER_NV_optimus=NVIDIA_only
│       │   └── QT_QPA_PLATFORM=xcb (if was wayland;xcb)
│       │   → execvp() the target application
│       │
│       └── NO → Run on default GPU (iGPU)
│
└── PATH 2: Runtime Focus-Change (Daemon + Hyprland IPC)
    │
    ├── Hyprland sends activewindowv2>> event
    │   └── Extract wm_class from event payload
    │
    ├── Config::classify_app(wm_class)
    │   ├── Exact match in [apps] section? → return "dgpu"/"igpu"/"auto"
    │   ├── Glob match in [patterns] section? → return "dgpu"/"igpu"/"auto"
    │   └── No match → return "auto"
    │
    ├── Classifier::classify_with_power(rule, is_battery)
    │   ├── Explicit "dgpu" → return DGPU (always)
    │   ├── Explicit "igpu" → return IGPU (always)
    │   └── "auto" → if battery: IGPU; if AC: DGPU
    │
    └── GpuEnforcer enforces physically
        ├── DGPU target:
        │   ├── If first dGPU client → PCI power ON
        │   └── Track window address in active_dgpu_windows_
        ├── IGPU target:
        │   ├── Remove window from tracking
        │   └── If no clients remain → PCI power AUTO
        └── Window close → remove from tracking → power off if idle
```

---

## Key Files Reference

| File | Role |
|------|------|
| `analyzer/config/heavy_libs.conf` | Rule database for library-based classification |
| `analyzer/scripts/common.sh` | Shared shell functions: ELF detection, path filtering, record formatting |
| `analyzer/scripts/analyze_binary.sh` | Core classifier: runs ldd, checks for heavy library linkage |
| `analyzer/scripts/analyze_package.sh` | Package-level analyzer: finds executables in pacman packages |
| `analyzer/scripts/initial_scan.sh` | Full system scan, rebuilds heavy_apps.list from scratch |
| `analyzer/scripts/update_heavy_list.sh` | Deduplicates and merges records into heavy_apps.list |
| `state/heavy_apps.list` | Persisted classification database (191 entries) |
| `pacman-hook/hooks/autogpuswitcher.hook` | libalpm hook: triggers on Install/Upgrade |
| `pacman-hook/post_transaction.sh` | Reads package names from stdin, runs analysis |
| `interceptor/src/main.cpp` | Launch-time interceptor: checks heavy list, applies env vars |
| `interceptor/src/heavy_app_db.cpp` | Lookup engine for heavy_apps.list |
| `interceptor/src/env_policy.cpp` | Sets NVIDIA PRIME offload environment variables |
| `subsystems/.../configs/titan-gpu.config.default` | Rule database for window-class-based classification |
| `subsystems/.../src/config.cpp` | INI config parser + classify_app() with exact + glob matching |
| `subsystems/.../src/workload_classifier.cpp` | Converts rule strings to GpuTarget enum, applies power heuristic |
| `subsystems/.../src/gpu_enforcer.cpp` | Core enforcement: classify → power on/off dGPU → track windows |
| `subsystems/.../src/hyprland_ipc_bridge.cpp` | Event source: receives window focus/close events from Hyprland |
| `subsystems/.../src/gpu_detector.cpp` | Hardware detection via /sys/class/drm |
| `subsystems/.../src/power_manager.cpp` | PCI power control via /sys/bus/pci/devices/*/power/control |
| `subsystems/.../src/main.cpp` | Daemon: main loop, IPC, manual override, idle timeout |

---

## Environment Variables

| Variable | Default | Used By | Purpose |
|----------|---------|---------|---------|
| `AUTOGPUSWITCHER_HEAVY_LIST_FILE` | `state/heavy_apps.list` | Interceptor | Override heavy apps list path |
| `AUTOGPUSWITCHER_STATE_DIR` | `state/` | Analyzer scripts | State directory location |
| `AUTOGPUSWITCHER_CONFIG_FILE` | `/etc/autogpuswitcher/autogpuswitcher.conf` | Analyzer scripts | Configuration file |
| `AUTOGPUSWITCHER_HEAVY_LIBS_FILE` | `analyzer/config/heavy_libs.conf` | Analyzer scripts | Heavy library patterns file |
| `AUTOGPUSWITCHER_VERBOSE` | `0` | Analyzer scripts | Enable verbose logging |
| `TITAN_CONFIG_PATH` | `/etc/titan-gpu/config` | Daemon | Daemon config file path |
| `TITAN_DRM_PATH` | `/sys/class/drm` | GPU Detector | Override DRM sysfs path |
| `TITAN_DRI_PATH` | `/dev/dri` | GPU Detector | Override DRI render node path |
| `TITAN_PCI_PATH` | `/sys/bus/pci/devices` | Power Manager | Override PCI sysfs path |
| `TITAN_SOCKET_PATH` | `/tmp/titan-gpu-daemon.sock` | Daemon | Unix socket for CLI commands |
| `AC_PATH` | auto-detected | Power Manager | Override AC power supply sysfs path |
| `__NV_PRIME_RENDER_OFFLOAD` | — | Target App | NVIDIA PRIME: enable offload rendering |
| `__GLX_VENDOR_LIBRARY_NAME` | — | Target App | NVIDIA PRIME: force NVIDIA GLX |
| `__VK_LAYER_NV_optimus` | — | Target App | NVIDIA PRIME: force NVIDIA Vulkan |
