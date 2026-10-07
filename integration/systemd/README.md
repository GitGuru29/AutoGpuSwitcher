# Systemd Integration

User services and timers for AutoGpuSwitcher.

## Files

| File | Purpose |
|------|---------|
| `autogpuswitcher.service` | Oneshot service that runs `gpu_auto_switcher.py` |
| `autogpuswitcher.timer` | Runs the above every 5 minutes |
| `titan-gpu-switcherd.service` | Long-running Titan daemon for window-based power management |

## Installation

```bash
# Install Titan daemon (recommended — enables rootless GPU switching)
sudo install -m 0644 titan-gpu-switcherd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now titan-gpu-switcherd

# Install workload auto-switcher timer
sudo install -m 0644 autogpuswitcher.service /etc/systemd/system/
sudo install -m 0644 autogpuswitcher.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now autogpuswitcher.timer

# Check status
systemctl status autogpuswitcher.timer
journalctl -u autogpuswitcher.service -f
```

## How they interact

```
titan-gpu-switcherd          (long-running daemon)
  └─ Listens to Hyprland IPC
  └─ Powers dGPU on/off per window focus
  └─ Exposes unix socket for commands

autogpuswitcher.timer        (every 5 minutes)
  └─ Runs gpu_auto_switcher.py
      └─ Scans /proc for GPU-heavy processes
      └─ Checks nvidia-smi for active GPU contexts
      └─ If Titan daemon is running → delegates via IPC
      └─ If not → falls back to prime-select/bbswitch (root)
```

Both mechanisms are coordinated: the Python switcher prefers the Titan
daemon and only falls back to direct switching when the daemon is absent.
