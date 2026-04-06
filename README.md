# AutoGpuSwitcher

Automatic GPU selection scaffold for Arch Linux.

## Phase 1

Phase 1 implements the detection pipeline:

- a `pacman` hook that reacts to package installs and upgrades
- a shell analyzer that inspects ELF executables with `ldd`
- a first-run scan for applications installed before AutoGpuSwitcher
- persistent state in `state/heavy_apps.list`

Heavy applications are detected by matching linked libraries against
[`analyzer/config/heavy_libs.conf`](./analyzer/config/heavy_libs.conf).
The scan ignores debug payloads and shared-library artifacts so it focuses on
launchable executables.

## Key Entrypoints

- `setup/first_run.sh`: prompts for the initial scan
- `analyzer/scripts/initial_scan.sh`: rebuilds the heavy app list
- `analyzer/scripts/analyze_package.sh`: analyzes pacman-owned files
- `analyzer/scripts/analyze_binary.sh`: analyzes specific ELF binaries
- `pacman-hook/post_transaction.sh`: hook entrypoint for new installs
