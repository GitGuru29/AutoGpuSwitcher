#!/usr/bin/env python3
import os
import sys
import json
import time
from datetime import datetime, timedelta

GPU_HISTORY = os.path.expanduser("~/.gpu-auto-switcher/history.json")
LOGFILE = os.path.expanduser("~/.gpu-auto-switcher/gpu-switcher.log")


def log(msg):
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = "{} | {}".format(ts, msg)
    with open(LOGFILE, "a") as f:
        f.write(line + "\n")
    print(line)


def load_history():
    try:
        with open(GPU_HISTORY, "r") as f:
            return json.load(f)
    except Exception:
        return {}


def save_history(data):
    try:
        with open(GPU_HISTORY, "w") as f:
            json.dump(data, f)
    except Exception:
        pass


def update_history(process, gpu):
    history = load_history()
    if process in history:
        history[process]['count'] = history[process].get('count', 0) + 1
    else:
        history[process] = {'count': 1, 'last_gpu': gpu, 'last_seen': datetime.now().isoformat()}
    save_history(history)


def detect_process_gpu(pid):
    try:
        with open("/proc/{}/environ".format(pid), "rb") as f:
            env = f.read().decode("utf-8", errors="ignore").lower()
            if "nvidia" in env:
                return "nvidia"
    except Exception:
        pass
    try:
        with open("/proc/{}/cmdline".format(pid), "rb") as f:
            cmdline = f.read().decode("utf-8", errors="ignore").lower()
            app_name = cmdline.split()[0] if cmdline else ""
            if any(kw in app_name for kw in ["steam", "blender", "3dsmax", "maya", "unreal", "godot", "cad", "render", "nvidia", "cuda", "gpgpu"]):
                return "nvidia"
            if "optirun" in cmdline or "primusrun" in cmdline:
                return "nvidia"
    except Exception:
        pass
    return "intel"


def analyze_workload(history):
    intel_score = 0
    nvidia_score = 0
    total_apps = 0
    now = datetime.now()
    recent_cutoff = now - timedelta(seconds=600)

    for proc, data in history.items():
        try:
            last_seen = datetime.fromisoformat(data.get('last_seen', '1970-01-01T00:00:00'))
            if last_seen < recent_cutoff:
                continue
        except Exception:
            continue
        count = data.get('count', 0)
        last_gpu = str(data.get('last_gpu', 'intel')).lower()
        total_apps += 1
        if last_gpu == 'nvidia':
            nvidia_score += count
        else:
            intel_score += count

    if total_apps > 3 and nvidia_score > intel_score * 1.5:
        return "nvidia"
    elif total_apps > 3 and intel_score > nvidia_score * 1.5:
        return "intel"
    return "balanced"


def get_current_gpu():
    try:
        with open("/proc/acpi/bbswitch/state", "r") as f:
            return f.read().strip()
    except Exception:
        return "unknown"


def switch_gpu(target):
    log("Switching to {} GPU mode...".format(target))
    try:
        if target == "intel":
            ret = os.system("prime-select intel 2>/dev/null")
            log("prime-select intel returned: {}".format(ret))
            try:
                with open("/proc/acpi/bbswitch", "w") as f:
                    f.write("OFF\n")
                log("NVIDIA card powered off via bbswitch")
            except Exception as e:
                log("bbswitch off error: {}".format(e))
            os.system("xrandr --setprovideroffloadsources intel NVIDIA-0 2>/dev/null")
            log("xrandr offload source set")
        elif target == "nvidia":
            ret = os.system("prime-select nvidia 2>/dev/null")
            log("prime-select nvidia returned: {}".format(ret))
            try:
                with open("/proc/acpi/bbswitch", "w") as f:
                    f.write("ON\n")
                log("NVIDIA card powered on via bbswitch")
            except Exception as e:
                log("bbswitch on error: {}".format(e))
            os.system("xrandr --setprovideroutputsource modesetting NVIDIA-0 2>/dev/null")
            log("xrandr source set")
    except Exception as e:
        log("switch_gpu error: {}".format(e))
    time.sleep(2)


def track_processes():
    my_uid = os.getuid()
    history = load_history()

    try:
        for pid_dir in os.listdir("/proc"):
            if not pid_dir.isdigit():
                continue
            pid = int(pid_dir)
            if pid == os.getpid():
                continue
            # Only track user's processes
            try:
                stat_info = os.stat("/proc/{}".format(pid_dir)).st_uid
                if stat_info != my_uid:
                    continue
            except PermissionError:
                continue

            try:
                with open("/proc/{}/status".format(pid), "r") as f:
                    comm = ""
                    for line in f:
                        if line.startswith("Name:"):
                            comm = line.split(":")[1].strip()
                            break
                if not comm:
                    continue
            except Exception:
                continue

            # System process exclusions
            comm_lower = comm.lower()
            if any(comm_lower.startswith(kw) for kw in ["kworker", "ksoftirqd", "migration", "watchdog", "events", "rcu", "power"]):
                continue

            # Detect GPU
            process_gpu = detect_process_gpu(pid)

            # Get process name
            try:
                with open("/proc/{}/cmdline".format(pid), "rb") as f:
                    proc_name = f.read().replace(b"\x00", b" ").decode("utf-8", errors="ignore")[:50]
            except Exception:
                proc_name = "unknown"

            # Skip very short-lived processes
            try:
                with open("/proc/{}/stat".format(pid), "r") as f:
                    stat_data = f.read()
                fields = stat_data.split()
                if len(fields) >= 22:
                    starttime = int(fields[21])
                    Hertz = os.sysconf("SC_CLK_TCK") or 100
                    now_time = time.time()
                    elapsed = int((now_time * Hertz) - (starttime / Hertz))
                    if elapsed < 10:
                        continue
            except Exception:
                pass

            update_history(proc_name, process_gpu)
    except Exception as e:
        log("track_processes error: {}".format(e))


def main():
    log("=== GPU Auto-Switcher starting ===")
    log("GPU history file: {}".format(GPU_HISTORY))

    # Track processes and update usage history
    log("Tracking process GPU usage...")
    track_processes()
    log("Process tracking complete")

    # Analyze workload patterns
    log("Analyzing workload patterns...")
    history = load_history()
    decision = analyze_workload(history)
    log("Workload analysis: {}".format(decision))

    # Get current GPU state
    current = get_current_gpu()
    log("Current GPU state: {}".format(current))

    # Make switching decision
    if decision == "nvidia":
        if current != "ON":
            switch_gpu("nvidia")
            log("Switched to Nvidia dGPU based on workload patterns")
        elif current == "ON":
            log("Nvidia already active, no switch needed")
        else:
            log("Cannot switch to Nvidia")
    elif decision == "intel":
        if current != "OFF":
            switch_gpu("intel")
            log("Switched to Intel iGPU based on workload patterns")
        elif current == "OFF":
            log("Intel already active, no switch needed")
        else:
            log("Cannot switch to Intel")
    elif decision == "balanced":
        log("Balanced workload pattern detected")
        if current == "ON":
            switch_gpu("intel")
            log("Switched to Intel iGPU for power saving (balanced pattern)")

    log("=== GPU Auto-Switcher cycle complete ===")


if __name__ == "__main__":
    main()