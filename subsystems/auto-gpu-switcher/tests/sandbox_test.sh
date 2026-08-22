#!/bin/bash
# Sandbox test harness for titan-gpu-switcherd
# Creates mock sysfs + mock Hyprland IPC, runs daemon, exercises all CLI commands.
# NO impact on host system — all paths are mock/isolated.
set -eo pipefail

SANDBOX="/tmp/titan-sandbox-$$"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSYSTEM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SUBSYSTEM_DIR/build"
DAEMON_BIN="$BUILD_DIR/titan-gpu-switcherd"
CLI_BIN="$BUILD_DIR/titan-gpu"
TESTS_BIN="$BUILD_DIR/titan-gpu-tests"
MOCK_HYPR="$SCRIPT_DIR/mock_hyprland.py"
DAEMON_PID=0
MOCK_HYPR_PID=0

cleanup() {
    echo ""
    echo "[sandbox] cleaning up $SANDBOX"
    [ "$DAEMON_PID" -ne 0 ] && kill "$DAEMON_PID" 2>/dev/null || true
    [ "$MOCK_HYPR_PID" -ne 0 ] && kill "$MOCK_HYPR_PID" 2>/dev/null || true
    [ "$DAEMON_PID" -ne 0 ] && wait "$DAEMON_PID" 2>/dev/null || true
    [ "$MOCK_HYPR_PID" -ne 0 ] && wait "$MOCK_HYPR_PID" 2>/dev/null || true
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

echo "============================================"
echo " titan-gpu-switcherd sandbox integration test"
echo "============================================"
echo ""

# ── Step 1: Build ─────────────────────────────────────────────────────
echo "[sandbox] building..."
cmake -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Debug -S "$SUBSYSTEM_DIR" >/dev/null 2>&1
cmake --build "$BUILD_DIR" -j$(nproc) >/dev/null 2>&1
echo "[sandbox] build OK"

# ── Step 2: Run unit tests ────────────────────────────────────────────
echo ""
echo "[sandbox] running unit tests..."
if "$TESTS_BIN" --gtest_color=no 2>&1 | tail -3; then
    echo "[sandbox] unit tests PASSED"
else
    echo "[sandbox] unit tests FAILED"
    exit 1
fi

# ── Step 3: Create mock sysfs tree ────────────────────────────────────
echo ""
echo "[sandbox] creating mock sysfs in $SANDBOX"

mkdir -p "$SANDBOX/sys/class/drm/card0/device/drm"
mkdir -p "$SANDBOX/sys/class/drm/card1/device/drm"
mkdir -p "$SANDBOX/sys/bus/pci/devices/0000:01:00.0/power"
mkdir -p "$SANDBOX/sys/class/power_supply/AC"

# Intel iGPU (card0)
echo "0x8086" > "$SANDBOX/sys/class/drm/card0/device/vendor"
cat > "$SANDBOX/sys/class/drm/card0/device/uevent" << 'UEOF'
DRIVER=i915
PCI_CLASS=30000
PCI_ID=8086:9A49
PCI_SUBSYS_ID=17AA:3F9B
PCI_SLOT_NAME=0000:00:02.0
MODALIAS=pci:v00008086d00009A49sv000017AAsd00003F9Bbc03sc00i00
UEOF
echo "connected" > "$SANDBOX/sys/class/drm/card0/status"
mkdir -p "$SANDBOX/sys/class/drm/card0/device/drm/renderD128"

# NVIDIA dGPU (card1)
echo "0x10de" > "$SANDBOX/sys/class/drm/card1/device/vendor"
cat > "$SANDBOX/sys/class/drm/card1/device/uevent" << 'UEOF'
DRIVER=nvidia
PCI_CLASS=30200
PCI_ID=10DE:1C94
PCI_SUBSYS_ID=17AA:3F9B
PCI_SLOT_NAME=0000:01:00.0
MODALIAS=pci:v000010DEd00001C94sv000017AAsd00003F9Bbc03sc02i00
UEOF
echo "connected" > "$SANDBOX/sys/class/drm/card1/status"
mkdir -p "$SANDBOX/sys/class/drm/card1/device/drm/renderD129"

# Power control
echo "auto" > "$SANDBOX/sys/bus/pci/devices/0000:01:00.0/power/control"
echo "1" > "$SANDBOX/sys/class/power_supply/AC/online"

# Mock render nodes (empty — daemon stat()s for existence)
mkdir -p "$SANDBOX/dev/dri"
touch "$SANDBOX/dev/dri/renderD128"
touch "$SANDBOX/dev/dri/renderD129"

echo "[sandbox] mock sysfs created:"
echo "  card0 (Intel):  0000:00:02.0 renderD128"
echo "  card1 (NVIDIA): 0000:01:00.0 renderD129"
echo "  PCI power: auto  |  AC: online"

# ── Step 4: Create mock Hyprland IPC socket ───────────────────────────
HIS="test-sandbox-$(date +%s)"
MOCK_HYPR_DIR="$SANDBOX/runtime/hypr/$HIS"
MOCK_HYPR_SOCK="$MOCK_HYPR_DIR/.socket2.sock"
MOCK_HYPR_LOG="$SANDBOX/hypr_events.log"
mkdir -p "$MOCK_HYPR_DIR"

python3 "$MOCK_HYPR" "$MOCK_HYPR_SOCK" "$MOCK_HYPR_LOG" \
    "activewindowv2>>0x1a,100,kitty,Terminal" \
    "activewindowv2>>0x2b,200,steam,My Game" \
    "activewindowv2>>0x3c,300,firefox,Browser" \
    "activewindowv2>>0x4d,400,blender,Blender 3D" &
MOCK_HYPR_PID=$!
sleep 0.3
echo "[sandbox] mock Hyprland IPC: $MOCK_HYPR_SOCK"

# ── Step 5: Create test config ────────────────────────────────────────
TEST_CONFIG="$SANDBOX/titan-gpu.config"
cat > "$TEST_CONFIG" << 'CFGEOF'
[power]
dgpu_idle_timeout_sec = 5
power_transition_timeout_ms = 200

[detector]
scan_interval_ms = 500

[apps]
steam = dgpu
blender = dgpu
kitty = igpu
firefox = igpu

[patterns]
*game* = dgpu
*browser* = igpu
CFGEOF
echo "[sandbox] test config: $TEST_CONFIG"

# ── Step 6: Export env vars and start daemon ──────────────────────────
export TITAN_DRM_PATH="$SANDBOX/sys/class/drm"
export TITAN_DRI_PATH="$SANDBOX/dev/dri"
export TITAN_PCI_PATH="$SANDBOX/sys/bus/pci/devices"
export TITAN_STATE_PATH="$SANDBOX/titan_gpu_state"
export TITAN_SOCKET_PATH="$SANDBOX/titan-gpu-daemon.sock"
export TITAN_CONFIG_PATH="$TEST_CONFIG"
export AC_PATH="$SANDBOX/sys/class/power_supply/AC/online"
export XDG_RUNTIME_DIR="$SANDBOX/runtime"
export HYPRLAND_INSTANCE_SIGNATURE="$HIS"

echo ""
echo "[sandbox] starting daemon..."
"$DAEMON_BIN" > "$SANDBOX/daemon.log" 2>&1 &
DAEMON_PID=$!

# Wait for socket to appear
for i in $(seq 1 30); do
    [ -S "$SANDBOX/titan-gpu-daemon.sock" ] && break
    sleep 0.1
done

if [ ! -S "$SANDBOX/titan-gpu-daemon.sock" ]; then
    echo "[sandbox] FAIL: daemon socket did not appear"
    echo "[sandbox] daemon log:"
    cat "$SANDBOX/daemon.log" | sed 's/^/  /'
    exit 1
fi
echo "[sandbox] daemon running (pid=$DAEMON_PID)"
sleep 0.5

# ── Step 7: Run CLI tests ─────────────────────────────────────────────
PASS=0
FAIL=0

run_test() {
    local desc="$1" expected="$2"
    shift 2
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -qF "$expected"; then
        echo "  PASS  $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $desc"
        echo "        expected: '$expected'"
        echo "        got:      '$output'"
        FAIL=$((FAIL + 1))
    fi
}

echo ""
echo "[sandbox] running CLI integration tests..."
echo ""

echo "--- GPU Detection ---"
run_test "Detects 2 GPUs" "NVIDIA" "$CLI_BIN" status
run_test "Shows Intel iGPU" "Intel" "$CLI_BIN" status
run_test "Power source AC" "AC" "$CLI_BIN" status

echo ""
echo "--- Manual Override ---"
run_test "Set iGPU" "set -> igpu" "$CLI_BIN" set igpu
sleep 0.2
run_test "Set dGPU" "set -> dgpu" "$CLI_BIN" set dgpu
sleep 0.2
run_test "Set auto" "set -> auto" "$CLI_BIN" set auto

echo ""
echo "--- Profile Switching ---"
run_test "Profile balanced" "profile -> balanced" "$CLI_BIN" profile balanced
run_test "Profile saver" "profile -> saver" "$CLI_BIN" profile saver
run_test "Profile performance" "profile -> performance" "$CLI_BIN" profile performance
run_test "Profile invalid rejected" "error: invalid profile" "$CLI_BIN" profile invalid

echo ""
echo "--- Power Control (mock sysfs writes) ---"
run_test "Power on" "dGPU power -> on" "$CLI_BIN" power on
VAL=$(cat "$SANDBOX/sys/bus/pci/devices/0000:01:00.0/power/control")
if [ "$VAL" = "on" ]; then
    echo "  PASS  PCI power file verified: 'on'"
    PASS=$((PASS + 1))
else
    echo "  FAIL  PCI power file: expected 'on', got '$VAL'"
    FAIL=$((FAIL + 1))
fi

run_test "Power off" "dGPU power -> off" "$CLI_BIN" power off
VAL=$(cat "$SANDBOX/sys/bus/pci/devices/0000:01:00.0/power/control")
if [ "$VAL" = "off" ]; then
    echo "  PASS  PCI power file verified: 'off'"
    PASS=$((PASS + 1))
else
    echo "  FAIL  PCI power file: expected 'off', got '$VAL'"
    FAIL=$((FAIL + 1))
fi

run_test "Power auto" "dGPU power -> auto" "$CLI_BIN" power auto
VAL=$(cat "$SANDBOX/sys/bus/pci/devices/0000:01:00.0/power/control")
if [ "$VAL" = "auto" ]; then
    echo "  PASS  PCI power file verified: 'auto'"
    PASS=$((PASS + 1))
else
    echo "  FAIL  PCI power file: expected 'auto', got '$VAL'"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Config Reload ---"
run_test "Reload config" "config reloaded" "$CLI_BIN" reload

echo ""
echo "--- State File ---"
sleep 0.5
if [ -f "$SANDBOX/titan_gpu_state" ]; then
    echo "  PASS  State file exists"
    PASS=$((PASS + 1))
    echo "  --- State file contents ---"
    cat "$SANDBOX/titan_gpu_state" | sed 's/^/        /'
    echo "  ---"
else
    echo "  FAIL  State file missing"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "--- Hyprland IPC Window Tracking & GPU Switching ---"
sleep 2
if [ -f "$MOCK_HYPR_LOG" ]; then
    EVENTS=$(cat "$MOCK_HYPR_LOG")
    if echo "$EVENTS" | grep -q "connected"; then
        echo "  PASS  Daemon connected to mock Hyprland IPC"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  Daemon did not connect to Hyprland IPC"
        FAIL=$((FAIL + 1))
    fi
    if echo "$EVENTS" | grep -q "sent:"; then
        echo "  PASS  Mock events delivered (kitty -> steam -> firefox -> blender)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  No events delivered"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  WARN  Hyprland event log not found"
fi

echo ""
echo "--- Phase 2 Interceptor Launcher ---"
PROJECT_ROOT="$(cd "$SUBSYSTEM_DIR/../.." && pwd)"
LAUNCHER_BIN="$PROJECT_ROOT/interceptor/build/autogpuswitcher-launcher"
HEAVY_LIST="$SANDBOX/heavy_apps.list"
cat > "$HEAVY_LIST" << 'HLSEOF'
arch-linux|blender|/usr/bin/blender
arch-linux|steam|/usr/bin/steam
HLSEOF
export AUTOGPUSWITCHER_HEAVY_LIST_FILE="$HEAVY_LIST"

if [ -x "$LAUNCHER_BIN" ]; then
    run_test "Launcher detects heavy app (blender)" "heavy app detected" "$LAUNCHER_BIN" --dry-run /usr/bin/blender
    run_test "Launcher detects standard app (kitty)" "standard app detected" "$LAUNCHER_BIN" --dry-run /usr/bin/kitty
    run_test "Launcher force-dgpu flag" "heavy app detected" "$LAUNCHER_BIN" --force-dgpu --dry-run /usr/bin/kitty
else
    echo "  WARN  Launcher binary not found at $LAUNCHER_BIN"
fi

echo ""
echo "--- Waybar Custom Module ---"
run_test "Waybar module execution" "App: blender" "$SUBSYSTEM_DIR/waybar/titan-gpu.sh"

echo ""
echo "--- Daemon Log (last 20 lines) ---"
tail -20 "$SANDBOX/daemon.log" | sed 's/^/  /'

# ── Step 8: Summary ──────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Results: $PASS passed, $FAIL failed"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

echo ""
echo "[sandbox] ALL TESTS PASSED — no host system changes made"
