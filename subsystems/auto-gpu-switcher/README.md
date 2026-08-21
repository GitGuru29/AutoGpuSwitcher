# Titan GPU Auto-Switcher (Standalone Host)

Self-contained GPU switching daemon for Arch Linux with Intel+NVIDIA hybrid GPU on Hyprland. No THM dependency.

## Build

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

## Install

```bash
sudo cmake --install .
sudo mkdir -p /etc/titan-gpu/launchers
sudo cp ../configs/titan-gpu.config.default /etc/titan-gpu/config
sudo cp ../systemd/titan-gpu-switcherd.service /etc/systemd/system/
sudo cp ../udev/99-nvidia-power.rules /etc/udev/rules.d/
sudo systemctl daemon-reload
sudo systemctl enable --now titan-gpu-switcherd
sudo udevadm control --reload-rules
```

## Usage

```bash
titan-gpu status          # Show GPU status
titan-gpu set igpu        # Force iGPU
titan-gpu set dgpu        # Force dGPU
titan-gpu set auto        # Auto mode
titan-gpu power on/off    # Force dGPU power
titan-gpu reload          # Reload config
```

## Config

`/etc/titan-gpu/config` — INI format with `[power]`, `[detector]`, `[apps]`, `[patterns]` sections.

## Architecture

- `titan-gpu-switcherd`: Daemon — GPU detection, Hyprland IPC, power management, classifier
- `titan-gpu`: CLI — communicates with daemon via UNIX socket
- Waybar module: reads `/tmp/titan_gpu_state`
