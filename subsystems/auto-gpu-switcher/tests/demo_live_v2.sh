#!/bin/bash
# Live GPU demo — real sysfs, real nvidia-smi, mock Hyprland IPC
# Shows daemon detecting GPUs, classifying apps, writing state
# PCI power writes need sudo — run: sudo -E ./demo_live_v2.sh
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSYSTEM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SUBSYSTEM_DIR/build"

CLEANUP_PIDS=""
cleanup() {
    echo ""
    for pid in $CLEANUP_PIDS; do kill -9 "$pid" 2>/dev/null; done
    rm -f /tmp/titan-live/daemon.sock
    rm -rf /tmp/titan-live/runtime
}
trap cleanup EXIT

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m'
B='\033[0;34m' C='\033[0;36m' W='\033[1;37m' D='\033[0m'

clear
echo -e "${W}"
cat << 'BANNER'
╔═══════════════════════════════════════════════════════════════╗
║     Titan GPU Auto-Switcher — LIVE GPU Switching Demo       ║
║                                                               ║
║  Real sysfs · Real nvidia-smi · Real PCI power control       ║
╚═══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${D}"

# ── Setup ────────────────────────────────────────────────────────────
rm -rf /tmp/titan-live && mkdir -p /tmp/titan-live/runtime/hypr/demo

echo -e "${C}[1/7] System Info${D}"
echo -e "  CPU:  $(lscpu | grep 'Model name' | sed 's/.*: *//')"
echo -e "  GPU1: $(lspci | grep 'VGA' | sed 's/.*: //')"
echo -e "  GPU2: $(lspci | grep '3D' | sed 's/.*: //')"
echo -e "  nvidia-smi GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null)"
echo ""

echo -e "${C}[2/7] Current PCI power state${D}"
echo -e "  control:     $(cat /sys/bus/pci/devices/0000:01:00.0/power/control)"
echo -e "  runtime:     $(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
echo -e "  VRAM used:   $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null) MiB"
echo ""

# ── Power toggle (needs sudo) ────────────────────────────────────────
echo -e "${C}[3/7] PCI Power State Transitions (sudo)${D}"
PCI="/sys/bus/pci/devices/0000:01:00.0/power/control"

if [ -w "$PCI" ] 2>/dev/null || sudo -n true 2>/dev/null; then
    echo -e "  ${Y}>>> Writing 'on' to $PCI${D}"
    echo on | sudo tee "$PCI" >/dev/null
    sleep 0.5
    echo -e "  After:  control=$(cat "$PCI")  runtime=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
    echo -e "  VRAM:   $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null) MiB"
    echo ""

    echo -e "  ${Y}>>> Writing 'auto' to $PCI${D}"
    echo auto | sudo tee "$PCI" >/dev/null
    sleep 0.5
    echo -e "  After:  control=$(cat "$PCI")  runtime=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
    echo -e "  VRAM:   $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null) MiB"
    echo ""

    echo -e "  ${Y}>>> Writing 'off' to $PCI${D}"
    echo off | sudo tee "$PCI" >/dev/null
    sleep 0.5
    echo -e "  After:  control=$(cat "$PCI")  runtime=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
    echo -e "  VRAM:   $(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null) MiB"
    echo ""

    echo -e "  ${G}>>> Restoring to 'on'${D}"
    echo on | sudo tee "$PCI" >/dev/null
    sleep 0.5
    echo -e "  After:  control=$(cat "$PCI")  runtime=$(cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status)"
    echo ""
else
    echo -e "  ${Y}[SKIP]${D} Need sudo. Run with: sudo -E $0"
    echo ""
fi

# ── Start mock Hyprland IPC ──────────────────────────────────────────
echo -e "${C}[4/7] Starting mock Hyprland IPC server${D}"
HIS="demo"
MOCK_SOCK="/tmp/titan-live/runtime/hypr/$HIS/.socket2.sock"

# Feed events to the mock server via stdin pipe
(
    sleep 3  # wait for daemon to connect
    echo "activewindowv2>>0x1a,100,kitty,Terminal"
    sleep 0.8
    echo "activewindowv2>>0x2b,200,firefox,Browser"
    sleep 0.8
    echo "activewindowv2>>0x3c,300,steam,Steam"
    sleep 0.8
    echo "activewindowv2>>0x4d,400,blender,Blender Render"
    sleep 0.8
    echo "activewindowv2>>0x5e,500,kitty,Back to Terminal"
    sleep 2
) | python3 "$SCRIPT_DIR/mock_hyprland_persistent.py" "$MOCK_SOCK" &>/tmp/titan-live/injector.log &
INJECT_PID=$!
CLEANUP_PIDS="$CLEANUP_PIDS $INJECT_PID"
echo -e "  PID: $INJECT_PID"
sleep 1

# ── Start daemon ─────────────────────────────────────────────────────
echo -e "${C}[5/7] Starting daemon (real GPU detection)${D}"
XDG_RUNTIME_DIR=/tmp/titan-live/runtime \
HYPRLAND_INSTANCE_SIGNATURE=$HIS \
TITAN_SOCKET_PATH=/tmp/titan-live/daemon.sock \
TITAN_STATE_PATH=/tmp/titan-live/state.json \
"$BUILD_DIR/titan-gpu-switcherd" &>/tmp/titan-live/daemon.log &
DAEMON_PID=$!
CLEANUP_PIDS="$CLEANUP_PIDS $DAEMON_PID"
echo -e "  PID: $DAEMON_PID"
sleep 2

echo -e "${C}  Daemon detected GPUs:${D}"
grep "GPU(s)" /tmp/titan-live/daemon.log | sed 's/^/    /'
grep "NVIDIA\|Intel" /tmp/titan-live/daemon.log | sed 's/^/    /'
echo ""

# ── Inject window events ─────────────────────────────────────────────
echo -e "${C}[6/7] Window focus events (via Hyprland IPC)${D}"
echo -e "  Events are being injected..."
echo -e "  kitty -> firefox -> steam -> blender -> kitty"
echo ""

echo -e "  ${DIM}Watching for classification results...${D}"
sleep 5

echo ""
echo -e "${C}[7/7] Results${D}"
echo ""

# ── Daemon log ───────────────────────────────────────────────────────
echo -e "${W}━━━ Daemon Log (full) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
cat /tmp/titan-live/daemon.log | sed 's/^/  /'
echo ""

# ── State file ───────────────────────────────────────────────────────
echo -e "${W}━━━ State File (JSON) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
if [ -f /tmp/titan-live/state.json ]; then
    python3 -m json.tool /tmp/titan-live/state.json 2>/dev/null | sed 's/^/  /'
else
    echo -e "  ${Y}(not written yet)${D}"
fi
echo ""

# ── nvidia-smi snapshot ──────────────────────────────────────────────
echo -e "${W}━━━ nvidia-smi ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
nvidia-smi 2>/dev/null | sed 's/^/  /'
echo ""

# ── Injector log ─────────────────────────────────────────────────────
echo -e "${W}━━━ Hyprland IPC Log ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
cat /tmp/titan-live/injector.log | sed 's/^/  /'
echo ""

# ── CLI demo ─────────────────────────────────────────────────────────
echo -e "${W}━━━ CLI Commands ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
TITAN_SOCKET_PATH=/tmp/titan-live/daemon.sock TITAN_STATE_PATH=/tmp/titan-live/state.json \
    $BUILD_DIR/titan-gpu status 2>&1 | sed 's/^/  /'
echo ""

TITAN_SOCKET_PATH=/tmp/titan-live/daemon.sock TITAN_STATE_PATH=/tmp/titan-live/state.json \
    $BUILD_DIR/titan-gpu set dgpu 2>&1 | sed 's/^/  /'
sleep 0.3

TITAN_SOCKET_PATH=/tmp/titan-live/daemon.sock TITAN_STATE_PATH=/tmp/titan-live/state.json \
    $BUILD_DIR/titan-gpu set auto 2>&1 | sed 's/^/  /'
echo ""

echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""
echo -e "${G}Demo complete!${D}"
echo ""
echo -e "To run the full demo WITH PCI power switching:"
echo -e "  ${C}sudo -E $0${D}"
echo ""
echo -e "To run the live GPU monitor in a separate terminal:"
echo -e "  ${C}$SCRIPT_DIR/monitor_gpu.sh${D}"
echo ""
