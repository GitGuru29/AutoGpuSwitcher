#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  analyze_package.sh [--record] [--verbose] package-name [...]

Finds executable files owned by pacman packages and analyzes them for heavy
graphics library usage.
EOF
}

ensure_state_dirs

record_matches=0
progress_prefix="${AUTOGPUSWITCHER_PROGRESS_PREFIX:-}"

while (($# > 0)); do
    case "${1}" in
        --help)
            usage
            exit 0
            ;;
        --record)
            record_matches=1
            shift
            ;;
        --verbose)
            export AUTOGPUSWITCHER_VERBOSE=1
            VERBOSE_MODE=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

[[ $# -gt 0 ]] || {
    usage >&2
    exit 1
}

for package_name in "$@"; do
    pacman -Q "${package_name}" >/dev/null 2>&1 || continue
    is_candidate_package "${package_name}" || {
        verbose_log "skipping package by name filter: ${package_name}"
        continue
    }

    if [[ -n "${progress_prefix}" ]]; then
        printf '%s%s\n' "${progress_prefix}" "${package_name}" >&2
    fi

    mapfile -t package_paths < <(pacman -Qlq "${package_name}" 2>/dev/null)

    if ! printf '%s\n' "${package_paths[@]}" | grep -qE '^(/usr/bin/|/usr/sbin/|/opt/|/usr/lib/)'; then
        verbose_log "skipping package with no candidate roots: ${package_name}"
        continue
    fi

    mapfile -t binaries < <(
        printf '%s\n' "${package_paths[@]}" | while IFS= read -r path; do
            path_is_candidate_root "${path}" || continue
            if is_elf_executable "${path}"; then
                printf '%s\n' "${path}"
            fi
        done
    )

    if (( ${#binaries[@]} == 0 )); then
        verbose_log "no launchable executables found for package: ${package_name}"
        continue
    fi

    verbose_log "analyzing ${#binaries[@]} executable(s) for package: ${package_name}"

    if (( record_matches )); then
        AUTOGPUSWITCHER_PACKAGE_NAME="${package_name}" \
            AUTOGPUSWITCHER_SKIP_ELF_CHECK=1 \
            "${SCRIPT_DIR}/analyze_binary.sh" --record "${binaries[@]}" >/dev/null
    else
        AUTOGPUSWITCHER_PACKAGE_NAME="${package_name}" \
            AUTOGPUSWITCHER_SKIP_ELF_CHECK=1 \
            "${SCRIPT_DIR}/analyze_binary.sh" "${binaries[@]}"
    fi
done
