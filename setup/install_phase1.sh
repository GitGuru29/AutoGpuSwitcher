#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
INSTALL_ROOT="/usr/lib/autogpuswitcher"
HOOK_DEST="/usr/share/libalpm/hooks/autogpuswitcher.hook"
CONFIG_DIR="/etc/autogpuswitcher"
CONFIG_FILE="${CONFIG_DIR}/autogpuswitcher.conf"
STATE_DIR="/var/lib/autogpuswitcher"

install -d "${INSTALL_ROOT}"
install -d "${INSTALL_ROOT}/analyzer/scripts"
install -d "${INSTALL_ROOT}/analyzer/config"
install -d "${INSTALL_ROOT}/pacman-hook"
install -d "${CONFIG_DIR}"
install -d "${STATE_DIR}/cache"
install -d "${STATE_DIR}/logs"

install -m 0644 "${PROJECT_ROOT}/pacman-hook/hooks/autogpuswitcher.hook" "${HOOK_DEST}"
install -m 0755 "${PROJECT_ROOT}/pacman-hook/post_transaction.sh" "${INSTALL_ROOT}/pacman-hook/post_transaction.sh"
install -m 0755 "${PROJECT_ROOT}/analyzer/scripts/common.sh" "${INSTALL_ROOT}/analyzer/scripts/common.sh"
install -m 0755 "${PROJECT_ROOT}/analyzer/scripts/update_heavy_list.sh" "${INSTALL_ROOT}/analyzer/scripts/update_heavy_list.sh"
install -m 0755 "${PROJECT_ROOT}/analyzer/scripts/analyze_binary.sh" "${INSTALL_ROOT}/analyzer/scripts/analyze_binary.sh"
install -m 0755 "${PROJECT_ROOT}/analyzer/scripts/analyze_package.sh" "${INSTALL_ROOT}/analyzer/scripts/analyze_package.sh"
install -m 0755 "${PROJECT_ROOT}/analyzer/scripts/initial_scan.sh" "${INSTALL_ROOT}/analyzer/scripts/initial_scan.sh"
install -m 0644 "${PROJECT_ROOT}/analyzer/config/heavy_libs.conf" "${INSTALL_ROOT}/analyzer/config/heavy_libs.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    cat > "${CONFIG_FILE}" <<EOF
AUTOGPUSWITCHER_STATE_DIR=${STATE_DIR}
AUTOGPUSWITCHER_HEAVY_LIST_FILE=${STATE_DIR}/heavy_apps.list
AUTOGPUSWITCHER_FIRST_RUN_MARKER=${STATE_DIR}/first_run_complete
AUTOGPUSWITCHER_HEAVY_LIBS_FILE=${INSTALL_ROOT}/analyzer/config/heavy_libs.conf
EOF
fi

touch "${STATE_DIR}/heavy_apps.list"

echo "Phase 1 assets installed."
echo "Hook: ${HOOK_DEST}"
echo "Runtime state: ${STATE_DIR}"
echo "Config: ${CONFIG_FILE}"
