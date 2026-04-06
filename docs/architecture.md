# Architecture

## Flow

1. First run performs an initial scan of installed applications.
2. Pacman hooks trigger incremental analysis for future installs.
3. Heavy applications are recorded in `state/heavy_apps.list`.
4. The launcher checks the list and applies dGPU environment variables on launch.

## Phase 1 Notes

- Detection is based on `ldd` output and a configurable list of heavy libraries.
- The first-run marker is considered complete only when `state/first_run_complete`
  contains a `completed_at=` timestamp.
- The pacman hook expects package targets on stdin via `NeedsTargets`.
