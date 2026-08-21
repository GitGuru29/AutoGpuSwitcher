#!/usr/bin/env bash
# mpv launcher — forces dGPU (Vulkan)
export __NV_PRIME_RENDER_OFFLOAD=1
exec mpv "$@"
