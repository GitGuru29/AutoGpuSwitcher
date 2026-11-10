# State

Runtime and persistent state files for AutoGpuSwitcher.

| File | Purpose |
|------|---------|
| `heavy_apps.list` | Detected heavy apps (pipe-delimited package/app/path records), rebuilt by the analyzer |
| `manual_heavy_apps.list` | User-pinned heavy apps; merged into every rebuild |
| `first_run_complete` | Marker written after the initial scan finishes |
| `cache/` | Analyzer cache |
| `logs/` | Analyzer, pacman-hook, and launcher logs |
