#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  update_heavy_list.sh [app-name ...]
  printf '%s\n' app1 app2 | update_heavy_list.sh

Merges app names into state/heavy_apps.list and keeps the file unique and sorted.
EOF
}

ensure_state_dirs

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

tmp_file=$(mktemp)
trap 'rm -f "${tmp_file}"' EXIT

cat "${HEAVY_LIST_FILE}" > "${tmp_file}"

if [[ $# -gt 0 ]]; then
    for item in "$@"; do
        normalize_heavy_app_record "${item}" >> "${tmp_file}"
    done
else
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        normalize_heavy_app_record "${line}" >> "${tmp_file}"
    done
fi

# Atomic write with flock: readers (interceptor, launcher) must never see
# a truncated/empty list while the pacman hook is mid-write.
final_tmp="${HEAVY_LIST_FILE}.new"
grep -vE '^\s*($|#)' "${tmp_file}" | LC_ALL=C sort -u > "${final_tmp}"
if command -v flock >/dev/null 2>&1; then
    (
        flock -x 9
        mv -f "${final_tmp}" "${HEAVY_LIST_FILE}"
    ) 9>"${HEAVY_LIST_FILE}.lock"
else
    mv -f "${final_tmp}" "${HEAVY_LIST_FILE}"
fi
