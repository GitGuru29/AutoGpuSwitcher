#!/usr/bin/env bash
# Generic dGPU launcher template
# Usage: generic-dgpu.sh <command> [args...]

if [ $# -eq 0 ]; then
    echo "Usage: $(basename "$0") <command> [args...]"
    exit 1
fi

export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
exec "$@"
