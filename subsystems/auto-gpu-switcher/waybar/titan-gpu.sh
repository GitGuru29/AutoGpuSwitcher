#!/usr/bin/env bash
# Waybar custom module: Titan GPU status
# Add to waybar config: "custom/titan-gpu": { "exec": "titan-gpu-waybar", ... }

STATE_FILE="/tmp/titan_gpu_state"

if [ ! -f "$STATE_FILE" ]; then
    echo '{"text": "GPU: n/a", "tooltip": "Daemon not running"}'
    exit 0
fi

target=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('target','?'))" 2>/dev/null || echo "?")
power=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('power','?'))" 2>/dev/null || echo "?")
dgpu_power=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('dgpu_power','?'))" 2>/dev/null || echo "?")
active=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('active_app',''))" 2>/dev/null || echo "")

case "$target" in
    dgpu) icon="NVIDIA" ;;
    igpu) icon="Intel" ;;
    *)    icon="Auto" ;;
esac

if [ "$power" = "battery" ]; then
    power_icon="BAT"
else
    power_icon="AC"
fi

tooltip="Target: ${target}\nPower: ${power_icon}\ndGPU: ${dgpu_power}\nApp: ${active}"

echo "{\"text\": \"${icon} [${target}]\", \"tooltip\": \"${tooltip}\"}"
