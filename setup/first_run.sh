#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
INITIAL_SCAN_SCRIPT="${PROJECT_ROOT}/analyzer/scripts/initial_scan.sh"
FIRST_RUN_MARKER="${PROJECT_ROOT}/state/first_run_complete"

usage() {
    cat <<'EOF'
Usage:
  first_run.sh [--yes] [--force]

Prompts for the initial installed-app scan unless it has already completed.
EOF
}

auto_yes=0
force_scan=0

for arg in "$@"; do
    case "${arg}" in
        --yes)
            auto_yes=1
            ;;
        --force)
            force_scan=1
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: ${arg}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -f "${FIRST_RUN_MARKER}" ]] && grep -q '^completed_at=' "${FIRST_RUN_MARKER}" 2>/dev/null && (( ! force_scan )); then
    echo "Initial scan already completed."
    exit 0
fi

if (( ! auto_yes )); then
    printf 'Run initial GPU usage scan for installed applications now? [y/N] '
    read -r response
    case "${response}" in
        y|Y|yes|YES)
            ;;
        *)
            echo "Initial scan skipped."
            exit 0
            ;;
    esac
fi

if (( force_scan )); then
    exec "${INITIAL_SCAN_SCRIPT}" --force
else
    exec "${INITIAL_SCAN_SCRIPT}"
fi
