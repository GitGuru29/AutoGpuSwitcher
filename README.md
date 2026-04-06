# AutoGpuSwitcher

Automatic GPU selection scaffold for Arch Linux.

This project is organized around:

- a `pacman` hook that detects new installs
- an analyzer that classifies apps as heavy or light
- a lightweight launcher/interceptor path for dGPU launches
- persistent state for heavy app tracking and first-run setup
