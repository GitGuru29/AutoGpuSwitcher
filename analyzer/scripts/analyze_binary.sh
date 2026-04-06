#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  analyze_binary.sh [--record] /path/to/binary [...]

Checks ELF executables with ldd and reports binaries that link against heavy
graphics libraries defined in analyzer/config/heavy_libs.conf.
EOF
}

ensure_state_dirs

record_matches=0
package_name="${AUTOGPUSWITCHER_PACKAGE_NAME:-unknown}"

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--record" ]]; then
    record_matches=1
    shift
fi

[[ $# -gt 0 ]] || {
    usage >&2
    exit 1
}

mapfile -t heavy_patterns < <(read_heavy_lib_patterns)
matches=()

binary_uses_heavy_libs() {
    local binary_path="$1"
    local ldd_output
    local pattern

    ldd_output=$(ldd "${binary_path}" 2>/dev/null || true)
    [[ -n "${ldd_output}" ]] || return 1

    for pattern in "${heavy_patterns[@]}"; do
        if grep -Fq "${pattern}" <<< "${ldd_output}"; then
            return 0
        fi
    done

    return 1
}

for binary_path in "$@"; do
    if ! is_elf_executable "${binary_path}"; then
        continue
    fi

    if binary_uses_heavy_libs "${binary_path}"; then
        app_name=$(normalize_app_name "${binary_path}")
        record=$(format_heavy_app_record "${package_name}" "${app_name}" "${binary_path}")
        printf '%s\n' "${record}"
        matches+=("${record}")
        verbose_log "heavy app detected: ${record}"
    fi
done

if (( record_matches )) && (( ${#matches[@]} > 0 )); then
    "${SCRIPT_DIR}/update_heavy_list.sh" "${matches[@]}"
fi
