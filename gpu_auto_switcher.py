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
TITAN_SOCKET = os.environ.get("TITAN_SOCKET_PATH", "/tmp/titan-gpu-daemon.sock")

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


def update_history(process, gpu):
    history = load_history()
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
    save_history(history)


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

    if any(w in cmdline for w in OFFLOAD_WRAPPER_KEYWORDS):
        return "nvidia"

    app_name = cmdline.split()[0] if cmdline else ""
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
            ret = os.system("prime-select intel 2>/dev/null")
            log("prime-select intel returned: {}".format(ret))
            success = (ret == 0)
        try:
            with open("/proc/acpi/bbswitch", "w") as f:
                f.write("OFF\n")
            log("NVIDIA card powered off via bbswitch")
            success = True
        except OSError as e:
            log("bbswitch off error: {}".format(e))
        os.system("xrandr --setprovideroffloadsources intel NVIDIA-0 "
                  "2>/dev/null")

    elif target == "nvidia":
        if shutil.which("prime-select"):
            ret = os.system("prime-select nvidia 2>/dev/null")
            log("prime-select nvidia returned: {}".format(ret))
            success = (ret == 0)
        try:
            with open("/proc/acpi/bbswitch", "w") as f:
                f.write("ON\n")
            log("NVIDIA card powered on via bbswitch")
            success = True
        except OSError as e:
            log("bbswitch on error: {}".format(e))
        os.system("xrandr --setprovideroutputsource modesetting NVIDIA-0 "
                  "2>/dev/null")

    time.sleep(1)
    return success


# ---------------------------------------------------------------------------
# Process scanning
# ---------------------------------------------------------------------------
def get_process_age_sec(pid):
    """Return process age in seconds, or None on error."""
    try:
        with open("/proc/{}/stat".format(pid), "r") as f:
            fields = f.read().split()
        if len(fields) < 22:
            return None
        starttime_jiffies = int(fields[21])
        hertz = os.sysconf("SC_CLK_TCK") or 100
        uptime_sec = time.time()
        # starttime is in jiffies since boot; convert to seconds
        start_sec = starttime_jiffies / hertz
        age = uptime_sec - start_sec
        return max(0.0, age)
    except (OSError, ValueError):
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

        # Age filter — skip short-lived processes
        age = get_process_age_sec(pid)
        if age is None or age < MIN_PROCESS_AGE_SEC:
            continue

        # Detect GPU
        process_gpu = detect_process_gpu(pid, nvidia_pids)

        # Build process key from cmdline (first 50 chars)
        try:
            with open("/proc/{}/cmdline".format(pid), "rb") as f:
                proc_name = (f.read()
                             .replace(b"\x00", b" ")
                             .decode("utf-8", errors="ignore")[:50]
                             .strip())
        except OSError:
            proc_name = "unknown"
        if not proc_name:
            continue

        update_history(proc_name, process_gpu)


# ---------------------------------------------------------------------------
# Decision & execution
# ---------------------------------------------------------------------------
def decide_and_switch():
    """Analyze workload, decide target GPU, and switch if needed."""
    history = load_history()
    decision = analyze_workload(history)
    log("Workload analysis: {}".format(decision))

    current = get_current_gpu()
    log("Current GPU state: {}".format(current))

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


def main():
    log("=== GPU Auto-Switcher starting ===")
    log("History: {}".format(GPU_HISTORY))
    log("Titan daemon: {}".format(
        "available" if titan_available() else "not detected"))

    # Enrich history with nvidia-smi GPU stats
    util, mem = get_nvidia_gpu_stats()
    log("nvidia-smi: utilization={}%, memory={}MB".format(util, mem))

    log("Tracking process GPU usage...")
    track_processes()
    log("Process tracking complete")

    log("Analyzing workload patterns...")
    decide_and_switch()

    log("=== GPU Auto-Switcher cycle complete ===")


if __name__ == "__main__":
    main()
