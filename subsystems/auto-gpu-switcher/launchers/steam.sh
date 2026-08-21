#!/usr/bin/env bash
# Steam launcher — forces dGPU
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
exec steam "$@"
