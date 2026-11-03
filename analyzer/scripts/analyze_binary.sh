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
    local grep_args=()

    ldd_output=$(ldd "${binary_path}" 2>/dev/null || true)
    if [[ -n "${ldd_output}" ]]; then
        for pattern in "${heavy_patterns[@]}"; do
            if grep -Fq "${pattern}" <<< "${ldd_output}"; then
                return 0
            fi
        done
    fi

    # Game engines often dlopen their graphics backend at runtime, so ldd
    # shows no GL/Vulkan dependency. Unigine Superposition is one example:
    # the engine binary only contains the library name as a string. Fall back
    # to a raw binary scan, but keep the direct-link check above first because
    # it is cheaper and more precise.
    for pattern in "${heavy_patterns[@]}"; do
        grep_args+=(-e "${pattern}")
    done
    if grep -a -Fq -m1 "${grep_args[@]}" -- "${binary_path}" 2>/dev/null; then
        return 0
    fi

    # Some engines hide the backend behind a bundled library. Unigine's
    # superposition binary links libUnigine_x64.so, and that library is what
    # references libGL.so.1. Follow direct dependencies that live next to the
    # executable and scan them too.
    local bin_dir dep
    bin_dir=$(dirname "${binary_path}")
    while IFS= read -r dep; do
        [[ -f "${dep}" ]] || continue
        [[ "$(dirname "${dep}")" == "${bin_dir}" ]] || continue
        if grep -a -Fq -m1 "${grep_args[@]}" -- "${dep}" 2>/dev/null; then
            return 0
        fi
    done < <(ldd "${binary_path}" 2>/dev/null | awk '/=> \// {print $3}')

    return 1
}

# Skip ELF check when caller (analyze_package.sh) already validated —
# avoids running `file` twice per binary (was: 2x file + 2x ldd per binary)
skip_elf_check="${AUTOGPUSWITCHER_SKIP_ELF_CHECK:-0}"

for binary_path in "$@"; do
    if [[ "${skip_elf_check}" != "1" ]] && ! is_elf_executable "${binary_path}"; then
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
