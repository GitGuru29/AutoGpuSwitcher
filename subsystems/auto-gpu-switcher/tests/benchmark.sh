#!/bin/bash
# Comprehensive benchmark for titan-gpu-switcherd
# Uses mock sandbox to avoid host impact
set -eo pipefail

SANDBOX="/tmp/titan-bench-$$"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSYSTEM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SUBSYSTEM_DIR/build"
DAEMON_BIN="$BUILD_DIR/titan-gpu-switcherd"
CLI_BIN="$BUILD_DIR/titan-gpu"
RESULTS_FILE="$SANDBOX/results.txt"

MOCK_HYPR_PID=0
DAEMON_PID=0

cleanup() {
    [ "$DAEMON_PID" -ne 0 ] && kill "$DAEMON_PID" 2>/dev/null || true
    [ "$MOCK_HYPR_PID" -ne 0 ] && kill "$MOCK_HYPR_PID" 2>/dev/null || true
    [ "$DAEMON_PID" -ne 0 ] && wait "$DAEMON_PID" 2>/dev/null || true
    [ "$MOCK_HYPR_PID" -ne 0 ] && wait "$MOCK_HYPR_PID" 2>/dev/null || true
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

echo "============================================"
echo " titan-gpu-switcherd Performance Benchmarks"
echo "============================================"
echo ""

# ── Setup mock environment ───────────────────────────────────────────
mkdir -p "$SANDBOX/sys/class/drm/card0/device/drm"
mkdir -p "$SANDBOX/sys/class/drm/card1/device/drm"
mkdir -p "$SANDBOX/sys/bus/pci/devices/0000:01:00.0/power"
mkdir -p "$SANDBOX/sys/class/power_supply/AC"

echo "0x8086" > "$SANDBOX/sys/class/drm/card0/device/vendor"
cat > "$SANDBOX/sys/class/drm/card0/device/uevent" << 'EOF'
DRIVER=i915
PCI_SLOT_NAME=0000:00:02.0
EOF
echo "connected" > "$SANDBOX/sys/class/drm/card0/status"
mkdir -p "$SANDBOX/sys/class/drm/card0/device/drm/renderD128"

echo "0x10de" > "$SANDBOX/sys/class/drm/card1/device/vendor"
cat > "$SANDBOX/sys/class/drm/card1/device/uevent" << 'EOF'
DRIVER=nvidia
PCI_SLOT_NAME=0000:01:00.0
EOF
echo "connected" > "$SANDBOX/sys/class/drm/card1/status"
mkdir -p "$SANDBOX/sys/class/drm/card1/device/drm/renderD129"

echo "auto" > "$SANDBOX/sys/bus/pci/devices/0000:01:00.0/power/control"
echo "1" > "$SANDBOX/sys/class/power_supply/AC/online"

mkdir -p "$SANDBOX/dev/dri"
touch "$SANDBOX/dev/dri/renderD128"
touch "$SANDBOX/dev/dri/renderD129"

# Hyprland mock
HIS="bench-$$"
mkdir -p "$SANDBOX/runtime/hypr/$HIS"
python3 "$SCRIPT_DIR/mock_hyprland.py" "$SANDBOX/runtime/hypr/$HIS/.socket2.sock" "$SANDBOX/hypr.log" &
MOCK_HYPR_PID=$!
sleep 0.2

# Config
cat > "$SANDBOX/titan-gpu.config" << 'EOF'
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
code = igpu
gimp = igpu
obs = dgpu
lutris = dgpu
mpv = igpu

[patterns]
*game* = dgpu
*browser* = igpu
*editor* = igpu
*render* = dgpu
*video* = igpu
EOF

# Env
export TITAN_DRM_PATH="$SANDBOX/sys/class/drm"
export TITAN_DRI_PATH="$SANDBOX/dev/dri"
export TITAN_PCI_PATH="$SANDBOX/sys/bus/pci/devices"
export TITAN_STATE_PATH="$SANDBOX/titan_gpu_state"
export TITAN_SOCKET_PATH="$SANDBOX/titan-gpu-daemon.sock"
export TITAN_CONFIG_PATH="$SANDBOX/titan-gpu.config"
export AC_PATH="$SANDBOX/sys/class/power_supply/AC/online"
export XDG_RUNTIME_DIR="$SANDBOX/runtime"
export HYPRLAND_INSTANCE_SIGNATURE="$HIS"

# ── Helper functions ──────────────────────────────────────────────────
elapsed_ms() {
    local start_ns=$1 end_ns=$2
    echo $(( (end_ns - start_ns) / 1000000 ))
}

avg() {
    local sum=0 count=$1
    shift
    for v in "$@"; do sum=$((sum + v)); done
    echo $((sum / count))
}

min_val() {
    local m=999999
    for v in "$@"; do [ "$v" -lt "$m" ] && m=$v; done
    echo "$m"
}

max_val() {
    local m=0
    for v in "$@"; do [ "$v" -gt "$m" ] && m=$v; done
    echo "$m"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 1: Daemon Startup Latency"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

STARTUP_TIMES=()
for i in $(seq 1 10); do
    TITAN_SOCKET_PATH="$SANDBOX/bench-daemon-$i.sock" \
    TITAN_STATE_PATH="$SANDBOX/bench-state-$i.json" \
    start_ns=$(date +%s%N)
    "$DAEMON_BIN" > /dev/null 2>&1 &
    dp=$!
    # Wait for socket
    for j in $(seq 1 30); do
        [ -S "$SANDBOX/bench-daemon-$i.sock" ] && break
        sleep 0.01
    done
    end_ns=$(date +%s%N)
    ms=$(elapsed_ms $start_ns $end_ns)
    STARTUP_TIMES+=($ms)
    kill "$dp" 2>/dev/null; wait "$dp" 2>/dev/null
    rm -f "$SANDBOX/bench-daemon-$i.sock" "$SANDBOX/bench-state-$i.json"
done

avg_startup=$(avg ${#STARTUP_TIMES[@]} "${STARTUP_TIMES[@]}")
min_startup=$(min_val "${STARTUP_TIMES[@]}")
max_startup=$(max_val "${STARTUP_TIMES[@]}")
echo "  Runs: ${STARTUP_TIMES[*]}"
echo "  Avg:  ${avg_startup} ms"
echo "  Min:  ${min_startup} ms  |  Max:  ${max_startup} ms"
echo ""

# Start daemon for remaining benchmarks
"$DAEMON_BIN" > /dev/null 2>&1 &
DAEMON_PID=$!
for i in $(seq 1 30); do [ -S "$SANDBOX/titan-gpu-daemon.sock" ] && break; sleep 0.01; done
sleep 0.3

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 2: GPU Detection (real sysfs scan)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

DETECT_TIMES=()
for i in $(seq 1 10); do
    start_ns=$(date +%s%N)
    TITAN_DRM_PATH="$SANDBOX/sys/class/drm" \
    TITAN_DRI_PATH="$SANDBOX/dev/dri" \
    "$CLI_BIN" status > /dev/null 2>&1
    end_ns=$(date +%s%N)
    ms=$(elapsed_ms $start_ns $end_ns)
    DETECT_TIMES+=($ms)
done

avg_detect=$(avg ${#DETECT_TIMES[@]} "${DETECT_TIMES[@]}")
min_detect=$(min_val "${DETECT_TIMES[@]}")
max_detect=$(max_val "${DETECT_TIMES[@]}")
echo "  Runs: ${DETECT_TIMES[*]}"
echo "  Avg:  ${avg_detect} ms"
echo "  Min:  ${min_detect} ms  |  Max:  ${max_detect} ms"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 3: PCI Power Transition Latency"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

POWER_ON_TIMES=()
POWER_OFF_TIMES=()
for i in $(seq 1 10); do
    start_ns=$(date +%s%N)
    "$CLI_BIN" power on > /dev/null 2>&1
    end_ns=$(date +%s%N)
    POWER_ON_TIMES+=($(elapsed_ms $start_ns $end_ns))

    start_ns=$(date +%s%N)
    "$CLI_BIN" power off > /dev/null 2>&1
    end_ns=$(date +%s%N)
    POWER_OFF_TIMES+=($(elapsed_ms $start_ns $end_ns))
done

avg_pon=$(avg ${#POWER_ON_TIMES[@]} "${POWER_ON_TIMES[@]}")
avg_poff=$(avg ${#POWER_OFF_TIMES[@]} "${POWER_OFF_TIMES[@]}")
echo "  Power ON  -> avg: ${avg_pon} ms"
echo "  Power OFF -> avg: ${avg_poff} ms"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 4: IPC Round-Trip Latency"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

IPC_TIMES=()
for i in $(seq 1 50); do
    start_ns=$(date +%s%N)
    "$CLI_BIN" status > /dev/null 2>&1
    end_ns=$(date +%s%N)
    IPC_TIMES+=($(elapsed_ms $start_ns $end_ns))
done

avg_ipc=$(avg ${#IPC_TIMES[@]} "${IPC_TIMES[@]}")
min_ipc=$(min_val "${IPC_TIMES[@]}")
max_ipc=$(max_val "${IPC_TIMES[@]}")
echo "  50 round-trips"
echo "  Avg:  ${avg_ipc} ms"
echo "  Min:  ${min_ipc} ms  |  Max:  ${max_ipc} ms"

# Percentiles
sorted=$(printf '%s\n' "${IPC_TIMES[@]}" | sort -n)
p50_idx=25; p95_idx=47; p99_idx=49
p50=$(echo "$sorted" | sed -n "$((p50_idx+1))p")
p95=$(echo "$sorted" | sed -n "$((p95_idx+1))p")
p99=$(echo "$sorted" | sed -n "$((p99_idx+1))p")
echo "  P50:   ${p50} ms  |  P95:  ${p95} ms  |  P99:  ${p99} ms"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 5: Config Parsing"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Create large config
LARGE_CFG="$SANDBOX/large.config"
{
    echo "[power]"
    echo "dgpu_idle_timeout_sec = 10"
    echo "[apps]"
    for i in $(seq 1 100); do
        echo "app_${i} = dgpu"
    done
    echo "[patterns]"
    for i in $(seq 1 50); do
        echo "*pattern${i}* = igpu"
    done
} > "$LARGE_CFG"

CFG_TIMES=()
for i in $(seq 1 100); do
    start_ns=$(date +%s%N)
    TITAN_CONFIG_PATH="$LARGE_CFG" "$CLI_BIN" reload > /dev/null 2>&1
    end_ns=$(date +%s%N)
    CFG_TIMES+=($(elapsed_ms $start_ns $end_ns))
done

avg_cfg=$(avg ${#CFG_TIMES[@]} "${CFG_TIMES[@]}")
min_cfg=$(min_val "${CFG_TIMES[@]}")
max_cfg=$(max_val "${CFG_TIMES[@]}")
echo "  150 rules (100 apps + 50 patterns), 100 parse cycles"
echo "  Avg:  ${avg_cfg} ms"
echo "  Min:  ${min_cfg} ms  |  Max:  ${max_cfg} ms"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 6: State File Write Throughput"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

STATE_TIMES=()
for i in $(seq 1 50); do
    start_ns=$(date +%s%N)
    "$CLI_BIN" status > /dev/null 2>&1
    end_ns=$(date +%s%N)
    STATE_TIMES+=($(elapsed_ms $start_ns $end_ns))
done

avg_state=$(avg ${#STATE_TIMES[@]} "${STATE_TIMES[@]}")
echo "  50 state file writes"
echo "  Avg write cycle: ${avg_state} ms"
if [ -f "$SANDBOX/titan_gpu_state" ]; then
    state_size=$(wc -c < "$SANDBOX/titan_gpu_state")
    echo "  State file size: ${state_size} bytes"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 7: Rapid CLI Stress Test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

start_ns=$(date +%s%N)
for i in $(seq 1 200); do
    "$CLI_BIN" status > /dev/null 2>&1
done
end_ns=$(date +%s%N)
total_ms=$(elapsed_ms $start_ns $end_ns)
echo "  200 sequential status commands"
echo "  Total:    ${total_ms} ms"
echo "  Per-call: $((total_ms / 200)) ms avg"
echo "  Throughput: $((200 * 1000 / (total_ms + 1))) cmd/sec"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 8: Binary Size Analysis"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "  titan-gpu-switcherd: $(du -h "$DAEMON_BIN" | cut -f1)"
echo "  titan-gpu (CLI):     $(du -h "$CLI_BIN" | cut -f1)"
echo "  titan-gpu-tests:     $(du -h "$BUILD_DIR/titan-gpu-tests" | cut -f1)"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " BENCHMARK 9: Memory Usage (daemon resident)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -d "/proc/$DAEMON_PID" ]; then
    rss=$(awk '/VmRSS/ {print $2}' /proc/$DAEMON_PID/status 2>/dev/null || echo "N/A")
    vsz=$(awk '/VmSize/ {print $2}' /proc/$DAEMON_PID/status 2>/dev/null || echo "N/A")
    echo "  PID:          $DAEMON_PID"
    echo "  RSS (phys):   ${rss} kB"
    echo "  VSZ (virt):   ${vsz} kB"
else
    echo "  (daemon not running)"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Daemon startup:       ${avg_startup} ms avg"
echo "  GPU detection:        ${avg_detect} ms avg"
echo "  IPC round-trip:       ${avg_ipc} ms avg (P50=${p50} P95=${p95})"
echo "  PCI power on:         ${avg_pon} ms avg"
echo "  PCI power off:        ${avg_poff} ms avg"
echo "  Config parse (150):   ${avg_cfg} ms avg"
echo "  State write cycle:    ${avg_state} ms avg"
echo "  Stress throughput:    $((200 * 1000 / (total_ms + 1))) cmd/sec"
echo ""
echo "============================================"
echo " Benchmarks complete"
echo "============================================"
