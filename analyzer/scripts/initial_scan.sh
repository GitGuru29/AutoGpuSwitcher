#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=./common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
    cat <<'EOF'
Usage:
  initial_scan.sh [--force] [--verbose]

Scans currently installed pacman packages, classifies heavy applications, and
rebuilds state/heavy_apps.list from scratch.
EOF
}

ensure_state_dirs

force_scan=0
verbose_flag=0

while (($# > 0)); do
    case "${1}" in
        --help)
            usage
            exit 0
            ;;
        --force)
            force_scan=1
            shift
            ;;
        --verbose)
            verbose_flag=1
            export AUTOGPUSWITCHER_VERBOSE=1
            VERBOSE_MODE=1
            shift
            ;;
        *)
            echo "Unknown option: ${1}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

scan_started_at=$(date +%s)
scan_log_file="${LOG_DIR}/initial_scan.log"

if [[ -z "${AUTOGPUSWITCHER_LOG_REDIRECTED:-}" ]]; then
    export AUTOGPUSWITCHER_LOG_REDIRECTED=1
    exec > >(tee -a "${scan_log_file}") 2>&1
fi

if (( ! force_scan )) && first_run_is_complete; then
    echo "Initial scan already completed. Use --force to rebuild." >&2
    exit 0
fi

tmp_list=$(mktemp)
trap 'rm -f "${tmp_list}"' EXIT

: > "${tmp_list}"

mapfile -t packages < <(pacman -Qq)
total_packages=${#packages[@]}
processed_packages=0

echo "Starting initial scan for ${total_packages} installed packages..."

for package_name in "${packages[@]}"; do
    [[ -n "${package_name}" ]] || continue
    processed_packages=$((processed_packages + 1))
    if (( verbose_flag )); then
        AUTOGPUSWITCHER_PROGRESS_PREFIX="[${processed_packages}/${total_packages}] " \
            "${SCRIPT_DIR}/analyze_package.sh" --verbose "${package_name}" >> "${tmp_list}" || true
    else
        AUTOGPUSWITCHER_PROGRESS_PREFIX="[${processed_packages}/${total_packages}] " \
            "${SCRIPT_DIR}/analyze_package.sh" "${package_name}" >> "${tmp_list}" || true
    fi
done

grep -vE '^\s*($|#)' "${tmp_list}" | LC_ALL=C sort -u > "${HEAVY_LIST_FILE}"
mark_first_run_complete

scan_finished_at=$(date +%s)
scan_duration=$((scan_finished_at - scan_started_at))

echo "Initial scan complete. Recorded $(count_lines "${HEAVY_LIST_FILE}") heavy apps in ${scan_duration}s."
echo "Log written to ${scan_log_file}"
