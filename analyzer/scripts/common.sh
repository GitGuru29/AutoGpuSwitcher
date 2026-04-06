#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
STATE_DIR="${PROJECT_ROOT}/state"
CACHE_DIR="${STATE_DIR}/cache"
LOG_DIR="${STATE_DIR}/logs"
HEAVY_LIST_FILE="${STATE_DIR}/heavy_apps.list"
FIRST_RUN_MARKER="${STATE_DIR}/first_run_complete"
HEAVY_LIBS_FILE="${PROJECT_ROOT}/analyzer/config/heavy_libs.conf"

ensure_state_dirs() {
    mkdir -p "${STATE_DIR}" "${CACHE_DIR}" "${LOG_DIR}"
    touch "${HEAVY_LIST_FILE}"
}

read_heavy_lib_patterns() {
    grep -vE '^\s*($|#)' "${HEAVY_LIBS_FILE}"
}

normalize_app_name() {
    local input="${1:-}"
    basename -- "${input}"
}

is_elf_executable() {
    local path="${1:-}"

    [[ -f "${path}" && -x "${path}" ]] || return 1

    file -Lb "${path}" 2>/dev/null | grep -q 'ELF'
}

mark_first_run_complete() {
    cat > "${FIRST_RUN_MARKER}" <<EOF
completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

first_run_is_complete() {
    [[ -f "${FIRST_RUN_MARKER}" ]] && grep -q '^completed_at=' "${FIRST_RUN_MARKER}" 2>/dev/null
}
