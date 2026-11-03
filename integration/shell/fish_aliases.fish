# AutoGPU Switcher - Fish integration
# Source this file in ~/.config/fish/config.fish:
#   source /usr/lib/autogpuswitcher/integration/shell/fish_aliases.fish

# Wrap common GPU-heavy apps to route through the interceptor launcher
if type -q autogpuswitcher-launcher
    for app in steam lutris blender obs mpv kdenlive davinci-resolve
        if type -q $app
            alias $app="autogpuswitcher-launcher $app"
        end
    end
end

# Quick GPU status
alias gpustatus='titan-gpu status 2>/dev/null; or nvidia-smi'

# Quick manual GPU switch
alias gpu-nvidia='titan-gpu set dgpu 2>/dev/null; or sudo prime-select nvidia'
alias gpu-intel='titan-gpu set igpu 2>/dev/null; or sudo prime-select intel'
alias gpu-auto='titan-gpu set auto 2>/dev/null; or sudo prime-select intel'
