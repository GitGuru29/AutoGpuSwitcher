#!/usr/bin/env bash
# autogpu-run - Shell wrapper that routes a command through the
# autogpuswitcher-launcher, falling back to direct execution if the
# launcher is not installed.

set -euo pipefail

LAUNCHER="autogpuswitcher-launcher"

if ! command -v "$LAUNCHER" &>/dev/null; then
    # Launcher not installed — run the command directly
    exec "$@"
fi

exec "$LAUNCHER" "$@"
