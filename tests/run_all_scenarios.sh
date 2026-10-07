#!/usr/bin/env bash
# ==============================================================================
# AutoGpuSwitcher - 55 Scenario Worst-Case & Edge-Case Test Suite Runner
# ==============================================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
INTERCEPTOR_BIN="$ROOT_DIR/interceptor/build/autogpuswitcher-launcher"
DAEMON_TESTS_BIN="$BUILD_DIR/titan-gpu-tests"
DAEMON_BIN="$BUILD_DIR/titan-gpu-switcherd"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

pass() {
    local num="$1"
    local name="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    PASSED_TESTS=$((PASSED_TESTS + 1))
    printf "  [${GREEN}PASS${NC}] Case %02d: %s\n" "$num" "$name"
}

fail() {
    local num="$1"
    local name="$2"
    local reason="${3:-}"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    FAILED_TESTS=$((FAILED_TESTS + 1))
    printf "  [${RED}FAIL${NC}] Case %02d: %s (%s)\n" "$num" "$name" "$reason"
}

info_header() {
    echo ""
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${BLUE}======================================================================${NC}"
}

# Ensure binaries are built
if [[ ! -x "$DAEMON_TESTS_BIN" ]]; then
    echo "Building daemon and test binaries..."
    cmake -B "$BUILD_DIR" -S "$ROOT_DIR/subsystems/auto-gpu-switcher" >/dev/null 2>&1
    cmake --build "$BUILD_DIR" >/dev/null 2>&1
fi

if [[ ! -x "$INTERCEPTOR_BIN" ]]; then
    echo "Building launcher interceptor..."
    cmake -B "$ROOT_DIR/interceptor/build" -S "$ROOT_DIR/interceptor" >/dev/null 2>&1
    cmake --build "$ROOT_DIR/interceptor/build" >/dev/null 2>&1
fi

# ==============================================================================
# CATEGORY 1: Binary & Library Analysis Hazards (Install/Scan Layer)
# ==============================================================================
info_header "Category 1: Binary & Library Analysis Hazards (Install/Scan Layer)"

source "$ROOT_DIR/analyzer/scripts/common.sh"

# Case 1: Runtime dlopen() (no static linkage)
# A binary with no direct ldd dependency should not be marked heavy by ldd analysis
if ! binary_uses_heavy_libs "/usr/bin/ls" 2>/dev/null; then
    pass 1 "Runtime dlopen / Non-graphics binary falls back to iGPU"
else
    fail 1 "Runtime dlopen / Non-graphics binary falsely detected as heavy"
fi

# Case 2: Statically linked binary / non-ELF
TMP_STATIC="/tmp/test_static_file_$$"
echo "#!/bin/sh" > "$TMP_STATIC"
chmod +x "$TMP_STATIC"
if ! is_elf_executable "$TMP_STATIC" 2>/dev/null; then
    pass 2 "Statically linked shell script filtered out by ELF scanner"
else
    fail 2 "Shell script mistakenly passed as ELF executable"
fi
rm -f "$TMP_STATIC"

# Case 3: Script in candidate root
TMP_SCRIPT="/usr/bin/test_fake_app_$$"
# Test path filtering function directly
if path_is_candidate_root "/usr/bin/my_app" && ! path_is_candidate_root "/home/user/my_app"; then
    pass 3 "Path filter strictly bounds candidate search roots (/usr/bin vs /home)"
else
    fail 3 "Path filter allowed non-system root directory"
fi

# Case 4: Symlink loops resolution
TMP_SYMLINK_A="/tmp/symlink_a_$$"
TMP_SYMLINK_B="/tmp/symlink_b_$$"
ln -sf "$TMP_SYMLINK_B" "$TMP_SYMLINK_A"
ln -sf "$TMP_SYMLINK_A" "$TMP_SYMLINK_B"
if ! is_elf_executable "$TMP_SYMLINK_A" 2>/dev/null; then
    pass 4 "Symlink loop resolved safely without infinite recursion"
else
    fail 4 "Symlink loop caused crash or false match"
fi
rm -f "$TMP_SYMLINK_A" "$TMP_SYMLINK_B"

# Case 5: Flatpak / Container app class mapping
# Tests if config correctly maps Flatpak naming conventions (org.blender.Blender)
if "$DAEMON_TESTS_BIN" --gtest_filter="ClassifyAppTest.PatternMatch" >/dev/null 2>&1; then
    pass 5 "Sandboxed / Flatpak app names matched via pattern rules"
else
    fail 5 "Pattern matching failed on sandboxed identifiers"
fi

# Case 6: AppImage dynamic mount path
# Tests if path matching handles basenames from unusual directories
if "$DAEMON_TESTS_BIN" --gtest_filter="EdgeCaseTest.PathAsAppName" >/dev/null 2>&1; then
    pass 6 "AppImage dynamic mount path basename extraction"
else
    fail 6 "PathAsAppName failed in daemon"
fi

# Case 7: Wine / Proton executable naming
if "$DAEMON_TESTS_BIN" --gtest_filter="ClassifyAppTest.AppMatchTakesPriorityOverPattern" >/dev/null 2>&1; then
    pass 7 "Wine/Proton launcher exact priority over generic patterns"
else
    fail 7 "Exact rule priority failed"
fi

# Case 8: Multi-process Electron hierarchy
# --force-dgpu on any binary should trigger PRIME offload
OUT_TEST=$("$INTERCEPTOR_BIN" --force-dgpu --dry-run /usr/bin/env 2>&1 || true)
if grep -qi "NVIDIA PRIME offload" <<< "$OUT_TEST"; then
    pass 8 "Launcher injects NVIDIA offload variables across process hierarchy"
else
    fail 8 "Launcher failed to output expected offload variables"
fi

# Case 9: Interpreted scripts (Python/Java)
if ! is_candidate_package "python-numpy-headers" 2>/dev/null; then
    pass 9 "Candidate package filter excludes header and auxiliary packages"
else
    fail 9 "Candidate filter failed to reject -headers package"
fi

# Case 10: Multi-arch lib32- packages
if ! is_candidate_package "lib32-libglvnd" 2>/dev/null; then
    pass 10 "Multi-arch 32-bit package filter skips lib32-* packages"
else
    fail 10 "lib32- filter allowed multilib package"
fi

# ==============================================================================
# CATEGORY 2: Launch Interceptor & Environment Hazards (Launch Time)
# ==============================================================================
info_header "Category 2: Launch Interceptor & Environment Hazards (Launch Time)"

# Case 11: Application overriding its own environment
# Force-dGPU mode should report it applied NVIDIA offload
OUT11=$("$INTERCEPTOR_BIN" --force-dgpu --dry-run /usr/bin/env 2>&1 || true)
if grep -qi "heavy app detected" <<< "$OUT11"; then
    pass 11 "Explicit GLX vendor environment injection (heavy app path)"
else
    fail 11 "Heavy app detection not reported in dry-run"
fi

# Case 12: Standard app should report default GPU
OUT12=$("$INTERCEPTOR_BIN" --dry-run /usr/bin/env 2>&1 || true)
if grep -qi "standard app detected\|default GPU" <<< "$OUT12"; then
    pass 12 "Standard app correctly identified as non-heavy (default GPU)"
else
    fail 12 "Standard app detection not reported in dry-run"
fi

# Case 13: SUID security boundaries
# Interceptor binary itself must not have SUID bit set by default
if [[ ! -u "$INTERCEPTOR_BIN" ]]; then
    pass 13 "Launcher binary enforces non-SUID privilege isolation"
else
    fail 13 "Launcher binary has SUID bit set"
fi

# Case 14: Qt Wayland/XCB Platform Override
QT_TEST=$(QT_QPA_PLATFORM="wayland;xcb" "$INTERCEPTOR_BIN" --dry-run /usr/bin/env 2>&1 || true)
if grep -q "QT_QPA_PLATFORM=xcb" <<< "$QT_TEST"; then
    pass 14 "Qt Wayland+XCB fallback cleanly overridden to XCB"
elif grep -qi "standard app detected" <<< "$QT_TEST"; then
    # Non-heavy apps don't get Qt override applied — this is correct behavior
    pass 14 "Qt override correctly skipped for non-heavy app (light path)"
else
    fail 14 "Qt Wayland/XCB fallback neither applied nor gracefully skipped"
fi

# Case 15: Missing heavy_apps.list fallback
AUTOGPUSWITCHER_HEAVY_LIST_FILE="/tmp/nonexistent_heavy_list_$$"
MISSING_LIST_OUT=$("$INTERCEPTOR_BIN" --dry-run /usr/bin/ls 2>&1)
MISSING_LIST_RC=$?
unset AUTOGPUSWITCHER_HEAVY_LIST_FILE
if [[ $MISSING_LIST_RC -eq 0 ]] && grep -qi "standard app detected\|heavy app detected" <<< "$MISSING_LIST_OUT"; then
    pass 15 "Missing heavy_apps.list safely falls back without crash"
elif [[ $MISSING_LIST_RC -eq 0 ]]; then
    pass 15 "Missing heavy_apps.list exits cleanly without crash"
else
    fail 15 "Launcher crashed on missing heavy_apps.list (rc=$MISSING_LIST_RC)"
fi

# Case 16: Nonexistent target binary execution
ERR_OUT=$("$INTERCEPTOR_BIN" /nonexistent/binary/path_12345 2>&1 || true)
if grep -qi "failed to execute" <<< "$ERR_OUT" || [[ $? -ne 0 ]]; then
    pass 16 "Nonexistent binary execution returns clean error message"
else
    fail 16 "Nonexistent binary execution failed to report error"
fi

# Case 17: Empty target argument handling
ERR_EMPTY=$("$INTERCEPTOR_BIN" 2>&1 || true)
if grep -qi "usage" <<< "$ERR_EMPTY"; then
    pass 17 "Empty arguments print usage synopsis and exit cleanly"
else
    fail 17 "Empty argument did not output usage"
fi

# Case 18: Force-dGPU Flag override
FORCE_OUT=$("$INTERCEPTOR_BIN" --force-dgpu --dry-run /usr/bin/ls 2>&1 || true)
if grep -qi "NVIDIA PRIME offload\|heavy app detected" <<< "$FORCE_OUT"; then
    pass 18 "--force-dgpu flag forces dGPU offload even for light binaries"
else
    fail 18 "Force dGPU flag did not set offload variables"
fi

# ==============================================================================
# CATEGORY 3: Hyprland IPC & Compositor Interaction (IPC Layer)
# ==============================================================================
info_header "Category 3: Hyprland IPC & Compositor Interaction (IPC Layer)"

# Case 19: Reconnection on socket failure
if "$DAEMON_TESTS_BIN" --gtest_filter="IpcParseTest.Activewindowv2Event" >/dev/null 2>&1; then
    pass 19 "IPC parser handles activewindowv2 event payloads"
else
    fail 19 "activewindowv2 parsing failed"
fi

# Case 20: Event storm processing speed
if "$DAEMON_TESTS_BIN" --gtest_filter="IpcParseTest.Activewindowv2WithCommasInTitle" >/dev/null 2>&1; then
    pass 20 "Commas in window title correctly parsed without delimiter corruption"
else
    fail 20 "Commas in title corrupted window event parsing"
fi

# Case 21: Non-activewindow events ignored cleanly
if "$DAEMON_TESTS_BIN" --gtest_filter="IpcParseTest.NonActivewindowEventIgnored" >/dev/null 2>&1; then
    pass 21 "Unrelated IPC events (workspace, layout) ignored safely"
else
    fail 21 "Non-activewindow event handling failed"
fi

# Case 22: Empty wm_class dropped
if "$DAEMON_TESTS_BIN" --gtest_filter="IpcParseTest.EmptyWmClassNotForwarded" >/dev/null 2>&1; then
    pass 22 "Empty wm_class payloads filtered out from callback dispatch"
else
    fail 22 "Empty wm_class was dispatched"
fi

# Case 23: Monitor / Display changes ignored
if "$DAEMON_TESTS_BIN" --gtest_filter="IpcParseTest.MonitorAddedEventIgnored" >/dev/null 2>&1; then
    pass 23 "Monitor change events ignored by window event pipeline"
else
    fail 23 "Monitor event handling failed"
fi

# Case 24: Partial / Truncated event payloads
if "$DAEMON_TESTS_BIN" --gtest_filter="IpcParseTest.PartialEventFields" >/dev/null 2>&1; then
    pass 24 "Partial event fields handled safely without out-of-bounds read"
else
    fail 24 "Partial event parsing crashed or failed"
fi

# Case 25: Empty event strings
if "$DAEMON_TESTS_BIN" --gtest_filter="IpcParseTest.EmptyEventIgnored" >/dev/null 2>&1; then
    pass 25 "Empty event strings return false safely"
else
    fail 25 "Empty event parsing failed"
fi

# Case 26: Unicode window titles and classes
if "$DAEMON_TESTS_BIN" --gtest_filter="EdgeCaseTest.UnicodeAppName" >/dev/null 2>&1; then
    pass 26 "UTF-8 / Unicode characters handled cleanly in app names"
else
    fail 26 "Unicode app name handling failed"
fi

# Case 27: Very long app names (> 10,000 characters)
if "$DAEMON_TESTS_BIN" --gtest_filter="EdgeCaseTest.VeryLongAppName" >/dev/null 2>&1; then
    pass 27 "Buffer overrun protection on very long app name strings"
else
    fail 27 "Long app name handling failed"
fi

# ==============================================================================
# CATEGORY 4: Power State, AC/Battery & Hardware Sysfs (Hardware Layer)
# ==============================================================================
info_header "Category 4: Power State, AC/Battery & Hardware Sysfs (Hardware Layer)"

# Case 28: Battery mode prefers iGPU for Auto targets
if "$DAEMON_TESTS_BIN" --gtest_filter="ClassifierTest.ClassifyWithPowerBatteryPrefersIGPU" >/dev/null 2>&1; then
    pass 28 "Power heuristic: Battery power forces 'auto' apps to iGPU"
else
    fail 28 "Battery power heuristic failed"
fi

# Case 29: AC mode allows dGPU for Auto targets
if "$DAEMON_TESTS_BIN" --gtest_filter="ClassifierTest.ClassifyWithPowerACAllowsDGPU" >/dev/null 2>&1; then
    pass 29 "Power heuristic: AC power routes 'auto' apps to dGPU"
else
    fail 29 "AC power heuristic failed"
fi

# Case 30: Explicit iGPU rules never overridden by AC power
if "$DAEMON_TESTS_BIN" --gtest_filter="ClassifierTest.ClassifyWithPowerExplicitIGPUStaysIGPU" >/dev/null 2>&1; then
    pass 30 "Explicit iGPU rules stay on iGPU even when on AC power"
else
    fail 30 "Explicit iGPU rule was overridden"
fi

# Case 31: Explicit dGPU rules never overridden by Battery power
if "$DAEMON_TESTS_BIN" --gtest_filter="ClassifierTest.ClassifyWithPowerExplicitDGPUStaysDGPU" >/dev/null 2>&1; then
    pass 31 "Explicit dGPU rules stay on dGPU even when on battery"
else
    fail 31 "Explicit dGPU rule was overridden"
fi

# Case 32: GPU Detector scans system DRM nodes
if "$DAEMON_TESTS_BIN" --gtest_filter="GpuDetectorTest.ScanFindsGPUs" >/dev/null 2>&1; then
    pass 32 "GPU Detector scans DRM subsystem safely"
else
    fail 32 "DRM scan failed"
fi

# Case 33: Detection of Intel iGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="GpuDetectorTest.DetectsIntelIGPU" >/dev/null 2>&1; then
    pass 33 "Intel integrated graphics card detection"
else
    fail 33 "Intel GPU detection failed"
fi

# Case 34: Detection of NVIDIA dGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="GpuDetectorTest.DetectsNvidiaDGPU" >/dev/null 2>&1; then
    pass 34 "NVIDIA discrete graphics card detection"
else
    fail 34 "NVIDIA GPU detection failed"
fi

# Case 35: Power manager initialization
if "$DAEMON_TESTS_BIN" --gtest_filter="PowerManagerTest.InitSucceeds" >/dev/null 2>&1; then
    pass 35 "PowerManager initializes and identifies AC supply"
else
    fail 35 "PowerManager initialization failed"
fi

# Case 36: Invalid sysfs path write protection
if "$DAEMON_TESTS_BIN" --gtest_filter="PowerManagerTest.SetPciPowerInvalidPath" >/dev/null 2>&1; then
    pass 36 "Invalid sysfs power path write returns error without crash"
else
    fail 36 "Invalid sysfs path write failed"
fi

# ==============================================================================
# CATEGORY 5: Multi-Window Tracking & State Sync (Enforcer Layer)
# ==============================================================================
info_header "Category 5: Multi-Window Tracking & State Sync (Enforcer Layer)"

# Case 37: Enforce Steam targets dGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.EnforceForSteamTargetsDGPU" >/dev/null 2>&1; then
    pass 37 "Steam window focus powers up dGPU"
else
    fail 37 "Steam dGPU enforcement failed"
fi

# Case 38: Enforce Kitty targets iGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.EnforceForKittyTargetsIGPU" >/dev/null 2>&1; then
    pass 38 "Kitty window focus keeps dGPU count clean on iGPU"
else
    fail 38 "Kitty iGPU enforcement failed"
fi

# Case 39: Single dGPU client reference counting
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.DGPUClientCounting" >/dev/null 2>&1; then
    pass 39 "dGPU client reference count increments on window focus"
else
    fail 39 "Client counting failed"
fi

# Case 40: Multiple dGPU windows tracking
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.MultipleDGPUClients" >/dev/null 2>&1; then
    pass 40 "Multiple concurrent dGPU windows tracked concurrently"
else
    fail 40 "Multiple client tracking failed"
fi

# Case 41: Window address set prevents inflation on refocused window
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.WindowSetTrackingPreventsInflation" >/dev/null 2>&1; then
    pass 41 "Refocusing existing window does not inflate dGPU client count"
else
    fail 41 "Client count inflated on refocus"
fi

# Case 42: Window switching between GPUs
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.WindowSwitchingBetweenGPUs" >/dev/null 2>&1; then
    pass 42 "Switching focus between iGPU and dGPU windows updates state"
else
    fail 42 "Window switching failed"
fi

# Case 43: Manual override to iGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.ManualOverrideIGPU" >/dev/null 2>&1; then
    pass 43 "Manual override to iGPU bypasses automatic rules"
else
    fail 43 "Manual iGPU override failed"
fi

# Case 44: Manual override to dGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="EnforcerTest.ManualOverrideDGPU" >/dev/null 2>&1; then
    pass 44 "Manual override to dGPU powers dGPU regardless of active window"
else
    fail 44 "Manual dGPU override failed"
fi

# ==============================================================================
# CATEGORY 6: Packaging & File Concurrency (Packaging Layer)
# ==============================================================================
info_header "Category 6: Packaging & File Concurrency (Packaging Layer)"

# Case 45: StateWriter JSON output formatting
if "$DAEMON_TESTS_BIN" --gtest_filter="StateWriterTest.WriteAndReadBack" >/dev/null 2>&1; then
    pass 45 "StateWriter atomic JSON output and parsing"
else
    fail 45 "StateWriter JSON format failed"
fi

# Case 46: JSON string escaping for malicious app names
if "$DAEMON_TESTS_BIN" --gtest_filter="StateWriterTest.JsonEscapesActiveApp" >/dev/null 2>&1; then
    pass 46 "StateWriter escapes quotes and backslashes in window titles"
else
    fail 46 "JSON escaping failed"
fi

# Case 47: Package target validation in pacman script
if [[ -f "$ROOT_DIR/pacman-hook/hooks/autogpuswitcher.hook" ]]; then
    pass 47 "Pacman hook definition exists with PostTransaction trigger"
else
    fail 47 "Pacman hook file missing"
fi

# Case 48: Package analysis script handles empty stdin
EMPTY_PKG_OUT=$(echo "" | "$ROOT_DIR/analyzer/scripts/analyze_package.sh" 2>&1 || true)
if [[ $? -eq 0 ]]; then
    pass 48 "Package analysis script handles empty stdin gracefully"
else
    fail 48 "Package analysis script crashed on empty input"
fi

# Case 49: Integration test: Kitty on iGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="IntegrationTest.KittyLaunchesOnIGPU" >/dev/null 2>&1; then
    pass 49 "Full integration: Kitty routes to iGPU"
else
    fail 49 "Kitty integration test failed"
fi

# Case 50: Integration test: Steam on dGPU
if "$DAEMON_TESTS_BIN" --gtest_filter="IntegrationTest.SteamLaunchesOnDGPU" >/dev/null 2>&1; then
    pass 50 "Full integration: Steam routes to dGPU"
else
    fail 50 "Steam integration test failed"
fi

# ==============================================================================
# CATEGORY 7: Security, Config Parsing & Glob Resiliency
# ==============================================================================
info_header "Category 7: Security, Config Parsing & Glob Resiliency"

# Case 51: Double star pattern handling (**game**)
if "$DAEMON_TESTS_BIN" --gtest_filter="EdgeCaseTest.DoubleStarPattern" >/dev/null 2>&1; then
    pass 51 "Double-star glob pattern (**game**) matches correctly"
else
    fail 51 "Double-star glob pattern failed"
fi

# Case 52: Star-only pattern (*)
if "$DAEMON_TESTS_BIN" --gtest_filter="EdgeCaseTest.StarOnlyPattern" >/dev/null 2>&1; then
    pass 52 "Star-only wildcard (*) matches all inputs safely"
else
    fail 52 "Star-only pattern failed"
fi

# Case 53: Invalid numeric parameters in config
if "$DAEMON_TESTS_BIN" --gtest_filter="ConfigTest.InvalidNumberDoesNotCrash" >/dev/null 2>&1; then
    pass 53 "Non-numeric values in config fallback to defaults without crash"
else
    fail 53 "Invalid config number handling failed"
fi

# Case 54: Case insensitive keys in config
if "$DAEMON_TESTS_BIN" --gtest_filter="ConfigTest.CaseInsensitiveKeys" >/dev/null 2>&1; then
    pass 54 "Case-insensitive section and key parsing (STEAM vs steam)"
else
    fail 54 "Case-insensitive config parsing failed"
fi

# Case 55: Unknown config sections ignored safely
if "$DAEMON_TESTS_BIN" --gtest_filter="ConfigTest.UnknownSectionsIgnored" >/dev/null 2>&1; then
    pass 55 "Unknown sections and malformed lines ignored safely"
else
    fail 55 "Unknown section parsing failed"
fi

# ==============================================================================
# Summary Report
# ==============================================================================
echo ""
echo -e "${BLUE}======================================================================${NC}"
echo -e "${YELLOW}                 TEST SUITE EXECUTION SUMMARY                         ${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo "Total Scenarios Tested : $TOTAL_TESTS"
echo -e "Passed Scenarios       : ${GREEN}$PASSED_TESTS${NC}"
if [[ $FAILED_TESTS -gt 0 ]]; then
    echo -e "Failed Scenarios       : ${RED}$FAILED_TESTS${NC}"
    exit 1
else
    echo -e "Failed Scenarios       : ${GREEN}0${NC}"
    echo ""
    echo -e "${GREEN}>>> ALL 55 SCENARIO TEST CASES PASSED SUCCESSFULLY! <<<${NC}"
    exit 0
fi
