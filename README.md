# AutoGpuSwitcher

Automatic GPU selection scaffold for Arch Linux.

## Phase 1

Phase 1 implements the detection pipeline:

- a `pacman` hook that reacts to package installs and upgrades
- a shell analyzer that inspects ELF executables with `ldd`
- a first-run scan for applications installed before AutoGpuSwitcher
- persistent state in `state/heavy_apps.list`
- installable pacman hook assets for system deployment

Heavy applications are detected by matching linked libraries against
[`analyzer/config/heavy_libs.conf`](./analyzer/config/heavy_libs.conf).
The scan ignores debug payloads and shared-library artifacts so it focuses on
launchable executables.

## Key Entrypoints

- `setup/first_run.sh`: prompts for the initial scan
- `setup/install_phase1.sh`: installs the hook and analyzer under `/usr/lib/autogpuswitcher`
- `analyzer/scripts/initial_scan.sh`: rebuilds the heavy app list
- `analyzer/scripts/analyze_package.sh`: analyzes pacman-owned files
- `analyzer/scripts/analyze_binary.sh`: analyzes specific ELF binaries
- `pacman-hook/post_transaction.sh`: hook entrypoint for new installs

## Runtime State

Runtime files are not meant to be committed:

- `state/heavy_apps.list`
- `state/first_run_complete`
- `state/logs/*`
- `state/cache/*`

The heavy-app list now stores records as:

```text
package-name|app-name|/full/path/to/binary
```

## Install Phase 1 System-Wide

Run this as root on Arch to install the hook and shell analyzer assets:

```bash
sudo ./setup/install_phase1.sh
```

This installs:

- hook file to `/usr/share/libalpm/hooks/autogpuswitcher.hook`
- project scripts to `/usr/lib/autogpuswitcher`
- config to `/etc/autogpuswitcher/autogpuswitcher.conf`
- writable runtime state to `/var/lib/autogpuswitcher`

After installation, run the initial scan:

```bash
./setup/first_run.sh --yes --verbose
```
