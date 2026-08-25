#!/usr/bin/env bash
# Waybar custom module: Titan GPU status
# Add to waybar config: "custom/titan-gpu": { "exec": "titan-gpu-waybar", ... }

STATE_FILE="${TITAN_STATE_PATH:-/tmp/titan_gpu_state}"

if [ ! -f "$STATE_FILE" ]; then
    echo '{"text": "GPU: n/a", "tooltip": "Daemon not running"}'
    exit 0
fi

python3 -c "
import json, sys
try:
    with open('$STATE_FILE') as f:
        d = json.load(f)
    target = d.get('target', '?')
    power = d.get('power', '?')
    dgpu_power = d.get('dgpu_power', '?')
    active = d.get('active_app', '')

    icon = 'NVIDIA' if target == 'dgpu' else ('Intel' if target == 'igpu' else 'Auto')
    power_icon = 'BAT' if power == 'battery' else 'AC'
    tooltip = f'Target: {target}\\nPower: {power_icon}\\ndGPU: {dgpu_power}\\nApp: {active}'
    print(json.dumps({'text': f'{icon} [{target}]', 'tooltip': tooltip}))
except Exception:
    print('{\"text\": \"GPU: error\", \"tooltip\": \"Error parsing state file\"}')
" 2>/dev/null || echo '{"text": "GPU: n/a", "tooltip": "Daemon state unreadable"}'
