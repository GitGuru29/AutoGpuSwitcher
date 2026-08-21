# Titan GPU Auto-Switcher - Test Report

**Date:** 2026-08-21
**Host:** Arch Linux, Intel+NVIDIA hybrid (9A49 + 1C94), Hyprland
**Framework:** Google Test 1.17.0
**Compiler:** GCC 16.2.1, C++17, Debug build

---

## Summary

| Metric | Value |
|--------|-------|
| Total tests | 66 |
| Passed | 66 |
| Failed | 0 |
| Test suites | 11 |
| Execution time | 11ms |
| Bugs found during testing | 13 |
| Bugs fixed | 13 |

---

## Test Suites

### 1. ConfigTest (7 tests) -- INI Config Parser

| Test | Status | Description |
|------|--------|-------------|
| LoadValidConfig | PASS | Parses [power], [detector], [apps], [patterns] sections |
| MissingFileReturnsFalse | PASS | Returns false on nonexistent config path |
| InvalidNumberDoesNotCrash | PASS | stoul on "not_a_number" logs error, keeps defaults |
| CommentsAndBlankLinesIgnored | PASS | # comments and empty lines skipped |
| CaseInsensitiveKeys | PASS | DEFAULT_PROFILE matches default_profile |
| UnknownSectionsIgnored | PASS | [unknown_section] does not affect parsing |
| EmptyConfig | PASS | Empty file loads with all defaults |

### 2. GlobMatchTest (5 tests) -- Wildcard Pattern Engine

| Test | Status | Description |
|------|--------|-------------|
| StarPrefixAndSuffix | PASS | *game* matches "mygame", "game", "super_game_launcher" |
| StarPrefixOnly | PASS | *firefox matches "myfirefox", "firefox" |
| StarSuffixOnly | PASS | steam* matches "steam", "steamnative" |
| NoMatchFallsBack | PASS | Non-matching app returns "auto" |
| EmptyInput | PASS | Empty wm_class returns "auto" |

### 3. ClassifyAppTest (5 tests) -- App Classification Pipeline

| Test | Status | Description |
|------|--------|-------------|
| ExactAppMatch | PASS | "steam" -> "dgpu", "kitty" -> "igpu" |
| ExactAppMatchCaseInsensitive | PASS | "Steam"/"STEAM" -> "dgpu" |
| PatternMatch | PASS | "coolgame" matches *game* -> "dgpu" |
| AppMatchTakesPriorityOverPattern | PASS | Exact [apps] entry beats [patterns] |
| UnknownAppReturnsAuto | PASS | Unmatched app returns "auto" |

### 4. ClassifierTest (8 tests) -- GPU Target Resolution

| Test | Status | Description |
|------|--------|-------------|
| StringToTarget | PASS | "igpu"->IGPU, "dgpu"->DGPU, "auto"->Auto |
| StringToTargetCaseInsensitive | PASS | "IGPU"/"DGPU"/"Auto" case-insensitive |
| StringToTargetUnknown | PASS | "", "balanced", "garbage" -> Auto |
| TargetToString | PASS | Round-trip string conversion |
| ClassifyWithPowerBatteryPrefersIGPU | PASS | Auto + battery -> IGPU |
| ClassifyWithPowerACAllowsDGPU | PASS | Auto + AC -> DGPU |
| ClassifyWithPowerExplicitIGPUStaysIGPU | PASS | IGPU + AC stays IGPU |
| ClassifyWithPowerExplicitDGPUStaysDGPU | PASS | DGPU + battery stays DGPU |

### 5. IpcParseTest (7 tests) -- Hyprland Event Parser

| Test | Status | Description |
|------|--------|-------------|
| Activewindowv2Event | PASS | Full 4-field event parsed correctly |
| Activewindowv2WithCommasInTitle | PASS | Commas in title field preserved |
| NonActivewindowEventIgnored | PASS | workspace>>1 returns false |
| MonitorAddedEventIgnored | PASS | monitoradded>>DP-1 returns false |
| EmptyEventIgnored | PASS | Empty string returns false |
| EmptyWmClassNotForwarded | PASS | Empty wm_class not sent to callback |
| PartialEventFields | PASS | 3-field event (no title) extracts wm_class |

### 6. GpuDetectorTest (6 tests) -- Real sysfs GPU Enumeration

| Test | Status | Description |
|------|--------|-------------|
| ScanFindsGPUs | PASS | Detects 2 GPUs on this system |
| DetectsIntelIGPU | PASS | Intel 8086:9A49 with render node |
| DetectsNvidiaDGPU | PASS | NVIDIA 10DE:1C94 with PCI address |
| RenderNodesExist | PASS | /dev/dri/renderD128 and renderD129 exist |
| RenderNodeForVendor | PASS | Maps vendor enum to render node path |
| RenderNodeForUnknownVendor | PASS | AMD vendor returns empty (not present) |

### 7. PowerManagerTest (5 tests) -- Real sysfs Power Control

| Test | Status | Description |
|------|--------|-------------|
| InitSucceeds | PASS | AC path initialization |
| CurrentSourceValid | PASS | Returns AC/Battery/Unknown |
| IsOnBatteryConsistent | PASS | bool matches PowerSource enum |
| GetPciPowerOnRealDevice | PASS | Reads NVIDIA PCI power state |
| SetPciPowerInvalidPath | PASS | Invalid PCI addr returns false |

### 8. StateWriterTest (2 tests) -- JSON State Output

| Test | Status | Description |
|------|--------|-------------|
| WriteAndReadBack | PASS | Writes valid JSON with all fields |
| JsonEscapesActiveApp | PASS | Quotes, backslashes, newlines escaped |

### 9. EnforcerTest (7 tests) -- GPU Enforcement Logic

| Test | Status | Description |
|------|--------|-------------|
| EnforceForSteamTargetsDGPU | PASS | Config rule applied |
| EnforceForKittyTargetsIGPU | PASS | Config rule applied |
| DGPUClientCounting | PASS | Increment on dgpu, decrement on igpu |
| MultipleDGPUClients | PASS | Power stays on until last client gone |
| ManualOverrideIGPU | PASS | enforce_target(IGPU) works |
| ManualOverrideDGPU | PASS | enforce_target(DGPU) increments |
| ResetDGPUClients | PASS | reset_dgpu_clients() zeroes counter |

### 10. EdgeCaseTest (8 tests) -- Boundary Conditions

| Test | Status | Description |
|------|--------|-------------|
| VeryLongAppName | PASS | 1000-char string does not crash |
| UnicodeAppName | PASS | Japanese/emoji strings handled |
| PathAsAppName | PASS | "/usr/bin/steam" matched by [apps] |
| EmptyWmClass | PASS | Returns "auto" |
| DoubleStarPattern | PASS | ** matches everything |
| StarOnlyPattern | PASS | * matches everything |
| ClassifierRoundTrip | PASS | string_to_target <-> target_to_string |
| GpuVendorEnumValues | PASS | Intel=0x8086, NVIDIA=0x10de, AMD=0x1002 |

### 11. IntegrationTest (6 tests) -- Full Pipeline

| Test | Status | Description |
|------|--------|-------------|
| SteamLaunchesOnDGPU | PASS | steam -> config -> enforce -> DGPU |
| KittyLaunchesOnIGPU | PASS | kitty -> config -> enforce -> IGPU |
| GamePatternOnDGPU | PASS | cyberpunk2077 -> *game* -> DGPU |
| BrowserPatternOnIGPU | PASS | chromebrowser -> *browser* -> IGPU |
| UnknownAppFollowsPowerHeuristic | PASS | battery->IGPU, AC->DGPU |
| ManualOverrideIgnoresRules | PASS | enforce_target overrides config rules |

---

## Bugs Found and Fixed During Testing

| # | Severity | Component | Bug | Discovery Method |
|---|----------|-----------|-----|------------------|
| 1 | CRITICAL | Config | *game* multi-wildcard patterns never matched | GlobMatchTest |
| 2 | HIGH | Daemon | Manual set dgpu override ignored on window change | Code review |
| 3 | HIGH | Daemon | Idle power-off never called | Code review |
| 4 | HIGH | Daemon | profile CLI command unimplemented | Code review |
| 5 | MEDIUM | Enforcer | Env file written with daemon PID, never consumed | Code review |
| 6 | MEDIUM | IPC | No reconnection on Hyprland restart | Code review |
| 7 | HIGH | Config | std::stoul crash on invalid config values | ConfigTest |
| 8 | MEDIUM | StateWriter | JSON active_app not escaped | StateWriterTest |
| 9 | LOW | Enforcer | Dead code: transition_power(), current_power_state_ | Code review |
| 10 | MEDIUM | Config | classify_app fallback returned "balanced" not "auto" | Code review |
| 11 | HIGH | IPC | 3-field events (no title) could not extract wm_class | IpcParseTest |
| 12 | MEDIUM | CMake | CLI binary missing link sources for detector/power | Build error |
| 13 | LOW | Header | Missing cstdint in workload_classifier.hpp | Build error |

---

## Hardware-Specific Results

GPU Detection:
  NVIDIA 10DE:1C94 render=/dev/dri/renderD129 connected=no
  Intel  8086:9A49 render=/dev/dri/renderD128 connected=no

Power State:
  Source: AC (desktop, no battery)
  NVIDIA PCI power: auto (runtime PM enabled)

Known Limitation: PCI BDF addresses contain colons (e.g. 10DE:1C94)
which do not map directly to sysfs PCI device paths. The sysfs path
format is 0000:01:00.0 (domain:bus:device.function). The uevent parser
needs to extract the proper BDF address from PCI_SLOT_NAME instead of
PCI_ID for power control to work on real hardware.
