#!/usr/bin/env bash
# Generate .desktop launcher files for heavy apps that route through
# autogpuswitcher-launcher.

set -euo pipefail

DESKTOP_DIR="${1:-$HOME/.local/share/applications/autogpuswitcher}"
HEAVY_LIST="${AUTOGPUSWITCHER_HEAVY_LIST_FILE:-/var/lib/autogpuswitcher/heavy_apps.list}"

if [[ ! -f "$HEAVY_LIST" ]]; then
    echo "ERROR: heavy_apps.list not found at $HEAVY_LIST" >&2
    echo "Run 'sudo ./setup/first_run.sh' first." >&2
    exit 1
fi

mkdir -p "$DESKTOP_DIR"

generated=0
while IFS='|' read -r pkg app path; do
    [[ -z "$path" ]] && continue

    # Only generate for apps that exist
    [[ -x "$path" ]] || continue

    basename_app=$(basename "$path")
    # Skip generic shell/script wrappers
    case "$basename_app" in
        sh|bash|env|python*|perl*) continue ;;
    esac

    desktop_file="$DESKTOP_DIR/${basename_app}-autogpu.desktop"

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${basename_app} (dGPU)
Comment=Launch ${basename_app} on NVIDIA dGPU via AutoGpuSwitcher
Exec=autogpuswitcher-launcher ${path}
Terminal=false
Categories=Utility;
EOF

    chmod 0644 "$desktop_file"
    generated=$((generated + 1))
    echo "Generated: $desktop_file"
done < <(sort -u "$HEAVY_LIST")

echo ""
echo "Generated $generated .desktop files in $DESKTOP_DIR"
echo "Run 'update-desktop-database $DESKTOP_DIR' to refresh menu."
