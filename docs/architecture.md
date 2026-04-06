# Architecture

## Flow

1. First run performs an initial scan of installed applications.
2. Pacman hooks trigger incremental analysis for future installs.
3. Heavy applications are recorded in `state/heavy_apps.list`.
4. The launcher checks the list and applies dGPU environment variables on launch.
