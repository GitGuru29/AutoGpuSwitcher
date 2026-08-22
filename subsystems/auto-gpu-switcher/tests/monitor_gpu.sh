#!/bin/bash
# Real-time GPU state monitor — watches nvidia-smi, sysfs power, daemon state
# Runs in a loop with color output. Press Ctrl+C to stop.
set -eo pipefail

PCI_ADDR="${1:-0000:01:00.0}"
STATE_FILE="${2:-/tmp/titan_gpu_state}"
INTERVAL="${3:-1}"

# Colors
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'
B='\033[0;34m'  C='\033[0;36m'  W='\033[1;37m'  D='\033[0m'

PCI_POWER="/sys/bus/pci/devices/$PCI_ADDR/power/control"
PCI_RUNTIME="/sys/bus/pci/devices/$PCI_ADDR/power/runtime_status"

clear
echo -e "${W}=== Titan GPU Live Monitor ===${D}"
echo -e "${C}PCI: $PCI_ADDR${D}"
echo -e "${C}Polling every ${INTERVAL}s — Ctrl+C to stop${D}"
echo ""

while true; do
    # --- Power State ---
    PSTATE="N/A"
    PRUNTIME="N/A"
    if [ -f "$PCI_POWER" ]; then
        PSTATE=$(cat "$PCI_POWER" 2>/dev/null || echo "N/A")
    fi
    if [ -f "$PCI_RUNTIME" ]; then
        PRUNTIME=$(cat "$PCI_RUNTIME" 2>/dev/null || echo "N/A")
    fi

    # Color based on power state
    case "$PSTATE" in
        auto) PCOL="$G" ;;
        on)   PCOL="$Y" ;;
        off)  PCOL="$R" ;;
        *)    PCOL="$D" ;;
    esac

    # --- nvidia-smi ---
    NVSMI_MEM=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A, N/A")
    NVSMI_UTIL=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "N/A")
    NVSMI_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 || echo "N/A")
    NVSMI_PROC=$(nvidia-smi --query-compute-apps=pid,name,used_memory --format=csv,noheader 2>/dev/null || echo "")

    # --- Daemon State ---
    DAEMON_TARGET="N/A"
    DAEMON_APP="N/A"
    DAEMON_DGPU_POWER="N/A"
    if [ -f "$STATE_FILE" ]; then
        DAEMON_TARGET=$(grep -o '"target": *"[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4 || echo "N/A")
        DAEMON_APP=$(grep -o '"active_app": *"[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4 || echo "N/A")
        DAEMON_DGPU_POWER=$(grep -o '"dgpu_power": *"[^"]*"' "$STATE_FILE" 2>/dev/null | cut -d'"' -f4 || echo "N/A")
    fi

    # --- Render ---
    echo -ne "\033[3A\033[J"  # Move up 3 lines, clear down

    echo -e "${W}┌─────────────────────────────────────────────────────────────────┐${D}"
    echo -e "${W}│${D} ${C}titan-gpu-switcherd${D} live monitor                       ${W}│${D}"
    echo -e "${W}├─────────────────────────────────────────────────────────────────┤${D}"

    echo -e "${W}│${D} ${W}PCI Power:${D}    ${PCOL}$(printf '%-8s' "$PSTATE")${D}  runtime: ${PCOL}$(printf '%-10s' "$PRUNTIME")${D}       ${W}│${D}"
    echo -e "${W}│${D} ${W}Daemon Target:${D} ${B}$(printf '%-8s' "$DAEMON_TARGET")${D}  Active:  ${B}$(printf '%-20s' "$DAEMON_APP")${D} ${W}│${D}"
    echo -e "${W}│${D} ${W}nvidia-smi:${D}   mem=${Y}${NVSMI_MEM}${D}  util=${Y}${NVSMI_UTIL}%${D}  temp=${Y}${NVSMI_TEMP}C${D}            ${W}│${D}"

    if [ -n "$NVSMI_PROC" ]; then
        echo -e "${W}│${D} ${W}GPU Procs:${D}"
        echo "$NVSMI_PROC" | while IFS=, read -r pid name mem; do
            name=$(echo "$name" | sed 's/^ *//;s/ *$//' | cut -c1-35)
            mem=$(echo "$mem" | sed 's/^ *//;s/ *$//')
            echo -e "${W}│${D}   ${G}PID $pid${D} ${name} (${mem} MiB)"
        done
    fi

    echo -e "${W}└─────────────────────────────────────────────────────────────────┘${D}"

    sleep "$INTERVAL"
done
