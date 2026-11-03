#!/usr/bin/env bash
# ==============================================================================
# Real hardware verification for the AutoGpuSwitcher launcher.
#
# 1. Verifies the launcher injects the same PRIME environment as prime-run.
# 2. Verifies a heavy app launched through the launcher actually opens the
#    discrete GPU render node (not just that it prints a message).
#
# Exit codes: 0 = passed, 1 = failed, 2 = skipped (no GPU/display/app).
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LAUNCHER="$ROOT_DIR/interceptor/build/autogpuswitcher-launcher"

PASS=0
FAIL=0
SKIP=0
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autogpuswitcher-render.XXXXXX")"
MPV_PID=""

cleanup() {
    if [[ -n "$MPV_PID" ]]; then
        kill "$MPV_PID" 2>/dev/null || true
        wait "$MPV_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
skip() { SKIP=$((SKIP + 1)); echo "  SKIP  $*"; }

echo "=== AutoGpuSwitcher real render test ==="

if [[ ! -x "$LAUNCHER" ]]; then
    echo "  SKIP  launcher not built ($LAUNCHER)"
    exit 2
fi

# ── 1. Environment injection ──────────────────────────────────────────
ENV_BIN="/usr/bin/env"
HEAVY_LIST="$TMP_DIR/heavy.list"
EMPTY_LIST="$TMP_DIR/empty.list"
LOG_FILE="$TMP_DIR/launcher.log"

printf 'test|env|/usr/bin/env\n' > "$HEAVY_LIST"
: > "$EMPTY_LIST"

unset_prime_env() {
    env -u __NV_PRIME_RENDER_OFFLOAD \
        -u __GLX_VENDOR_LIBRARY_NAME \
        -u __VK_LAYER_NV_optimus \
        "$@"
}

HEAVY_OUT=$(unset_prime_env \
    AUTOGPUSWITCHER_HEAVY_LIST_FILE="$HEAVY_LIST" \
    AUTOGPUSWITCHER_LOG_FILE="$LOG_FILE" \
    "$LAUNCHER" "$ENV_BIN" 2>&1)

missing=""
for var in __NV_PRIME_RENDER_OFFLOAD __GLX_VENDOR_LIBRARY_NAME __VK_LAYER_NV_optimus; do
    grep -q "^${var}=" <<< "$HEAVY_OUT" || missing="$missing $var"
done
if [[ -z "$missing" ]]; then
    pass "heavy app receives all PRIME offload variables"
else
    fail "heavy app missing environment:$missing"
fi

LIGHT_OUT=$(unset_prime_env \
    AUTOGPUSWITCHER_HEAVY_LIST_FILE="$EMPTY_LIST" \
    AUTOGPUSWITCHER_LOG_FILE="$LOG_FILE" \
    "$LAUNCHER" "$ENV_BIN" 2>&1)
if grep -q '^__NV_PRIME_RENDER_OFFLOAD=' <<< "$LIGHT_OUT"; then
    fail "standard app incorrectly received PRIME offload variables"
else
    pass "standard app runs without PRIME offload variables"
fi

if grep -q 'decision=dGPU.*reason=heavy' "$LOG_FILE" 2>/dev/null && \
   grep -q 'decision=iGPU.*reason=standard' "$LOG_FILE" 2>/dev/null; then
    pass "launcher decision log records heavy and standard paths"
else
    fail "launcher decision log incomplete"
fi

# ── 2. Real dGPU render node ──────────────────────────────────────────
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    skip "dGPU render check (no graphical session)"
else
    MPV_BIN="$(command -v mpv || true)"
    FFMPEG_BIN="$(command -v ffmpeg || true)"

    DGPU_RENDER=""
    for dev in /sys/class/drm/card*/device; do
        [[ -r "$dev/vendor" ]] || continue
        [[ "$(cat "$dev/vendor" 2>/dev/null)" == "0x10de" ]] || continue
        node="$(ls -d "$dev"/drm/renderD* 2>/dev/null | head -n1 || true)"
        [[ -n "$node" ]] && DGPU_RENDER="/dev/dri/$(basename "$node")"
        break
    done

    if [[ -z "$MPV_BIN" || -z "$FFMPEG_BIN" ]]; then
        skip "dGPU render check (mpv and/or ffmpeg not installed)"
    elif [[ -z "$DGPU_RENDER" ]]; then
        skip "dGPU render check (no NVIDIA render node found)"
    else
        VIDEO="$TMP_DIR/test.mp4"
        if ! "$FFMPEG_BIN" -hide_banner -loglevel error \
                -f lavfi -i "testsrc=duration=2:size=320x240:rate=30" \
                -c:v mpeg4 -y "$VIDEO" >/dev/null 2>&1; then
            skip "dGPU render check (could not generate test video)"
        else
            AUTOGPUSWITCHER_LOG_FILE="$TMP_DIR/render.log" \
                "$LAUNCHER" --force-dgpu "$MPV_BIN" \
                --vo=gpu --no-audio --loop-file=inf --really-quiet \
                "$VIDEO" >/dev/null 2>&1 &
            MPV_PID=$!

            OPENED=""
            for _ in $(seq 1 50); do
                OPENED=$(ls -l "/proc/$MPV_PID/fd" 2>/dev/null \
                    | grep -o 'renderD[0-9]*' | sort -u | head -n1 || true)
                [[ -n "$OPENED" ]] && break
                kill -0 "$MPV_PID" 2>/dev/null || break
                sleep 0.1
            done

            if [[ -z "$OPENED" ]]; then
                fail "app never opened a DRM render node"
            elif [[ "/dev/dri/$OPENED" == "$DGPU_RENDER" ]]; then
                pass "app opened the dGPU render node ($DGPU_RENDER)"
            else
                fail "app opened /dev/dri/$OPENED, expected $DGPU_RENDER"
            fi

            if command -v nvidia-smi >/dev/null 2>&1 && kill -0 "$MPV_PID" 2>/dev/null; then
                if nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null \
                        | grep -qx "$MPV_PID"; then
                    pass "nvidia-smi lists the launched process"
                else
                    skip "nvidia-smi process accounting not available for this app"
                fi
            fi

            kill "$MPV_PID" 2>/dev/null || true
            wait "$MPV_PID" 2>/dev/null || true
            MPV_PID=""
        fi
    fi
fi

echo "=== real render: $PASS passed, $FAIL failed, $SKIP skipped ==="
if (( FAIL > 0 )); then
    exit 1
fi
if (( PASS == 0 )); then
    exit 2
fi
exit 0
