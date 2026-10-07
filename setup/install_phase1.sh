#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
INSTALL_ROOT="/usr/lib/autogpuswitcher"
HOOK_DEST="/usr/share/libalpm/hooks/autogpuswitcher.hook"
CONFIG_DIR="/etc/autogpuswitcher"
CONFIG_FILE="${CONFIG_DIR}/autogpuswitcher.conf"
STATE_DIR="/var/lib/autogpuswitcher"
BIN_DIR="/usr/bin"

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

# --- Install interceptor launcher (Phase 2) ---
LAUNCHER_BIN="${PROJECT_ROOT}/interceptor/build/autogpuswitcher-launcher"
if [[ -x "${LAUNCHER_BIN}" ]]; then
    install -m 0755 "${LAUNCHER_BIN}" "${BIN_DIR}/autogpuswitcher-launcher"
    echo "Interceptor launcher installed: ${BIN_DIR}/autogpuswitcher-launcher"
else
    echo "WARNING: interceptor binary not found at ${LAUNCHER_BIN}" >&2
    echo "         Build it first: cmake -B build -S interceptor && cmake --build build" >&2
fi

# --- Install workload auto-switcher script (Python) ---
install -m 0755 "${PROJECT_ROOT}/gpu_auto_switcher.py" "${INSTALL_ROOT}/gpu_auto_switcher.py"
echo "Auto-switcher script installed: ${INSTALL_ROOT}/gpu_auto_switcher.py"

# --- Install systemd units (if systemd is available) ---
SYSTEMD_DIR=""
if [[ -d /etc/systemd/system ]]; then
    SYSTEMD_DIR="/etc/systemd/system"
elif [[ -d "${HOME}/.config/systemd/user" ]]; then
    SYSTEMD_DIR="${HOME}/.config/systemd/user"
fi

if [[ -n "${SYSTEMD_DIR}" && -d "${PROJECT_ROOT}/integration/systemd" ]]; then
    for unit in autogpuswitcher.service autogpuswitcher.timer titan-gpu-switcherd.service; do
        if [[ -f "${PROJECT_ROOT}/integration/systemd/${unit}" ]]; then
            install -m 0644 "${PROJECT_ROOT}/integration/systemd/${unit}" "${SYSTEMD_DIR}/${unit}"
            echo "Systemd unit installed: ${SYSTEMD_DIR}/${unit}"
        fi
    done
    echo "Run 'systemctl daemon-reload' to register new units."
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    cat > "${CONFIG_FILE}" <<EOF
AUTOGPUSWITCHER_STATE_DIR=${STATE_DIR}
AUTOGPUSWITCHER_HEAVY_LIST_FILE=${STATE_DIR}/heavy_apps.list
AUTOGPUSWITCHER_FIRST_RUN_MARKER=${STATE_DIR}/first_run_complete
AUTOGPUSWITCHER_HEAVY_LIBS_FILE=${INSTALL_ROOT}/analyzer/config/heavy_libs.conf
AUTOGPUSWITCHER_LOG_FILE=${STATE_DIR}/logs/launcher.log
EOF
fi

touch "${STATE_DIR}/heavy_apps.list"

echo ""
echo "Phase 1+2 assets installed."
echo "Hook: ${HOOK_DEST}"
echo "Runtime state: ${STATE_DIR}"
echo "Config: ${CONFIG_FILE}"
echo "Launcher: ${BIN_DIR}/autogpuswitcher-launcher (if built)"
echo "Auto-switcher: ${INSTALL_ROOT}/gpu_auto_switcher.py"
echo ""
echo "Next steps:"
echo "  1. sudo ./setup/first_run.sh          # initial heavy-app scan"
echo "  2. sudo systemctl enable --now autogpuswitcher.timer  # auto-switch timer"
echo "  3. autogpuswitcher-launcher --dry-run glxinfo         # verify launcher"
