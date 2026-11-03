#!/usr/bin/env bash
# ==============================================================================
# Steam / Proton real-world validation for AutoGpuSwitcher
#
# Checks that Steam/Proton workloads are detected, listed, and routed to
# the NVIDIA dGPU through the launcher pipeline.
#
# Usage:
#   ./tests/validate_steam.sh           # full validation
#   ./tests/validate_steam.sh --quick   # skip environment deep checks
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INTERCEPTOR_BIN="$ROOT_DIR/interceptor/build/autogpuswitcher-launcher"
QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf "  [\033[0;32mPASS\033[0m] %s\n" "$1"; }
bad() { FAIL=$((FAIL+1)); printf "  [\033[0;31mFAIL\033[0m] %s\n" "$1"; }

echo "=============================================="
echo " Steam / Proton Validation"
echo "=============================================="
echo ""

# ---- 1. Steam installed? -----------------------------------------------------
echo "[1/6] Steam installation"
STEAM_BIN=""
for p in /usr/bin/steam ~/.local/share/Steam/steam.sh /usr/bin/steam-runtime; do
    [[ -x "$p" ]] && STEAM_BIN="$p" && break
done
if [[ -n "$STEAM_BIN" ]]; then
    ok "Steam binary found: $STEAM_BIN"
elif command -v steam >/dev/null 2>&1; then
    STEAM_BIN="$(command -v steam)"
    ok "Steam found in PATH: $STEAM_BIN"
else
    bad "Steam not installed (skipping Steam-specific checks)"
fi

# ---- 2. Steam in heavy_apps.list? -------------------------------------------
echo ""
echo "[2/6] Heavy app list contains Steam"
HEAVY_LIST="${AUTOGPUSWITCHER_HEAVY_LIST_FILE:-$ROOT_DIR/state/heavy_apps.list}"
if [[ ! -f "$HEAVY_LIST" ]]; then
    # Try system install path
    [[ -f /var/lib/autogpuswitcher/heavy_apps.list ]] && \
        HEAVY_LIST=/var/lib/autogpuswitcher/heavy_apps.list
fi

if [[ -f "$HEAVY_LIST" ]] && grep -qi "steam" "$HEAVY_LIST"; then
    ok "Steam present in heavy_apps.list"
    grep -i "steam" "$HEAVY_LIST" | head -3 | sed 's/^/         /'
elif [[ -f "$HEAVY_LIST" && -n "$STEAM_BIN" ]]; then
    # Try to analyze Steam now
    if bash "$ROOT_DIR/analyzer/scripts/analyze_binary.sh" --record "$STEAM_BIN" \
        >/dev/null 2>&1 && grep -qi "steam" "$HEAVY_LIST"; then
        ok "Steam analyzed and added to heavy_apps.list"
    else
        bad "Steam not in heavy_apps.list (run: sudo ./setup/first_run.sh)"
    fi
else
    bad "heavy_apps.list not found or Steam missing from it"
fi

# ---- 3. Launcher dry-run routes Steam to dGPU --------------------------------
echo ""
echo "[3/6] Launcher routes Steam to dGPU"
if [[ ! -x "$INTERCEPTOR_BIN" ]]; then
    bad "Interceptor not built (cmake -B interceptor/build -S interceptor && cmake --build interceptor/build)"
elif [[ -n "$STEAM_BIN" ]]; then
    OUT=$(AUTOGPUSWITCHER_HEAVY_LIST_FILE="$HEAVY_LIST" \
        "$INTERCEPTOR_BIN" --dry-run "$STEAM_BIN" 2>&1 || true)
    if echo "$OUT" | grep -qi "nvidia\|dGPU\|offload\|heavy"; then
        ok "Launcher decision: dGPU"
        echo "$OUT" | head -3 | sed 's/^/         /'
    else
        bad "Launcher did not route Steam to dGPU"
        echo "$OUT" | sed 's/^/         /'
    fi
else
    bad "No Steam binary to test"
fi

# ---- 4. PRIME render offload environment --------------------------------------
echo ""
echo "[4/6] NVIDIA PRIME render offload"
if [[ "$QUICK" -eq 1 ]]; then
    echo "  [SKIP] --quick mode"
elif ! command -v nvidia-smi >/dev/null 2>&1; then
    bad "nvidia-smi not available"
elif nvidia-smi -L >/dev/null 2>&1; then
    ok "nvidia-smi sees NVIDIA GPU"
    nvidia-smi -L | sed 's/^/         /'
else
    bad "nvidia-smi cannot enumerate GPUs"
fi

# ---- 5. glxinfo / vulkaninfo renderer check -----------------------------------
echo ""
echo "[5/6] Render offload actually works"
if [[ "$QUICK" -eq 1 ]]; then
    echo "  [SKIP] --quick mode"
elif ! command -v glxinfo >/dev/null 2>&1; then
    echo "  [SKIP] glxinfo not installed (pacman -S mesa-demos)"
elif [[ -n "$STEAM_BIN" ]] && [[ -x "$INTERCEPTOR_BIN" ]]; then
    # Run glxinfo through launcher forced to dGPU and check renderer
    RENDERER=$(AUTOGPUSWITCHER_HEAVY_LIST_FILE="$HEAVY_LIST" \
        "$INTERCEPTOR_BIN" --force-dgpu glxinfo 2>/dev/null \
        | grep "OpenGL renderer" | head -1)
    if echo "$RENDERER" | grep -qi "nvidia"; then
        ok "Force-dGPU glxinfo reports NVIDIA renderer"
        echo "         $RENDERER"
    elif [[ -n "$RENDERER" ]]; then
        bad "Force-dGPU glxinfo did NOT report NVIDIA renderer"
        echo "         $RENDERER"
    else
        bad "Could not query OpenGL renderer"
    fi
else
    echo "  [SKIP] needs interceptor + glxinfo"
fi

# ---- 6. Proton / Steam runtime directories -------------------------------------
echo ""
echo "[6/6] Proton / Steam runtime"
PROTON_FOUND=0
for d in \
    ~/.steam/steam/steamapps/common \
    ~/.local/share/Steam/steamapps/common \
    ~/.local/share/Steam/steamapps/compatdata \
    ~/.steam/root/steamapps/common; do
    if [[ -d "$d" ]]; then
        ok "Steam library found: $d"
        PROTON_FOUND=1
        # Check for installed Proton versions
        PROTONS=$(ls -d ~/.steam/steam/steamapps/common/Proton* \
                      ~/.local/share/Steam/steamapps/common/Proton* 2>/dev/null | wc -l)
        if [[ "$PROTONS" -gt 0 ]]; then
            ok "$PROTONS Proton version(s) installed"
        else
            echo "  [INFO] No Proton versions found (install from Steam > Steam Play)"
        fi
        break
    fi
done
if [[ "$PROTON_FOUND" -eq 0 ]]; then
    echo "  [INFO] No Steam library found (install a game first)"
fi

# ---- Summary -------------------------------------------------------------------
echo ""
echo "=============================================="
printf " Results: \033[0;32m%d passed\033[0m, \033[0;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
