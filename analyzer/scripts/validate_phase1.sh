#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  validate_phase1.sh package-name [...]

Runs package analysis and prints any heavy-app records that would be produced.
EOF
}

if [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

[[ $# -gt 0 ]] || {
    usage >&2
    exit 1
}

"${SCRIPT_DIR}/analyze_package.sh" --verbose "$@"
