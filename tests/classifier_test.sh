#!/usr/bin/env bash
# ==============================================================================
# Classifier precision tests.
#
# Regression coverage for the old "links libGL => heavy" behavior that marked
# Hyprland, Xwayland, Dolphin, KDE/Qt utilities, and other desktop components
# as dGPU workloads.
#
# Exit codes: 0 = passed, 1 = failed.
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autogpuswitcher-classifier.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

export AUTOGPUSWITCHER_CONFIG_FILE="$TMP_DIR/no-such-config"
export AUTOGPUSWITCHER_STATE_DIR="$TMP_DIR/state"
export AUTOGPUSWITCHER_HEAVY_LIST_FILE="$TMP_DIR/state/heavy.list"
export AUTOGPUSWITCHER_MANUAL_HEAVY_LIST_FILE="$TMP_DIR/state/manual.list"
export AUTOGPUSWITCHER_CLASSIFIER_FILE="$ROOT_DIR/analyzer/config/classifier.conf"
# shellcheck source=../analyzer/scripts/common.sh
source "$ROOT_DIR/analyzer/scripts/common.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS  $*"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }

make_desktop() {
    local name="$1" categories="$2"
    local path="$TMP_DIR/$name.desktop"
    cat > "$path" <<EOF
[Desktop Entry]
Type=Application
Name=$name
Categories=$categories
Exec=/usr/bin/$name
EOF
    printf '%s\n' "$path"
}

expect_heavy() {
    local description="$1" path="$2"
    if desktop_file_is_heavy "$path"; then
        pass "$description"
    else
        fail "$description"
    fi
}

expect_light() {
    local description="$1" path="$2"
    if desktop_file_is_heavy "$path"; then
        fail "$description"
    else
        pass "$description"
    fi
}

echo "=== AutoGpuSwitcher classifier precision test ==="

# ── Desktop category classification ───────────────────────────────────
GAME_DESKTOP="$(make_desktop game 'Game;')"
BENCH_DESKTOP="$(make_desktop benchmark 'Launcher;Benchmark;')"
MPV_DESKTOP="$(make_desktop mpv 'AudioVideo;Audio;Video;Player;TV;')"
VLC_DESKTOP="$(make_desktop vlc 'AudioVideo;Player;Recorder;')"
MUSIC_DESKTOP="$(make_desktop music 'AudioVideo;Audio;Player;')"
PV_DESKTOP="$(make_desktop pavucontrol-qt 'Qt;AudioVideo;Audio;Settings;DesktopSettings;')"
DOLPHIN_DESKTOP="$(make_desktop dolphin 'Qt;KDE;System;FileTools;FileManager;')"
KITTY_DESKTOP="$(make_desktop kitty 'System;TerminalEmulator;')"
BROWSER_DESKTOP="$(make_desktop firefox 'Network;WebBrowser;')"
GRAPHICS_DESKTOP="$(make_desktop inkscape 'Graphics;VectorGraphics;GTK;')"
VIEWER_DESKTOP="$(make_desktop gwenview 'Qt;KDE;Graphics;Viewer;')"
DEV_DESKTOP="$(make_desktop code 'Development;TextEditor;')"

expect_heavy "game category is heavy" "$GAME_DESKTOP"
expect_heavy "benchmark category is heavy" "$BENCH_DESKTOP"
expect_heavy "video player (mpv categories) is heavy" "$MPV_DESKTOP"
expect_heavy "recording/playing video (VLC) is heavy" "$VLC_DESKTOP"
expect_heavy "graphics editor is heavy" "$GRAPHICS_DESKTOP"
expect_light "music-only player is not heavy" "$MUSIC_DESKTOP"
expect_light "audio settings panel is not heavy" "$PV_DESKTOP"
expect_light "file manager is not heavy" "$DOLPHIN_DESKTOP"
expect_light "terminal is not heavy" "$KITTY_DESKTOP"
expect_light "browser is not heavy" "$BROWSER_DESKTOP"
expect_light "image viewer is not heavy" "$VIEWER_DESKTOP"
expect_light "editor/IDE is not heavy" "$DEV_DESKTOP"

# ── Package-level decisions ───────────────────────────────────────────
expect_pkg_heavy() {
    local description="$1" package="$2"
    if is_heavy_package "$package" /nonexistent; then
        pass "$description"
    else
        fail "$description"
    fi
}

expect_pkg_light() {
    local description="$1" package="$2"
    if is_heavy_package "$package" /nonexistent; then
        fail "$description"
    else
        pass "$description"
    fi
}

expect_pkg_heavy "GpuTest package is a benchmark" "gputest"
expect_pkg_heavy "Unigine package matches benchmark glob" "unigine-superposition"
expect_pkg_heavy "Steam is a game launcher" "steam"
expect_pkg_heavy "Dolphin emulator is a game launcher" "dolphin-emu"
expect_pkg_light "Hyprland compositor is excluded" "hyprland"
expect_pkg_light "Xwayland is excluded" "xwayland"
expect_pkg_light "Dolphin file manager is excluded" "dolphin"
expect_pkg_light "KDE/Qt audio settings is excluded" "pavucontrol-qt"
expect_pkg_light "unknown package with no game desktop entry is not heavy" "some-random-package"

# Package-name allowlists must not override explicit desktop evidence.
if is_heavy_package "example-game" "$GAME_DESKTOP"; then
    pass "package with a game desktop entry is heavy"
else
    fail "package with a game desktop entry is heavy"
fi
if is_heavy_package "example-util" "$DEV_DESKTOP"; then
    fail "package with only a development desktop entry is light"
else
    pass "package with only a development desktop entry is light"
fi

# ── Manual list survives a forced initial scan ────────────────────────
mkdir -p "$TMP_DIR/state" "$TMP_DIR/bin" "$TMP_DIR/scan-state"
printf 'manual|example-game|/opt/example-game/example-game\n' > "$MANUAL_HEAVY_LIST_FILE"

# Stub pacman so the scan sees one package that is filtered out by the
# category gate; the only surviving record must come from the manual list.
cat > "$TMP_DIR/bin/pacman" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    -Qq) printf 'fake-game\n' ;;
    -Q) exit 0 ;;
    -Qlq) printf '/usr/bin/fake-game\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP_DIR/bin/pacman"

env PATH="$TMP_DIR/bin:$PATH" \
    AUTOGPUSWITCHER_CONFIG_FILE="$TMP_DIR/no-such-config" \
    AUTOGPUSWITCHER_STATE_DIR="$TMP_DIR/scan-state" \
    AUTOGPUSWITCHER_HEAVY_LIST_FILE="$TMP_DIR/scan-state/heavy.list" \
    AUTOGPUSWITCHER_MANUAL_HEAVY_LIST_FILE="$MANUAL_HEAVY_LIST_FILE" \
    AUTOGPUSWITCHER_FIRST_RUN_MARKER="$TMP_DIR/scan-state/first_run_complete" \
    AUTOGPUSWITCHER_CLASSIFIER_FILE="$ROOT_DIR/analyzer/config/classifier.conf" \
    bash "$ROOT_DIR/analyzer/scripts/initial_scan.sh" --force >/dev/null 2>&1

if grep -q '^manual|example-game|/opt/example-game/example-game$' \
    "$TMP_DIR/scan-state/heavy.list"; then
    pass "manual_heavy_apps.list survives a forced initial scan"
else
    fail "manual_heavy_apps.list was lost during a forced initial scan"
fi

echo "=== classifier: $PASS passed, $FAIL failed ==="
if ((FAIL > 0)); then
    exit 1
fi
exit 0
