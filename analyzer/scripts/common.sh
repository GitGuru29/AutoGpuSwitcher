#!/usr/bin/env bash
# Library of shared functions. This file is SOURCED, not executed.
# Do NOT set -euo pipefail here — it would change strictness for every
# sourcing script (including tests/run_all_scenarios.sh which uses set -u only).

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "${SCRIPT_DIR}/../.." && pwd)
CONFIG_FILE_DEFAULT="/etc/autogpuswitcher/autogpuswitcher.conf"

if [[ -f "${AUTOGPUSWITCHER_CONFIG_FILE:-${CONFIG_FILE_DEFAULT}}" ]]; then
    # shellcheck disable=SC1090
    source "${AUTOGPUSWITCHER_CONFIG_FILE:-${CONFIG_FILE_DEFAULT}}"
fi

STATE_DIR="${AUTOGPUSWITCHER_STATE_DIR:-${PROJECT_ROOT}/state}"
CACHE_DIR="${STATE_DIR}/cache"
LOG_DIR="${STATE_DIR}/logs"
HEAVY_LIST_FILE="${AUTOGPUSWITCHER_HEAVY_LIST_FILE:-${STATE_DIR}/heavy_apps.list}"
MANUAL_HEAVY_LIST_FILE="${AUTOGPUSWITCHER_MANUAL_HEAVY_LIST_FILE:-${STATE_DIR}/manual_heavy_apps.list}"
FIRST_RUN_MARKER="${AUTOGPUSWITCHER_FIRST_RUN_MARKER:-${STATE_DIR}/first_run_complete}"
HEAVY_LIBS_FILE="${AUTOGPUSWITCHER_HEAVY_LIBS_FILE:-${PROJECT_ROOT}/analyzer/config/heavy_libs.conf}"
CLASSIFIER_FILE="${AUTOGPUSWITCHER_CLASSIFIER_FILE:-${PROJECT_ROOT}/analyzer/config/classifier.conf}"
VERBOSE_MODE="${AUTOGPUSWITCHER_VERBOSE:-0}"

# Safe defaults in case the classifier config is missing. Keep these in sync
# with analyzer/config/classifier.conf.
HEAVY_CATEGORIES=(
    Game Benchmark Graphics 2DGraphics 3DGraphics VectorGraphics
    RasterGraphics Photography
)
EXCLUDED_CATEGORIES=(
    Utility System Settings DesktopSettings Development FileManager
    TerminalEmulator TextEditor Network Office Audio Qt KDE ConsoleOnly Viewer
)
BENCHMARK_PACKAGES=(gputest unigine-* vkmark glmark2 glmark2-* *benchmark*)
GAME_LAUNCHER_PACKAGES=(
    steam lutris heroic-* bottles itch itch-* prismlauncher multimc
    minecraft-launcher retroarch dolphin-emu ppsspp pcsx2 rpcs3 ryujinx yuzu
    cemu duckstation xemu melonds mupen64plus scummvm dosbox dosbox-staging
    wine proton proton-ge-custom
)
EXCLUDED_PACKAGES=(
    hyprland xwayland dolphin baloo pavucontrol-qt pinentry
    polkit-kde-agent zxing-cpp gtk3 gtk4
)

if [[ -f "${CLASSIFIER_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${CLASSIFIER_FILE}"
fi

ensure_state_dirs() {
    mkdir -p "${STATE_DIR}" "${CACHE_DIR}" "${LOG_DIR}"
    touch "${HEAVY_LIST_FILE}"
    touch "${MANUAL_HEAVY_LIST_FILE}"
}

read_heavy_lib_patterns() {
    # grep exits 1 when config is all comments/blank — must not abort
    # callers running under set -e (they'd get an empty pattern array
    # and silently classify every binary as "not heavy")
    grep -vE '^\s*($|#)' "${HEAVY_LIBS_FILE}" || true
}

normalize_app_name() {
    local input="${1:-}"
    basename -- "${input}"
}

format_heavy_app_record() {
    local package_name="${1:-unknown}"
    local app_name="${2:-}"
    local binary_path="${3:-}"

    printf '%s|%s|%s\n' "${package_name}" "${app_name}" "${binary_path}"
}

normalize_heavy_app_record() {
    local input="${1:-}"

    if [[ "${input}" == *'|'* ]]; then
        printf '%s\n' "${input}"
    else
        normalize_app_name "${input}"
    fi
}

is_elf_executable() {
    local path="${1:-}"
    local file_output

    [[ -f "${path}" && -x "${path}" ]] || return 1
    should_scan_path "${path}" || return 1

    file_output=$(file -Lb "${path}" 2>/dev/null || true)
    [[ -n "${file_output}" ]] || return 1

    grep -Eq 'ELF .* (executable|pie executable),' <<< "${file_output}"
}

should_scan_path() {
    local path="${1:-}"

    [[ -n "${path}" ]] || return 1
    [[ "${path}" != /usr/lib/debug/* ]] || return 1
    [[ "${path}" != *.debug ]] || return 1
    [[ "${path}" != *.so ]] || return 1
    [[ "${path}" != *.so.* ]] || return 1
    [[ "${path}" != /usr/include/* ]] || return 1
    [[ "${path}" != /usr/share/* ]] || return 1

    return 0
}

count_lines() {
    local path="${1:-}"

    if [[ -f "${path}" ]]; then
        wc -l < "${path}"
    else
        echo 0
    fi
}

log_info() {
    printf '%s\n' "$*" >&2
}

verbose_log() {
    if [[ "${VERBOSE_MODE}" == "1" ]]; then
        log_info "$@"
    fi
}

is_candidate_package() {
    local package_name="${1:-}"

    [[ -n "${package_name}" ]] || return 1
    [[ "${package_name}" != *-headers ]] || return 1
    [[ "${package_name}" != lib32-* ]] || return 1

    return 0
}

matches_any_glob() {
    local value="${1,,}"
    local pattern

    shift || true
    for pattern in "$@"; do
        # case patterns undergo glob expansion, unlike the right-hand side of
        # [[ == ]] when it is quoted. The expansion is an intentional glob.
        # shellcheck disable=SC2254
        case "${value}" in
            ${pattern,,}) return 0 ;;
        esac
    done
    return 1
}

desktop_file_is_heavy() {
    local desktop_file="${1:-}"
    local categories category lower
    local has_game=0 has_benchmark=0 has_heavy=0
    local has_av=0 has_video=0 has_excluded=0 has_viewer=0

    [[ -f "${desktop_file}" ]] || return 1

    categories=$(grep -m1 '^Categories=' "${desktop_file}" 2>/dev/null | cut -d= -f2- || true)
    [[ -n "${categories}" ]] || return 1

    local -a cats=()
    IFS=';' read -r -a cats <<< "${categories}"

    for category in "${cats[@]}"; do
        # Trim leading/trailing whitespace.
        category="${category#"${category%%[![:space:]]*}"}"
        category="${category%"${category##*[![:space:]]}"}"
        [[ -n "${category}" ]] || continue
        lower="${category,,}"

        case "${lower}" in
            game) has_game=1 ;;
            benchmark) has_benchmark=1 ;;
            audiovideo) has_av=1 ;;
            video|recorder|tv) has_video=1 ;;
            viewer) has_viewer=1 ;;
        esac

        if matches_any_glob "${lower}" "${HEAVY_CATEGORIES[@]}"; then
            has_heavy=1
        fi
        if matches_any_glob "${lower}" "${EXCLUDED_CATEGORIES[@]}"; then
            has_excluded=1
        fi
    done

    # Game/Benchmark are decisive. A viewer or utility is not a game even if
    # it also advertises a Graphics category (image viewers, KDE tools, ...).
    (( has_game || has_benchmark )) && return 0
    (( has_viewer )) && return 1
    (( has_heavy )) && return 0

    # Audio/video apps are only considered heavy when they actually handle
    # video (mpv, VLC, OBS, kdenlive). Music players fall through to the
    # excluded Audio category.
    (( has_av && has_video )) && return 0
    (( has_excluded )) && return 1

    return 1
}

# Return 0 when a pacman package is worth scanning for heavy binaries.
# Optional extra arguments are package file paths; when omitted, pacman is
# queried. Tests pass explicit paths so they never depend on installed packages.
is_heavy_package() {
    local package_name="${1:-}"
    local lower paths=() path

    [[ -n "${package_name}" ]] || return 1
    shift || true

    if (($# > 0)); then
        paths=("$@")
    fi

    lower="${package_name,,}"

    matches_any_glob "${lower}" "${EXCLUDED_PACKAGES[@]}" && return 1
    matches_any_glob "${lower}" "${BENCHMARK_PACKAGES[@]}" && return 0
    matches_any_glob "${lower}" "${GAME_LAUNCHER_PACKAGES[@]}" && return 0

    if ((${#paths[@]} == 0)); then
        mapfile -t paths < <(pacman -Qlq "${package_name}" 2>/dev/null || true)
    fi

    for path in "${paths[@]}"; do
        [[ "${path}" == *.desktop ]] || continue
        [[ -f "${path}" ]] || continue
        desktop_file_is_heavy "${path}" && return 0
    done

    return 1
}

path_is_candidate_root() {
    local path="${1:-}"

    [[ "${path}" == /usr/bin/* ]] && return 0
    [[ "${path}" == /usr/sbin/* ]] && return 0
    [[ "${path}" == /opt/* ]] && return 0
    [[ "${path}" == /usr/lib/* ]] && return 0

    return 1
}

mark_first_run_complete() {
    cat > "${FIRST_RUN_MARKER}" <<EOF
completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF
}

first_run_is_complete() {
    [[ -f "${FIRST_RUN_MARKER}" ]] && grep -q '^completed_at=' "${FIRST_RUN_MARKER}" 2>/dev/null
}
