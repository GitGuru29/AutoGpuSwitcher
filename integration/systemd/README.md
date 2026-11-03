# Systemd Integration

System services for AutoGpuSwitcher.

## Files

| File | Purpose |
|------|---------|
| `titan-gpu-switcherd.service` | Long-running daemon: Hyprland window tracking, PCI runtime power management, workload auto-switching |

> The former `autogpuswitcher.service` + `autogpuswitcher.timer` pair (Python
> `gpu_auto_switcher.py` every 5 minutes) was removed. Workload analysis is
> now built into `titan-gpu-switcherd` (C++ `WorkloadAnalyzer`, 5-minute cycle
> inside the daemon loop). The Python script remains in the repo as an
> uninstalled fallback for root prime-select/bbswitch setups.

## Installation

```bash
# Via the installer (recommended)
sudo ./setup/install_phase1.sh

# Or manually
sudo install -m 0644 titan-gpu-switcherd.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now titan-gpu-switcherd

# Check status
systemctl status titan-gpu-switcherd
journalctl -u titan-gpu-switcherd -f

# Workload analyzer status
titan-gpu workload
titan-gpu workload-rescan
```

## What the daemon does

```
titan-gpu-switcherd                    (long-running daemon)
  ├─ Listens to Hyprland IPC (1s poll, reconnects on compositor restart)
  ├─ Powers dGPU on/off per window focus (reference-counted)
  ├─ AC/Battery power heuristics (auto → iGPU on battery, dGPU on AC)
  ├─ WorkloadAnalyzer cycle (every 5 min)
  │    ├─ /proc scan of current user's processes (age-filtered)
  │    ├─ nvidia-smi compute PID check
  │    └─ Score-based decision → auto-switch (skipped if manual override)
  ├─ Manual override (30 min) + idle power-off timers
  └─ Unix socket /run/titan-gpu/daemon.sock for `titan-gpu` CLI
```

## Environment variables

Set via `systemctl edit titan-gpu-switcherd`:

| Variable | Default | Purpose |
|----------|---------|---------|
| `TITAN_CONFIG_PATH` | `/etc/titan-gpu/config` | Daemon INI config |
| `TITAN_SOCKET_PATH` | `/run/titan-gpu/daemon.sock` | CLI socket path |
| `TITAN_HISTORY_PATH` | `/var/lib/autogpuswitcher/workload_history.dat` | Workload history file |
| `TITAN_DEBUG` | unset | Per-focus verbose logging (`1` enables) |
