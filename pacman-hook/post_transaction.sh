#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
ANALYZE_PACKAGE_SCRIPT="${PROJECT_ROOT}/analyzer/scripts/analyze_package.sh"
LOG_FILE="${PROJECT_ROOT}/state/logs/pacman-hook.log"

mkdir -p "${PROJECT_ROOT}/state/logs"

mapfile -t package_names

if (( ${#package_names[@]} == 0 )); then
    echo "No package targets supplied to pacman hook." >> "${LOG_FILE}"
    exit 0
fi

{
    printf '[%s] analyzing %s package target(s)\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${#package_names[@]}"
    "${ANALYZE_PACKAGE_SCRIPT}" --record "${package_names[@]}"
} >> "${LOG_FILE}" 2>&1
