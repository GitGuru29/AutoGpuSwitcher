# Shell Integration

Shell wrappers and aliases for AutoGpuSwitcher.

## Files

| File | Shell | Purpose |
|------|-------|---------|
| `autogpu-run.sh` | Any | Universal wrapper — routes any command through the launcher |
| `bash_aliases.sh` | Bash | Aliases for heavy apps + GPU switch commands |
| `fish_aliases.fish` | Fish | Same as above, for Fish shell |

## Installation

```bash
# Copy to system location
sudo mkdir -p /usr/lib/autogpuswitcher/integration/shell
sudo cp integration/shell/* /usr/lib/autogpuswitcher/integration/shell/

# Bash — add to ~/.bashrc
echo 'source /usr/lib/autogpuswitcher/integration/shell/bash_aliases.sh' >> ~/.bashrc

# Fish — add to ~/.config/fish/config.fish
echo 'source /usr/lib/autogpuswitcher/integration/shell/fish_aliases.fish' >> ~/.config/fish/config.fish
```

## Usage

```bash
# Wrapped apps automatically go through the launcher
steam              # → autogpuswitcher-launcher steam

# Manual GPU switch
gpu-nvidia         # Force dGPU
gpu-intel          # Force iGPU
gpu-auto           # Auto mode

# GPU status
gpustatus          # Titan daemon status or nvidia-smi fallback

# Wrap any arbitrary command
autogpu-run your-app --flag
```
