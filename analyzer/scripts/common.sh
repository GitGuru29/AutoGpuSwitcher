#!/usr/bin/env bash
# Library of shared functions. This file is SOURCED, not executed.
# Do NOT set -euo pipefail here — it would change strictness for every
# sourcing script (including tests/run_all_scenarios.sh which uses set -u only).

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
CONFIG_FILE_DEFAULT="/etc/autogpuswitcher/autogpuswitcher.conf"

if [[ -f "${AUTOGPUSWITCHER_CONFIG_FILE:-${CONFIG_FILE_DEFAULT}}" ]]; then
    # shellcheck disable=SC1090
    source "${AUTOGPUSWITCHER_CONFIG_FILE:-${CONFIG_FILE_DEFAULT}}"
fi

STATE_DIR="${AUTOGPUSWITCHER_STATE_DIR:-${PROJECT_ROOT}/state}"
CACHE_DIR="${STATE_DIR}/cache"
LOG_DIR="${STATE_DIR}/logs"
HEAVY_LIST_FILE="${AUTOGPUSWITCHER_HEAVY_LIST_FILE:-${STATE_DIR}/heavy_apps.list}"
FIRST_RUN_MARKER="${AUTOGPUSWITCHER_FIRST_RUN_MARKER:-${STATE_DIR}/first_run_complete}"
HEAVY_LIBS_FILE="${AUTOGPUSWITCHER_HEAVY_LIBS_FILE:-${PROJECT_ROOT}/analyzer/config/heavy_libs.conf}"
VERBOSE_MODE="${AUTOGPUSWITCHER_VERBOSE:-0}"

ensure_state_dirs() {
    mkdir -p "${STATE_DIR}" "${CACHE_DIR}" "${LOG_DIR}"
    touch "${HEAVY_LIST_FILE}"
}

read_heavy_lib_patterns() {
    # grep exits 1 when config is all comments/blank — must not abort
    # callers running under set -e (they'd get an empty pattern array
    # and silently classify every binary as "not heavy")
    grep -vE '^\s*($|#)' "${HEAVY_LIBS_FILE}" || true
}

normalize_app_name() {
    local input="${1:-}"
    basename -- "${input}"
}

format_heavy_app_record() {
    local package_name="${1:-unknown}"
    local app_name="${2:-}"
    local binary_path="${3:-}"

    printf '%s|%s|%s\n' "${package_name}" "${app_name}" "${binary_path}"
}

normalize_heavy_app_record() {
    local input="${1:-}"

    if [[ "${input}" == *'|'* ]]; then
        printf '%s\n' "${input}"
    else
        normalize_app_name "${input}"
    fi
}

is_elf_executable() {
    local path="${1:-}"
    local file_output

    [[ -f "${path}" && -x "${path}" ]] || return 1
    should_scan_path "${path}" || return 1

    file_output=$(file -Lb "${path}" 2>/dev/null || true)
    [[ -n "${file_output}" ]] || return 1

    grep -Eq 'ELF .* (executable|pie executable),' <<< "${file_output}"
}

should_scan_path() {
    local path="${1:-}"

    [[ -n "${path}" ]] || return 1
    [[ "${path}" != /usr/lib/debug/* ]] || return 1
    [[ "${path}" != *.debug ]] || return 1
    [[ "${path}" != *.so ]] || return 1
    [[ "${path}" != *.so.* ]] || return 1
    [[ "${path}" != /usr/include/* ]] || return 1
    [[ "${path}" != /usr/share/* ]] || return 1

    return 0
}

count_lines() {
    local path="${1:-}"

    if [[ -f "${path}" ]]; then
        wc -l < "${path}"
    else
        echo 0
    fi
}

log_info() {
    printf '%s\n' "$*" >&2
}

verbose_log() {
    if [[ "${VERBOSE_MODE}" == "1" ]]; then
        log_info "$@"
    fi
}

is_candidate_package() {
    local package_name="${1:-}"

    [[ -n "${package_name}" ]] || return 1
    [[ "${package_name}" != *-headers ]] || return 1
    [[ "${package_name}" != lib32-* ]] || return 1

    return 0
}

path_is_candidate_root() {
    local path="${1:-}"

    [[ "${path}" == /usr/bin/* ]] && return 0
    [[ "${path}" == /usr/sbin/* ]] && return 0
    [[ "${path}" == /opt/* ]] && return 0
    [[ "${path}" == /usr/lib/* ]] && return 0

    return 1
}

mark_first_run_complete() {
    cat > "${FIRST_RUN_MARKER}" <<EOF
completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

first_run_is_complete() {
    [[ -f "${FIRST_RUN_MARKER}" ]] && grep -q '^completed_at=' "${FIRST_RUN_MARKER}" 2>/dev/null
}
