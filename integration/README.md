# Integration

System integration points that make AutoGpuSwitcher work end-to-end.

| Directory | What lives here |
|-----------|-----------------|
| `systemd/` | `titan-gpu-switcherd.service` — the daemon (window tracking + workload auto-switching) |
| `desktop/` | Generator that creates `.desktop` entries for detected heavy apps (runs on pacman post-transaction) |
| `shell/` | Bash/Fish aliases + the universal `autogpu-run` wrapper |
| `pacman-hook/` | `alpm-hooks` entry + `post_transaction.sh` (re-runs ELF analyzer, refreshes desktop entries) |

## Activation order

1. `pacman-hook/post_transaction.sh` fires on any package transaction
2. Analyzer updates `state/heavy_apps.list`
3. Desktop generator rebuilds `.desktop` entries → `X-GPUAutoSwitcher-Heavy=true`
4. Shell wrappers and `autogpuswitcher-launcher` read the list at launch time
5. `titan-gpu-switcherd` handles runtime power state per window focus + workload history

See [`systemd/README.md`](systemd/README.md) for service setup and
[`../README.md`](../README.md) for the full architecture.
