#!/usr/bin/env bash
# ==============================================================================
# End-to-end-ish test for the pacman post-transaction hook.
#
# Runs the real hook script against real installed packages, but redirects all
# state, logs, heavy list, and desktop output into a temp directory. It never
# installs/removes packages and never touches the real system state.
#
# Exit codes: 0 = passed, 1 = failed, 2 = skipped (not an Arch/pacman host).
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$ROOT_DIR/pacman-hook/post_transaction.sh"

PASS=0
FAIL=0
SKIP=0
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autogpuswitcher-hook.XXXXXX")"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $*"; }

echo "=== AutoGpuSwitcher pacman hook test ==="

if ! command -v pacman >/dev/null 2>&1; then
    echo "  SKIP  pacman not available on this host"
    exit 2
fi
if [[ ! -x "$HOOK" ]]; then
    fail "hook is missing or not executable: $HOOK"
    exit 1
fi

STATE_DIR="$TMP_DIR/state"
HOME_DIR="$TMP_DIR/home"
mkdir -p "$HOME_DIR"

run_hook() {
    # Isolate every path the hook and analyzer can write to.
    HOME="$HOME_DIR" \
    AUTOGPUSWITCHER_CONFIG_FILE="$TMP_DIR/no-such-config" \
    AUTOGPUSWITCHER_STATE_DIR="$STATE_DIR" \
    AUTOGPUSWITCHER_HEAVY_LIST_FILE="$STATE_DIR/heavy_apps.list" \
        "$HOOK" "$@"
}

# ── 1. Empty stdin must be a clean no-op ──────────────────────────────
run_hook </dev/null >"$TMP_DIR/empty.out" 2>&1
if [[ $? -eq 0 ]] && grep -q "No package targets" "$STATE_DIR/logs/pacman-hook.log" 2>/dev/null; then
    pass "empty stdin exits 0 and is logged"
else
    fail "empty stdin handling"
fi

# ── 2. Unknown package must be skipped without failing ────────────────
printf 'autogpuswitcher-test-package-that-does-not-exist\n' \
    | run_hook >"$TMP_DIR/unknown.out" 2>&1
if [[ $? -eq 0 ]]; then
    pass "unknown package is skipped without error"
else
    fail "unknown package caused hook failure"
fi

# ── 3. Real heavy package must be analyzed and recorded ───────────────
HEAVY_PKG=""
for candidate in mpv ffmpeg vlc blender steam obs-studio; do
    if pacman -Q "$candidate" >/dev/null 2>&1; then
        HEAVY_PKG="$candidate"
        break
    fi
done

if [[ -z "$HEAVY_PKG" ]]; then
    skip "no known heavy package installed (mpv/ffmpeg/vlc/blender/steam)"
elif ! command -v file >/dev/null 2>&1; then
    skip "recording check (file(1) not installed)"
else
    mapfile -t heavy_paths < <(pacman -Qlq "$HEAVY_PKG" 2>/dev/null)
    if ! printf '%s\n' "${heavy_paths[@]}" | grep -qE '^(/usr/bin/|/opt/)'; then
        skip "$HEAVY_PKG has no launchable binary to analyze"
    else
        printf '%s\n' "$HEAVY_PKG" | run_hook >"$TMP_DIR/heavy.out" 2>&1
        rc=$?
        LIST="$STATE_DIR/heavy_apps.list"

        if [[ $rc -ne 0 ]]; then
            fail "hook failed for $HEAVY_PKG (exit $rc)"
            sed 's/^/        /' "$TMP_DIR/heavy.out"
        elif [[ ! -s "$LIST" ]]; then
            fail "hook produced an empty heavy list for $HEAVY_PKG"
        elif ! grep -q "|${HEAVY_PKG}|" "$LIST"; then
            fail "hook did not record a $HEAVY_PKG binary (list: $(tr '\n' ' ' < "$LIST"))"
        else
            pass "hook analyzed $HEAVY_PKG and wrote a heavy record"
        fi

        if grep -q "analyzing .* package target" "$STATE_DIR/logs/pacman-hook.log" 2>/dev/null; then
            pass "hook log records the analyzed package"
        else
            fail "hook log missing analysis entry"
        fi

        DESKTOP_DIR="$HOME_DIR/.local/share/applications/autogpuswitcher"
        if [[ -d "$DESKTOP_DIR" ]] && compgen -G "$DESKTOP_DIR/*.desktop" >/dev/null; then
            pass "desktop integration regenerated inside the isolated HOME"
        elif [[ -d "$DESKTOP_DIR" ]]; then
            skip "desktop generator ran but produced no launchers"
        else
            fail "desktop generator did not use the isolated HOME"
        fi
    fi
fi

echo "=== pacman hook: $PASS passed, $FAIL failed, $SKIP skipped ==="
if (( FAIL > 0 )); then
    exit 1
fi
if (( PASS == 0 )); then
    exit 2
fi
exit 0
