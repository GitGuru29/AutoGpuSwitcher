#!/usr/bin/env python3
"""Auto GPU Switcher - Workload-based Intel/NVIDIA GPU switching.

Scans running processes, tracks per-process GPU usage history, and
auto-switches between the Intel iGPU and NVIDIA dGPU based on learned
workload patterns.  Delegates to the Titan daemon when available so all
three switching mechanisms stay coordinated.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import time
from datetime import datetime, timedelta

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
STATE_DIR = os.path.expanduser("~/.gpu-auto-switcher")
GPU_HISTORY = os.path.join(STATE_DIR, "history.json")
LOGFILE = os.path.join(STATE_DIR, "gpu-switcher.log")
POWER_HISTORY = os.path.join(STATE_DIR, "power_history.json")
# Check systemd RuntimeDirectory path first, then legacy /tmp fallback
TITAN_SOCKET = os.environ.get("TITAN_SOCKET_PATH")
if not TITAN_SOCKET:
    for _p in ("/run/titan-gpu/daemon.sock", "/tmp/titan-gpu-daemon.sock"):
        if os.path.exists(_p):
            TITAN_SOCKET = _p
            break
    else:
        TITAN_SOCKET = "/run/titan-gpu/daemon.sock"

# Recent-workload analysis window (seconds)
ANALYSIS_WINDOW_SEC = 600
# Minimum apps that must be seen recently before we decide a switch
MIN_APPS_FOR_DECISION = 4
# Score ratio threshold — one GPU must beat the other by this factor
PREFERENCE_RATIO = 1.5
# Minimum process age (seconds) before it counts toward history
MIN_PROCESS_AGE_SEC = 10
# Well-known apps that are known to be GPU-heavy
HEAVY_KEYWORDS = frozenset({
    "steam", "lutris", "blender", "3dsmax", "maya", "unreal",
    "godot", "obs", "kdenlive", "davinci", "cad", "render",
    "nvidia", "cuda", "gpgpu", "hashcat", "opencv",
})
# Wrapper tools that force NVIDIA rendering
OFFLOAD_WRAPPER_KEYWORDS = ("optirun", "primusrun", "prime-run")


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = "{} | {}".format(ts, msg)
    try:
        with open(LOGFILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line)


# ---------------------------------------------------------------------------
# History persistence
# ---------------------------------------------------------------------------
def load_history():
    try:
        with open(GPU_HISTORY, "r") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def save_history(data):
    try:
        os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)
        tmp = GPU_HISTORY + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, GPU_HISTORY)
    except OSError as e:
        log("save_history error: {}".format(e))


def update_history(history, process, gpu):
    """Mutate `history` dict in place. Caller is responsible for save_history()."""
    now_iso = datetime.now().isoformat()
    if process in history:
        entry = history[process]
        entry["count"] = entry.get("count", 0) + 1
        entry["last_gpu"] = gpu
        entry["last_seen"] = now_iso
        # Rolling window: append and trim to last 100 observations
        obs = entry.get("observations", [])
        obs.append({"gpu": gpu, "time": now_iso})
        entry["observations"] = obs[-100:]
    else:
        history[process] = {
            "count": 1,
            "last_gpu": gpu,
            "last_seen": now_iso,
            "observations": [{"gpu": gpu, "time": now_iso}],
        }


# ---------------------------------------------------------------------------
# GPU detection helpers
# ---------------------------------------------------------------------------
def get_nvidia_pids():
    """Return a set of PIDs that have an open NVIDIA compute/graphics context."""
    pids = set()
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-compute-apps=pid",
             "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL,
            timeout=5,
        ).decode()
        for line in out.splitlines():
            line = line.strip()
            if line.isdigit():
                pids.add(int(line))
    except (FileNotFoundError, subprocess.SubprocessError, OSError):
        pass
    return pids


def get_nvidia_gpu_stats():
    """Return (utilization_pct, memory_used_mb) or (0, 0) on failure."""
    try:
        out = subprocess.check_output(
            ["nvidia-smi",
             "--query-gpu=utilization.gpu,memory.used",
             "--format=csv,noheader,nounits"],
            stderr=subprocess.DEVNULL,
            timeout=5,
        ).decode().strip()
        parts = [p.strip() for p in out.split(",")]
        if len(parts) >= 2:
            return int(parts[0]), int(parts[1])
    except (FileNotFoundError, subprocess.SubprocessError, OSError,
            ValueError, IndexError):
        pass
    return 0, 0


def is_root():
    return os.geteuid() == 0


# ---------------------------------------------------------------------------
# Power consumption monitoring (battery drain rate from sysfs)
# ---------------------------------------------------------------------------
def read_power_supply():
    """Read battery power_now (uW) and capacity (%).

    Returns dict with keys: power_w (float watts), capacity (int %),
    or None if no battery exists.
    """
    import glob
    for bat in glob.glob("/sys/class/power_supply/BAT*"):
        info = {}
        # power_now in microwatts (some systems only expose energy_now/current_now)
        try:
            with open(os.path.join(bat, "power_now")) as f:
                info["power_uw"] = int(f.read().strip())
        except (OSError, ValueError):
            # Fallback: voltage_now * current_now
            try:
                with open(os.path.join(bat, "voltage_now")) as f:
                    volt = int(f.read().strip())
                with open(os.path.join(bat, "current_now")) as f:
                    curr = int(f.read().strip())
                info["power_uw"] = abs(volt * curr)
            except (OSError, ValueError):
                pass
        try:
            with open(os.path.join(bat, "capacity")) as f:
                info["capacity"] = int(f.read().strip())
        except (OSError, ValueError):
            pass
        if info:
            info["power_w"] = info.get("power_uw", 0) / 1_000_000.0
            info["bat"] = os.path.basename(bat)
            return info
    return None


def read_ac_online():
    """Return True if AC adapter is connected."""
    import glob
    for src in glob.glob("/sys/class/power_supply/AC*"):
        try:
            with open(os.path.join(src, "online")) as f:
                return f.read().strip() == "1"
        except OSError:
            continue
    # Fallback: check if any battery is charging
    for bat in glob.glob("/sys/class/power_supply/BAT*"):
        try:
            with open(os.path.join(bat, "status")) as f:
                return f.read().strip() == "Discharging"
        except OSError:
            continue
    return None


def log_power_sample(gpu_state):
    """Record a power sample for later trend analysis."""
    power = read_power_supply()
    if power is None:
        return None

    sample = {
        "time": datetime.now().isoformat(),
        "hour": datetime.now().hour,
        "gpu": gpu_state,
        "power_w": round(power["power_w"], 2),
        "capacity": power.get("capacity"),
        "ac": read_ac_online(),
    }

    # Append to rolling power history (last 500 samples)
    try:
        data = []
        if os.path.exists(POWER_HISTORY):
            with open(POWER_HISTORY) as f:
                data = json.load(f)
    except (OSError, json.JSONDecodeError):
        data = []
    data.append(sample)
    data = data[-500:]
    try:
        os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)
        tmp = POWER_HISTORY + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f, indent=None)
        os.replace(tmp, POWER_HISTORY)
    except OSError:
        pass

    log("Power: {:.1f}W capacity={} AC={} gpu={}".format(
        sample["power_w"], sample["capacity"],
        "yes" if sample["ac"] else "no", gpu_state))
    return sample


def compute_drain_rate(window_min=60):
    """Estimate battery drain rate (W) over the recent window."""
    try:
        with open(POWER_HISTORY) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if len(data) < 2:
        return None

    cutoff = datetime.now() - timedelta(minutes=window_min)
    recent = []
    for s in data:
        try:
            t = datetime.fromisoformat(s["time"])
        except (ValueError, KeyError):
            continue
        if t >= cutoff:
            recent.append(s)
    if len(recent) < 2:
        return None

    # If capacity dropped, compute mAh drain using capacity delta & time delta
    first, last = recent[0], recent[-1]
    try:
        cap0, cap1 = first["capacity"], last["capacity"]
        t0 = datetime.fromisoformat(first["time"])
        t1 = datetime.fromisoformat(last["time"])
    except (KeyError, ValueError):
        return None
    if cap0 is None or cap1 is None or t1 <= t0:
        # Fall back to instantaneous power average
        powers = [s["power_w"] for s in recent if s.get("power_w") is not None]
        if not powers:
            return None
        return sum(powers) / len(powers)

    hours = (t1 - t0).total_seconds() / 3600.0
    pct_drop = cap0 - cap1
    if pct_drop <= 0:
        return 0.0  # charging or full
    # Approximate: battery capacity unknown, use current instantaneous power
    powers = [s["power_w"] for s in recent if s.get("power_w") is not None]
    if powers:
        return sum(powers) / len(powers)
    return None


# ---------------------------------------------------------------------------
# Time-of-day workload prediction
# ---------------------------------------------------------------------------
def predict_from_time_of_day(history, window_days=14):
    """Use historical observations at the same hour to predict preferred GPU.

    Returns 'nvidia', 'intel', or None if insufficient data.
    """
    cutoff = datetime.now() - timedelta(days=window_days)
    current_hour = datetime.now().hour
    hour_nvidia = 0
    hour_intel = 0
    total = 0

    for _proc, data in history.items():
        for obs in data.get("observations", []):
            gpu = str(obs.get("gpu", "")).lower()
            try:
                t = datetime.fromisoformat(obs["time"])
            except (ValueError, KeyError):
                continue
            if t < cutoff:
                continue
            # Same hour or ±1 hour tolerance
            if abs(t.hour - current_hour) <= 1 or \
               (current_hour == 23 and t.hour == 0) or \
               (current_hour == 0 and t.hour == 23):
                total += 1
                if gpu == "nvidia":
                    hour_nvidia += 1
                else:
                    hour_intel += 1

    if total < 5:
        return None
    if hour_nvidia > hour_intel * 1.3:
        return "nvidia"
    if hour_intel > hour_nvidia * 1.3:
        return "intel"
    return None


def detect_process_gpu(pid, nvidia_pids):
    """Classify a single PID as 'nvidia' or 'intel'."""
    # Fast path: nvidia-smi tells us directly
    if pid in nvidia_pids:
        return "nvidia"

    # Check environment variables for NVIDIA PRIME offload markers
    try:
        with open("/proc/{}/environ".format(pid), "rb") as f:
            env = f.read().decode("utf-8", errors="ignore")
        if "__NV_PRIME_RENDER_OFFLOAD" in env or \
           "__VK_LAYER_NV_optimus" in env:
            return "nvidia"
    except OSError:
        pass

    # Check cmdline for known heavy apps or offload wrappers
    try:
        with open("/proc/{}/cmdline".format(pid), "rb") as f:
            cmdline = f.read().decode("utf-8", errors="ignore").lower()
    except OSError:
        return "intel"

    return _classify_cmdline(pid, nvidia_pids, cmdline)


def detect_process_gpu_with_cmdline(pid, nvidia_pids, cmdline_lower):
    """Classify a PID using an already-read cmdline (avoids double /proc read)."""
    if pid in nvidia_pids:
        return "nvidia"
    try:
        with open("/proc/{}/environ".format(pid), "rb") as f:
            env = f.read().decode("utf-8", errors="ignore")
        if "__NV_PRIME_RENDER_OFFLOAD" in env or \
           "__VK_LAYER_NV_optimus" in env:
            return "nvidia"
    except OSError:
        pass
    return _classify_cmdline(pid, nvidia_pids, cmdline_lower)


def _classify_cmdline(pid, nvidia_pids, cmdline_lower):
    if any(w in cmdline_lower for w in OFFLOAD_WRAPPER_KEYWORDS):
        return "nvidia"
    app_name = cmdline_lower.split()[0] if cmdline_lower else ""
    base = os.path.basename(app_name)
    if any(kw in base for kw in HEAVY_KEYWORDS):
        return "nvidia"
    return "intel"


# ---------------------------------------------------------------------------
# Workload analysis
# ---------------------------------------------------------------------------
def analyze_workload(history):
    """Return 'nvidia', 'intel', or 'balanced' based on recent usage."""
    intel_score = 0
    nvidia_score = 0
    total_apps = 0
    cutoff = datetime.now() - timedelta(seconds=ANALYSIS_WINDOW_SEC)

    for _proc, data in history.items():
        try:
            last_seen = datetime.fromisoformat(
                data.get("last_seen", "1970-01-01T00:00:00"))
        except ValueError:
            continue
        if last_seen < cutoff:
            continue

        count = data.get("count", 0)
        last_gpu = str(data.get("last_gpu", "intel")).lower()
        total_apps += 1
        if last_gpu == "nvidia":
            nvidia_score += count
        else:
            intel_score += count

    if total_apps < MIN_APPS_FOR_DECISION:
        return "balanced"
    if nvidia_score > intel_score * PREFERENCE_RATIO:
        return "nvidia"
    if intel_score > nvidia_score * PREFERENCE_RATIO:
        return "intel"
    return "balanced"


# ---------------------------------------------------------------------------
# Titan daemon delegation (keeps mechanisms coordinated)
# ---------------------------------------------------------------------------
def titan_available():
    """Check whether the Titan daemon socket is reachable."""
    if not os.path.exists(TITAN_SOCKET):
        return False
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect(TITAN_SOCKET)
        sock.close()
        return True
    except (OSError, ConnectionRefusedError):
        return False


def titan_command(cmd):
    """Send a command to the Titan daemon and return its response."""
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3)
        sock.connect(TITAN_SOCKET)
        sock.sendall((cmd + "\n").encode())
        resp = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            resp += chunk
        sock.close()
        return resp.decode(errors="ignore").strip()
    except (OSError, ConnectionRefusedError) as e:
        log("titan_command error: {}".format(e))
        return ""


# ---------------------------------------------------------------------------
# GPU state detection
# ---------------------------------------------------------------------------
def get_current_gpu():
    """Determine the current dGPU power state.

    Priority:
      1. bbswitch state file (ON/OFF)
      2. Titan daemon state
      3. PCI runtime power control
    """
    # 1. bbswitch
    try:
        with open("/proc/acpi/bbswitch/state", "r") as f:
            return f.read().strip()
    except OSError:
        pass

    # 2. Titan daemon
    if titan_available():
        resp = titan_command("status")
        for line in resp.splitlines():
            if "dGPU power:" in line:
                val = line.split(":", 1)[1].strip().lower()
                if val == "on":
                    return "ON"
                elif val == "off":
                    return "OFF"
                elif val == "auto":
                    return "AUTO"

    # 3. PCI runtime power control (best-effort)
    try:
        import glob
        for dev in glob.glob("/sys/bus/pci/devices/*/power/control"):
            # Only check the NVIDIA device
            uevent = os.path.join(os.path.dirname(dev), "uevent")
            try:
                with open(uevent) as f:
                    content = f.read()
                if "0x10de" not in content:
                    continue
            except OSError:
                continue
            with open(dev) as f:
                state = f.read().strip()
            return state.upper()
    except OSError:
        pass

    return "unknown"


# ---------------------------------------------------------------------------
# GPU switching
# ---------------------------------------------------------------------------
def switch_gpu(target):
    """Switch to 'intel' or 'nvidia'. Prefers Titan daemon, falls back."""
    log("Switching to {} GPU mode...".format(target))

    # --- Preferred: delegate to Titan daemon (single coordinated backend) ---
    if titan_available():
        titan_target = "igpu" if target == "intel" else "dgpu"
        resp = titan_command("set {}".format(titan_target))
        log("titan-gpu set {}: {}".format(titan_target, resp))
        if resp and "error" not in resp:
            return True
        log("titan-gpu delegation failed, falling back to direct methods")

    # --- Fallback: direct switching (requires root for most operations) ---
    if not is_root():
        log("WARNING: not running as root — prime-select/bbswitch will fail. "
            "Run with sudo or install the Titan daemon for rootless switching.")
        return False

    success = False

    if target == "intel":
        if shutil.which("prime-select"):
            ret = subprocess.run(["prime-select", "intel"],
                                 capture_output=True).returncode
            log("prime-select intel returned: {}".format(ret))
            success = (ret == 0)
        try:
            with open("/proc/acpi/bbswitch", "w") as f:
                f.write("OFF\n")
            log("NVIDIA card powered off via bbswitch")
            success = True
        except OSError as e:
            log("bbswitch off error: {}".format(e))
        # xrandr only works on X11; skip silently on Wayland/Hyprland
        if os.environ.get("XDG_SESSION_TYPE") == "x11" and shutil.which("xrandr"):
            subprocess.run(["xrandr", "--setprovideroffloadsources",
                            "intel", "NVIDIA-0"], capture_output=True)

    elif target == "nvidia":
        if shutil.which("prime-select"):
            ret = subprocess.run(["prime-select", "nvidia"],
                                 capture_output=True).returncode
            log("prime-select nvidia returned: {}".format(ret))
            success = (ret == 0)
        try:
            with open("/proc/acpi/bbswitch", "w") as f:
                f.write("ON\n")
            log("NVIDIA card powered on via bbswitch")
            success = True
        except OSError as e:
            log("bbswitch on error: {}".format(e))
        if os.environ.get("XDG_SESSION_TYPE") == "x11" and shutil.which("xrandr"):
            subprocess.run(["xrandr", "--setprovideroutputsource",
                            "modesetting", "NVIDIA-0"], capture_output=True)

    time.sleep(1)
    return success


# ---------------------------------------------------------------------------
# Process scanning
# ---------------------------------------------------------------------------
def get_process_age_sec(pid):
    """Return process age in seconds, or None on error."""
    try:
        with open("/proc/{}/stat".format(pid), "r") as f:
            raw = f.read()
        # Parse from the last ')' — comm field may contain spaces/parens
        rparen = raw.rfind(")")
        if rparen < 0:
            return None
        fields = raw[rparen + 1:].split()
        # After removing pid+comm, starttime is at index 19 (was 21 with pid+comm)
        if len(fields) < 20:
            return None
        starttime_jiffies = int(fields[19])
        hertz = os.sysconf("SC_CLK_TCK") or 100
        # Read actual system uptime (seconds since boot), not epoch time
        with open("/proc/uptime", "r") as f:
            uptime_sec = float(f.read().split()[0])
        # starttime is in jiffies since boot; convert to seconds
        start_sec = starttime_jiffies / hertz
        age = uptime_sec - start_sec
        return max(0.0, age)
    except (OSError, ValueError, IndexError):
        return None


def track_processes():
    """Scan user-owned processes and record their GPU usage in history."""
    my_uid = os.getuid()
    nvidia_pids = get_nvidia_pids()

    try:
        pid_dirs = os.listdir("/proc")
    except OSError as e:
        log("listdir /proc error: {}".format(e))
        return

    # Load history ONCE, mutate in memory, save once at the end
    # (was: load+save per PID = O(N) full JSON rewrites per cycle)
    history = load_history()

    for pid_dir in pid_dirs:
        if not pid_dir.isdigit():
            continue
        pid = int(pid_dir)
        if pid == os.getpid():
            continue

        # Only track current user's processes
        try:
            if os.stat("/proc/{}".format(pid_dir)).st_uid != my_uid:
                continue
        except OSError:
            continue

        # Skip known system threads
        try:
            with open("/proc/{}/comm".format(pid), "r") as f:
                comm = f.read().strip()
        except OSError:
            continue
        if any(comm.startswith(kw) for kw in
               ("kworker", "ksoftirqd", "migration", "watchdog",
                "rcu_", "irq/", "idle_inject")):
            continue

        # Age filter — skip short-lived processes (requires fixed epoch-vs-boot bug)
        age = get_process_age_sec(pid)
        if age is None or age < MIN_PROCESS_AGE_SEC:
            continue

        # Read cmdline ONCE — use for both GPU detection and process key
        # (was: read twice, once in detect_process_gpu and once here)
        try:
            with open("/proc/{}/cmdline".format(pid), "rb") as f:
                cmdline_raw = f.read()
            cmdline = cmdline_raw.replace(b"\x00", b" ").decode(
                "utf-8", errors="ignore")
        except OSError:
            cmdline = ""
        if not cmdline.strip():
            continue

        # Detect GPU (pass cmdline to avoid re-reading /proc)
        process_gpu = detect_process_gpu_with_cmdline(
            pid, nvidia_pids, cmdline.lower())

        # Build process key from cmdline (first 50 chars)
        proc_name = cmdline[:50].strip()

        update_history(history, proc_name, process_gpu)

    # Save once after the loop
    save_history(history)


# ---------------------------------------------------------------------------
# Decision & execution
# ---------------------------------------------------------------------------
def decide_and_switch():
    """Analyze workload, decide target GPU, and switch if needed."""
    history = load_history()
    decision = analyze_workload(history)
    log("Workload analysis (recent window): {}".format(decision))

    # Time-of-day prediction as secondary signal
    tod_pred = predict_from_time_of_day(history)
    if tod_pred:
        log("Time-of-day prediction (hour {}): {}".format(
            datetime.now().hour, tod_pred))

    # Combine: recent window is primary; TOD only decides ties
    if decision == "balanced" and tod_pred:
        decision = tod_pred
        log("Using time-of-day prediction to break tie: {}".format(decision))

    # Power-aware bias: on battery with high drain, prefer intel unless
    # recent workload strongly demands nvidia
    power = read_power_supply()
    if power and not read_ac_online():
        drain = compute_drain_rate()
        if drain and drain > 25.0 and decision == "balanced":
            decision = "intel"
            log("Battery drain {:.1f}W > 25W, biasing to intel".format(drain))

    current = get_current_gpu()
    log("Current GPU state: {}".format(current))

    # Record power sample for trend analysis
    log_power_sample(current)

    if decision == "nvidia":
        if current not in ("ON", "AUTO"):
            switch_gpu("nvidia")
            log("Switched to Nvidia dGPU based on workload patterns")
        else:
            log("Nvidia already active, no switch needed")
    elif decision == "intel":
        if current not in ("OFF",):
            switch_gpu("intel")
            log("Switched to Intel iGPU based on workload patterns")
        else:
            log("Intel already active, no switch needed")
    elif decision == "balanced":
        log("Balanced workload pattern detected")
        if current == "ON":
            switch_gpu("intel")
            log("Switched to Intel iGPU for power saving (balanced pattern)")


def run_subcommand(argv):
    """Handle CLI subcommands before the default switch cycle.

    Returns True if a subcommand was handled, False to run normal cycle.
    """
    if len(argv) < 2:
        return False

    cmd = argv[1]

    if cmd in ("power", "--power"):
        power = read_power_supply()
        ac = read_ac_online()
        drain = compute_drain_rate()
        if power is None:
            print("No battery found.")
            return True
        print("Battery: {}  Capacity: {}%  Power: {:.1f}W  AC: {}".format(
            power.get("bat", "?"), power.get("capacity", "?"),
            power["power_w"], "connected" if ac else "disconnected"))
        if drain is not None:
            print("Average drain (60min): {:.1f}W".format(drain))
        else:
            print("Drain rate: insufficient data")
        return True

    if cmd in ("rescan", "--rescan"):
        # Phase 3 item 8: rebuild heavy app state from scratch
        log("=== Rescan: rebuilding heavy app state ===")
        project_root = os.path.dirname(os.path.abspath(__file__))
        scan_script = os.path.join(project_root, "analyzer",
                                   "scripts", "initial_scan.sh")
        if not os.path.exists(scan_script):
            scan_script = "/usr/lib/autogpuswitcher/initial_scan.sh"
        if os.path.exists(scan_script):
            ret = subprocess.run(["bash", scan_script, "--yes"],
                                 capture_output=True).returncode
            log("initial_scan.sh exited: {}".format(ret))
        else:
            log("ERROR: initial_scan.sh not found. "
                "Reinstall with sudo ./setup/install_phase1.sh")
            return True

        # Also regenerate desktop entries after rescan
        run_subcommand(argv[:1] + ["desktop"])
        return True

    if cmd in ("desktop", "--desktop"):
        # Phase 3 item 7: rebuild .desktop integration
        log("=== Rebuilding desktop integration ===")
        project_root = os.path.dirname(os.path.abspath(__file__))
        gen_script = os.path.join(project_root, "integration", "desktop",
                                  "generate_desktop_entries.sh")
        if not os.path.exists(gen_script):
            gen_script = "/usr/lib/autogpuswitcher/generate_desktop_entries.sh"
        if os.path.exists(gen_script):
            ret = subprocess.run(["bash", gen_script],
                                 capture_output=True).returncode
            log("desktop generator exited: {}".format(ret))
        else:
            log("ERROR: generate_desktop_entries.sh not found.")
        return True

    if cmd in ("status", "--status"):
        history = load_history()
        decision = analyze_workload(history)
        tod = predict_from_time_of_day(history)
        current = get_current_gpu()
        power = read_power_supply()
        print("Tracked apps:        {}".format(len(history)))
        print("Workload decision:   {}".format(decision))
        print("Time-of-day pred:    {}".format(tod or "insufficient data"))
        print("Current GPU state:   {}".format(current))
        print("Titan daemon:        {}".format(
            "available" if titan_available() else "not detected"))
        if power:
            print("Power:               {:.1f}W capacity={} AC={}".format(
                power["power_w"], power.get("capacity"),
                "yes" if read_ac_online() else "no"))
        return True

    if cmd in ("help", "--help", "-h"):
        print("Usage: gpu_auto_switcher.py [COMMAND]")
        print()
        print("Commands:")
        print("  (none)    Run one switch cycle (default)")
        print("  power     Show battery/power report")
        print("  status    Show current workload and GPU status")
        print("  rescan    Rebuild heavy_apps.list from scratch + desktop entries")
        print("  desktop   Regenerate .desktop integration only")
        print("  help      Show this message")
        return True

    return False


def main():
    # Handle CLI subcommands
    if run_subcommand(sys.argv):
        return

    log("=== GPU Auto-Switcher starting ===")
    log("History: {}".format(GPU_HISTORY))
    log("Titan daemon: {}".format(
        "available" if titan_available() else "not detected"))

    # Enrich history with nvidia-smi GPU stats
    util, mem = get_nvidia_gpu_stats()
    log("nvidia-smi: utilization={}%, memory={}MB".format(util, mem))

    # Power status summary
    power = read_power_supply()
    if power:
        log("Power: {:.1f}W capacity={} AC={}".format(
            power["power_w"], power.get("capacity"),
            "yes" if read_ac_online() else "no"))

    log("Tracking process GPU usage...")
    track_processes()
    log("Process tracking complete")

    log("Analyzing workload patterns...")
    decide_and_switch()

    log("=== GPU Auto-Switcher cycle complete ===")


if __name__ == "__main__":
    main()
