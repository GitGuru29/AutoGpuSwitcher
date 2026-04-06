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
        normalize_app_name "${item}" >> "${tmp_file}"
    done
else
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        normalize_app_name "${line}" >> "${tmp_file}"
    done
fi

grep -vE '^\s*($|#)' "${tmp_file}" | LC_ALL=C sort -u > "${HEAVY_LIST_FILE}"
