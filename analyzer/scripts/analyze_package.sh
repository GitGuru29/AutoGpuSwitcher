#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  analyze_package.sh [--record] package-name [...]

Finds executable files owned by pacman packages and analyzes them for heavy
graphics library usage.
EOF
}

ensure_state_dirs

record_matches=0

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

for package_name in "$@"; do
    pacman -Q "${package_name}" >/dev/null 2>&1 || continue

    mapfile -t binaries < <(
        pacman -Qlq "${package_name}" 2>/dev/null | while IFS= read -r path; do
            if is_elf_executable "${path}"; then
                printf '%s\n' "${path}"
            fi
        done
    )

    if (( ${#binaries[@]} == 0 )); then
        continue
    fi

    if (( record_matches )); then
        "${SCRIPT_DIR}/analyze_binary.sh" --record "${binaries[@]}" >/dev/null
    else
        "${SCRIPT_DIR}/analyze_binary.sh" "${binaries[@]}"
    fi
done
