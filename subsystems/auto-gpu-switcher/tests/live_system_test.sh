#!/usr/bin/env bash
# Live System Test Suite for AutoGpuSwitcher on real hardware
# Tests real GPU detection, binary analysis, launcher offload environment, and execution.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
LAUNCHER_BIN="$PROJECT_ROOT/interceptor/build/autogpuswitcher-launcher"
ANALYZE_BIN="$PROJECT_ROOT/analyzer/scripts/analyze_binary.sh"
HEAVY_LIST="$PROJECT_ROOT/state/heavy_apps.list"

echo "========================================================"
echo " AutoGpuSwitcher Live System Execution Test Report"
echo " Date: $(date -u)"
echo " Host: $(hostname)"
echo " Kernel: $(uname -r)"
echo "========================================================"
echo ""

# ── 1. Host Hardware Inventory ─────────────────────────────────────────
echo "--- 1. Real Hardware Inventory ---"
lscpu | grep "Model name" | sed 's/^/  /'
lspci | grep -iE 'vga|3d|display' | sed 's/^/  /'
if command -v nvidia-smi >/dev/null 2>&1; truncated_out=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader); then
    echo "  NVIDIA-SMI: $truncated_out"
fi
echo ""

# ── 2. Binary Analyzer Test on Real System Binaries ────────────────────
echo "--- 2. Binary Analyzer Scanning Installed Apps ---"
export AUTOGPUSWITCHER_HEAVY_LIST_FILE="$HEAVY_LIST"
mkdir -p "$PROJECT_ROOT/state"
touch "$HEAVY_LIST"

TARGET_BINS=(/usr/bin/mpv /usr/bin/vlc /usr/bin/ffmpeg /usr/bin/fastfetch)
for bin in "${TARGET_BINS[@]}"; do
    if [ -x "$bin" ]; then
        echo "Scanning $bin..."
        "$ANALYZE_BIN" --record "$bin" | sed 's/^/  /' || true
    fi
done
echo "Recorded Heavy Apps in state/heavy_apps.list:"
cat "$HEAVY_LIST" | sed 's/^/  /'
echo ""

# ── 3. Interceptor Launcher Environment Verification ──────────────────
echo "--- 3. Interceptor Launcher Offload Verification ---"
echo "[Test 1: Standard App (fastfetch)]"
"$LAUNCHER_BIN" --dry-run /usr/bin/fastfetch | sed 's/^/  /'

echo ""
echo "[Test 2: Heavy App (mpv)]"
"$LAUNCHER_BIN" --dry-run /usr/bin/mpv | sed 's/^/  /'

echo ""
echo "[Test 3: Forced dGPU Offload (--force-dgpu fastfetch)]"
"$LAUNCHER_BIN" --force-dgpu --dry-run /usr/bin/fastfetch | sed 's/^/  /'
echo ""

# ── 4. Live Binary Execution Test ─────────────────────────────────────
echo "--- 4. Live Binary Execution Test ---"
echo "[Exec 1: Standard launch fastfetch via launcher]"
"$LAUNCHER_BIN" /usr/bin/fastfetch 2>&1 | head -15 | sed 's/^/  /'

echo ""
echo "[Exec 2: Heavy app launch mpv --version via launcher]"
"$LAUNCHER_BIN" /usr/bin/mpv --version 2>&1 | head -10 | sed 's/^/  /'

echo ""
echo "========================================================"
echo " Live System Execution Test Completed Successfully"
echo "========================================================"
