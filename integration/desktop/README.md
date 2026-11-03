# Desktop Integration

`.desktop` launcher files for heavy apps that route through `autogpuswitcher-launcher`.

## Files

| File | Purpose |
|------|---------|
| `generate_desktop_entries.sh` | Reads `heavy_apps.list` and generates `.desktop` entries |

## Usage

```bash
# Generate desktop entries for all detected heavy apps
./integration/desktop/generate_desktop_entries.sh

# Custom output directory
./integration/desktop/generate_desktop_entries.sh ~/.local/share/applications

# Refresh desktop database
update-desktop-database ~/.local/share/applications/autogpuswitcher
```

## What it does

1. Reads `state/heavy_apps.list` (populated by the Phase 1 analyzer)
2. For each heavy app found in `/usr/bin`, `/usr/sbin`, `/opt`, etc.
3. Creates a `.desktop` file that calls `autogpuswitcher-launcher <path>`
4. The launcher applies NVIDIA PRIME offload env vars before executing

Result: apps appear in your app menu with a `(dGPU)` suffix and
automatically render on the discrete GPU when launched.
