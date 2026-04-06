#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
# shellcheck source=../analyzer/scripts/common.sh
source "${PROJECT_ROOT}/analyzer/scripts/common.sh"
ANALYZE_PACKAGE_SCRIPT="${PROJECT_ROOT}/analyzer/scripts/analyze_package.sh"
LOG_FILE="${LOG_DIR}/pacman-hook.log"

ensure_state_dirs

mapfile -t package_names

if (( ${#package_names[@]} == 0 )); then
    echo "No package targets supplied to pacman hook." >> "${LOG_FILE}"
    exit 0
fi

{
    printf '[%s] analyzing %s package target(s)\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "${#package_names[@]}"
    "${ANALYZE_PACKAGE_SCRIPT}" --record "${package_names[@]}"
} >> "${LOG_FILE}" 2>&1
