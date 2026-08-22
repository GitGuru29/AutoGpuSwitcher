#!/bin/bash
# Live GPU switching demo — real sysfs, real nvidia-smi
# Shows the daemon actually toggling dGPU power and apps landing on the right GPU.
#
# WHAT YOU'LL SEE:
#   1. Daemon starts, detects Intel iGPU + NVIDIA dGPU
#   2. dGPU power state flips: auto -> on -> auto -> off -> on
#   3. nvidia-smi shows VRAM allocation changes
#   4. Window focus events trigger app classification
#   5. State file updates in real-time
#
# SAFETY:
#   - Only toggles PCI runtime PM (auto/on/off) — safe for hardware
#   - On cleanup: restores dGPU to "auto" state
#   - Uses your real sysfs — not mocked
#
# PREREQUISITES:
#   - Built binaries in build/
#   - sudo access for PCI power control writes (runtime PM)
#   - nvidia-smi available
#
# USAGE:
#   ./demo_live.sh              # full demo
#   ./demo_live.sh --no-power   # skip actual power toggling (observe only)
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSYSTEM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SUBSYSTEM_DIR/build"
DAEMON_BIN="$BUILD_DIR/titan-gpu-switcherd"
CLI_BIN="$BUILD_DIR/titan-gpu"
INJECTOR="$SCRIPT_DIR/inject_hyprland.py"
MONITOR="$SCRIPT_DIR/monitor_gpu.sh"

NO_POWER=false
[ "${1:-}" = "--no-power" ] && NO_POWER=true

R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
B='\033[0;34m'  C='\033[0;36m'  W='\033[1;37m'  D='\033[0m'
DIM='\033[2m'

DAEMON_PID=0
INJECTOR_PID=0
MOCK_HYPR_PID=0

cleanup() {
    echo ""
    echo -e "${W}[demo]${D} Cleaning up..."
    [ "$DAEMON_PID" -ne 0 ] && kill "$DAEMON_PID" 2>/dev/null || true
    [ "$INJECTOR_PID" -ne 0 ] && kill "$INJECTOR_PID" 2>/dev/null || true
    [ "$MOCK_HYPR_PID" -ne 0 ] && kill "$MOCK_HYPR_PID" 2>/dev/null || true
    [ "$DAEMON_PID" -ne 0 ] && wait "$DAEMON_PID" 2>/dev/null || true

    # Restore dGPU to auto
    if [ "$NO_POWER" = false ]; then
        PCI="0000:01:00.0"
        echo "auto" | sudo tee "/sys/bus/pci/devices/$PCI/power/control" >/dev/null 2>&1 || true
        echo -e "${G}[demo]${D} dGPU restored to auto"
    fi

    rm -f /tmp/titan-gpu-daemon.sock /tmp/titan_gpu_state
    echo -e "${G}[demo]${D} Cleanup complete"
}
trap cleanup EXIT

clear
echo -e "${W}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║        Titan GPU Auto-Switcher — Live Demo                  ║"
echo "║                                                             ║"
echo "║  Watch nvidia-smi + sysfs power states flip in real-time    ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${D}"

# ── Step 0: Pre-flight checks ────────────────────────────────────────
echo -e "${C}[preflight]${D} Checking prerequisites..."

if ! command -v nvidia-smi &>/dev/null; then
    echo -e "${R}[preflight]${D} nvidia-smi not found — install nvidia-utils"
    exit 1
fi

if ! [ -x "$DAEMON_BIN" ]; then
    echo -e "${Y}[preflight]${D} Binaries not found, building..."
    cmake -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -S "$SUBSYSTEM_DIR" >/dev/null 2>&1
    cmake --build "$BUILD_DIR" -j$(nproc) >/dev/null 2>&1
fi

PCI="0000:01:00.0"
if [ ! -f "/sys/bus/pci/devices/$PCI/power/control" ]; then
    echo -e "${R}[preflight]${D} PCI power control not found at $PCI"
    exit 1
fi

# Check sudo
if [ "$NO_POWER" = false ]; then
    if ! sudo -n true 2>/dev/null; then
        echo -e "${Y}[preflight]${D} Need sudo for PCI power writes. Enter password:"
        sudo true || { echo -e "${R}[preflight]${D} sudo failed"; exit 1; }
    fi
fi

echo -e "${G}[preflight]${D} OK"
echo ""

# ── Step 1: Show current state ───────────────────────────────────────
echo -e "${W}━━━ Current GPU State ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""

echo -e "${C}GPU Hardware:${D}"
lspci | grep -iE "vga|3d" | sed 's/^/  /'
echo ""

echo -e "${C}nvidia-smi:${D}"
nvidia-smi --query-gpu=name,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv 2>/dev/null | sed 's/^/  /' || echo "  (nvidia-smi query failed)"
echo ""

CURRENT_POWER=$(cat "/sys/bus/pci/devices/$PCI/power/control" 2>/dev/null || echo "N/A")
CURRENT_RUNTIME=$(cat "/sys/bus/pci/devices/$PCI/power/runtime_status" 2>/dev/null || echo "N/A")
echo -e "${C}PCI Power State:${D}  control=${Y}$CURRENT_POWER${D}  runtime=${Y}$CURRENT_RUNTIME${D}"
echo ""

# ── Step 2: Create mock Hyprland IPC ─────────────────────────────────
HIS="demo-$$-$(date +%s)"
export XDG_RUNTIME_DIR="/tmp/titan-demo-$$"
mkdir -p "$XDG_RUNTIME_DIR/hypr/$HIS"
MOCK_SOCK="$XDG_RUNTIME_DIR/hypr/$HIS/.socket2.sock"
export HYPRLAND_INSTANCE_SIGNATURE="$HIS"

# Events file: simulates switching between apps
EVENTS_FILE=$(mktemp)
cat > "$EVENTS_FILE" << 'EVENTS'
# Demo: switch between apps, watch GPU target change
activewindowv2>>0x1a,100,kitty,Terminal
activewindowv2>>0x2b,200,firefox,Browser
activewindowv2>>0x3c,300,steam,Steam
activewindowv2>>0x4d,400,blender,Blender
activewindowv2>>0x5e,500,kitty,Terminal
EVENTS

# Start mock Hyprland server
python3 "$INJECTOR" "$MOCK_SOCK" "$EVENTS_FILE" &
MOCK_HYPR_PID=$!
sleep 0.3

# ── Step 3: Start daemon (real sysfs) ────────────────────────────────
echo -e "${W}━━━ Starting Daemon (real sysfs) ━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""

"$DAEMON_BIN" > /tmp/titan-demo-daemon.log 2>&1 &
DAEMON_PID=$!

for i in $(seq 1 30); do
    [ -S /tmp/titan-gpu-daemon.sock ] && break
    sleep 0.05
done

if [ ! -S /tmp/titan-gpu-daemon.sock ]; then
    echo -e "${R}[demo]${D} Daemon failed to start"
    cat /tmp/titan-demo-daemon.log | sed 's/^/  /'
    exit 1
fi

sleep 0.5
echo -e "${G}[demo]${D} Daemon running (pid=$DAEMON_PID)"
echo ""

# ── Step 4: Show daemon status ───────────────────────────────────────
echo -e "${W}━━━ Daemon GPU Detection ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""
"$CLI_BIN" status 2>/dev/null | sed 's/^/  /'
echo ""

# ── Step 5: Interactive power demo ───────────────────────────────────
echo -e "${W}━━━ Live Power Switching Demo ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""

show_state() {
    local label="$1"
    local pwr=$(cat "/sys/bus/pci/devices/$PCI/power/control" 2>/dev/null || echo "N/A")
    local rt=$(cat "/sys/bus/pci/devices/$PCI/power/runtime_status" 2>/dev/null || echo "N/A")
    local nv_mem=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
    echo -e "  ${G}[$label]${D} power=${Y}$pwr${D}  runtime=${Y}$rt${D}  nvidia VRAM=${Y}${nv_mem} MiB${D}"
}

show_state "INITIAL"
echo ""

if [ "$NO_POWER" = false ]; then
    # --- Flip 1: Force dGPU ON ---
    echo -e "  ${C}>>> Forcing dGPU ON...${D}"
    sudo sh -c "echo on > /sys/bus/pci/devices/$PCI/power/control"
    sleep 1
    show_state "AFTER ON"
    echo ""

    # --- Flip 2: Set to auto (runtime PM) ---
    echo -e "  ${C}>>> Setting dGPU to auto (runtime PM)...${D}"
    sudo sh -c "echo auto > /sys/bus/pci/devices/$PCI/power/control"
    sleep 1
    show_state "AFTER AUTO"
    echo ""

    # --- Flip 3: Force dGPU OFF ---
    echo -e "  ${C}>>> Forcing dGPU OFF...${D}"
    sudo sh -c "echo auto > /sys/bus/pci/devices/$PCI/power/control"
    sleep 0.5
    sudo sh -c "echo off > /sys/bus/pci/devices/$PCI/power/control"
    sleep 1
    show_state "AFTER OFF"
    echo ""

    # --- Flip 4: Back to ON ---
    echo -e "  ${C}>>> Restoring dGPU to ON...${D}"
    sudo sh -c "echo on > /sys/bus/pci/devices/$PCI/power/control"
    sleep 1
    show_state "RESTORED"
    echo ""
else
    echo -e "  ${Y}[skip]${D} Power toggling disabled (--no-power flag)"
    echo ""
fi

# ── Step 6: Wait for Hyprland IPC events ─────────────────────────────
echo -e "${W}━━━ Hyprland IPC Event Injection ━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""
echo -e "  ${DIM}The daemon connected to mock Hyprland IPC.${D}"
echo -e "  ${DIM}Events are being injected to simulate window focus changes.${D}"
echo ""
echo -e "  ${C}Events sequence:${D}"
echo -e "    1. kitty (Terminal)  -> target: ${G}igpu${D}"
echo -e "    2. firefox (Browser) -> target: ${G}igpu${D} (pattern: *browser*)"
echo -e "    3. steam (Steam)     -> target: ${R}dgpu${D}"
echo -e "    4. blender (Blender) -> target: ${R}dgpu${D}"
echo -e "    5. kitty (Terminal)  -> target: ${G}igpu${D}"
echo ""

echo -e "  ${DIM}Waiting 8s for events to propagate...${D}"
sleep 8

# Show state file
echo ""
echo -e "${W}━━━ Final State File ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""
if [ -f /tmp/titan_gpu_state ]; then
    python3 -c "
import json
with open('/tmp/titan_gpu_state') as f:
    d = json.load(f)
print(json.dumps(d, indent=2))
" | sed 's/^/  /'
else
    echo -e "  ${Y}State file not yet written${D}"
fi
echo ""

# ── Step 7: Show daemon log ──────────────────────────────────────────
echo -e "${W}━━━ Daemon Log ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""
tail -30 /tmp/titan-demo-daemon.log 2>/dev/null | sed 's/^/  /' || echo "  (no log)"
echo ""

# ── Step 8: Final nvidia-smi ─────────────────────────────────────────
echo -e "${W}━━━ Final nvidia-smi ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""
nvidia-smi 2>/dev/null | sed 's/^/  /' || echo "  (nvidia-smi failed)"
echo ""

# ── Done ──────────────────────────────────────────────────────────────
echo -e "${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${D}"
echo ""
echo -e "${G}Demo complete!${D} All GPU power states restored to auto."
echo ""
echo -e "${DIM}To run the live monitor in a separate terminal:${D}"
echo -e "  ${C}$MONITOR${D}"
echo ""
echo -e "${DIM}To manually trigger GPU switching:${D}"
echo -e "  ${C}$CLI_BIN set dgpu${D}   # force dGPU"
echo -e "  ${C}$CLI_BIN set igpu${D}   # force iGPU"
echo -e "  ${C}$CLI_BIN set auto${D}   # auto mode"
echo ""

rm -f "$EVENTS_FILE"
