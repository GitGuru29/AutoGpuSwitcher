## Summary

<!-- What and why -->

## Verification

- [ ] Clean build, no warnings (`-Wall -Wextra -Wpedantic`)
- [ ] `./build/titan-gpu-tests` — 80/80
- [ ] `bash tests/run_all_scenarios.sh` — 60/60
- [ ] `bash tests/validate_steam.sh` (if launcher/analyzer touched)
- [ ] No new Python/timer dependencies (workload analysis stays in the daemon)
- [ ] Docs updated if behavior/commands changed
