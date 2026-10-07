#!/usr/bin/env bash
# AutoGPU Switcher - Bash integration
# Source this file in ~/.bashrc:  source /usr/lib/autogpuswitcher/integration/shell/gpu_aliases.sh

# Wrap common GPU-heavy apps to route through the interceptor launcher
if command -v autogpuswitcher-launcher &>/dev/null; then
    for app in steam lutris blender obs mpv kdenlive davinci-resolve; do
        if command -v "$app" &>/dev/null; then
            alias "$app"="autogpuswitcher-launcher $app"
        fi
    done
fi

# Quick GPU status
alias gpustatus='titan-gpu status 2>/dev/null || nvidia-smi'

# Quick manual GPU switch
alias gpu-nvidia='titan-gpu set dgpu 2>/dev/null || sudo prime-select nvidia'
alias gpu-intel='titan-gpu set igpu 2>/dev/null || sudo prime-select intel'
alias gpu-auto='titan-gpu set auto 2>/dev/null || sudo prime-select intel'
