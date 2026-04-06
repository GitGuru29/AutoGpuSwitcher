#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  initial_scan.sh [--force]

Scans currently installed pacman packages, classifies heavy applications, and
rebuilds state/heavy_apps.list from scratch.
EOF
}

ensure_state_dirs

force_scan=0

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ "${1:-}" == "--force" ]]; then
    force_scan=1
fi

if (( ! force_scan )) && first_run_is_complete; then
    echo "Initial scan already completed. Use --force to rebuild." >&2
    exit 0
fi

tmp_list=$(mktemp)
trap 'rm -f "${tmp_list}"' EXIT

: > "${tmp_list}"

while IFS= read -r package_name; do
    [[ -n "${package_name}" ]] || continue
    "${SCRIPT_DIR}/analyze_package.sh" "${package_name}" >> "${tmp_list}" || true
done < <(pacman -Qq)

grep -vE '^\s*($|#)' "${tmp_list}" | LC_ALL=C sort -u > "${HEAVY_LIST_FILE}"
mark_first_run_complete

echo "Initial scan complete. Recorded $(wc -l < "${HEAVY_LIST_FILE}") heavy apps."
