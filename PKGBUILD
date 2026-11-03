# Maintainer: GitGuru29 <your@email.example>
pkgname=autogpuswitcher
pkgver=0.1.0
pkgrel=1
pkgdesc="Automatic GPU selection for hybrid graphics: detection, launch interception, and workload-based switching"
arch=('x86_64')
url="https://github.com/GitGuru29/AutoGpuSwitcher"
license=('Apache-2.0')
depends=('bash' 'nvidia-utils')
optdepends=(
  'hyprland: window tracking via Titan daemon'
  'waybar: status module'
  'prime-select: fallback PRIME switching'
  'bbswitch: legacy dGPU power management'
  'fish: Fish shell aliases'
)
makedepends=('gcc' 'cmake')
backup=(
  'etc/autogpuswitcher/autogpuswitcher.conf'
  'etc/titan-gpu/config'
)
source=("$pkgname-$pkgver.tar.gz::https://github.com/GitGuru29/AutoGpuSwitcher/archive/refs/heads/$pkgname-$pkgver.tar.gz")
sha256sums=('SKIP')

prepare() {
    cd "$pkgname-$pkgver" || cd AutoGpuSwitcher-$pkgver

    # Build Titan daemon
    cmake -B build -S subsystems/auto-gpu-switcher \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DBUILD_TESTING=OFF
    cmake --build build -j"$(nproc)"

    # Build interceptor
    cmake -B interceptor/build -S interceptor \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr
    cmake --build interceptor/build -j"$(nproc)"
}

build() {
    # Binaries are built in prepare() since source layout differs
    :
}

package() {
    cd "$pkgname-$pkgver" || cd AutoGpuSwitcher-$pkgver

    # --- Titan daemon binaries ---
    install -Dm755 build/titan-gpu \
        "$pkgdir/usr/bin/titan-gpu"
    install -Dm755 build/titan-gpu-switcherd \
        "$pkgdir/usr/bin/titan-gpu-switcherd"

    # --- Interceptor launcher ---
    install -Dm755 interceptor/build/autogpuswitcher-launcher \
        "$pkgdir/usr/bin/autogpuswitcher-launcher"

    # --- Analyzer scripts (nested layout matching install_phase1.sh) ---
    install -dm755 "$pkgdir/usr/lib/autogpuswitcher/analyzer/scripts"
    install -dm755 "$pkgdir/usr/lib/autogpuswitcher/analyzer/config"
    install -dm755 "$pkgdir/usr/lib/autogpuswitcher/pacman-hook"
    local script
    for script in analyzer/scripts/*.sh; do
        install -Dm755 "$script" \
            "$pkgdir/usr/lib/autogpuswitcher/analyzer/scripts/$(basename "$script")"
    done
    install -Dm644 analyzer/config/heavy_libs.conf \
        "$pkgdir/usr/lib/autogpuswitcher/analyzer/config/heavy_libs.conf"

    # --- Pacman hook (nested path matching .hook Exec= line) ---
    install -Dm644 pacman-hook/hooks/autogpuswitcher.hook \
        "$pkgdir/usr/share/libalpm/hooks/autogpuswitcher.hook"
    install -Dm755 pacman-hook/post_transaction.sh \
        "$pkgdir/usr/lib/autogpuswitcher/pacman-hook/post_transaction.sh"

    # --- First-run / installer helpers ---
    install -Dm755 setup/first_run.sh \
        "$pkgdir/usr/lib/autogpuswitcher/first_run.sh"

    # --- Config files ---
    install -Dm644 /dev/null \
        "$pkgdir/etc/autogpuswitcher/autogpuswitcher.conf"
    install -Dm644 subsystems/auto-gpu-switcher/configs/titan-gpu.config.default \
        "$pkgdir/etc/titan-gpu/config"

    # --- Systemd units ---
    install -Dm644 integration/systemd/titan-gpu-switcherd.service \
        "$pkgdir/usr/lib/systemd/system/titan-gpu-switcherd.service"

    # --- Shell integration ---
    install -Dm644 integration/shell/bash_aliases.sh \
        "$pkgdir/usr/share/autogpuswitcher/bash_aliases.sh"
    install -Dm644 integration/shell/fish_aliases.fish \
        "$pkgdir/usr/share/autogpuswitcher/fish_aliases.fish"
    install -Dm755 integration/shell/autogpu-run.sh \
        "$pkgdir/usr/bin/autogpu-run"

    # --- Desktop integration generator ---
    install -Dm755 integration/desktop/generate_desktop_entries.sh \
        "$pkgdir/usr/lib/autogpuswitcher/generate_desktop_entries.sh"

    # --- Waybar module ---
    install -Dm755 subsystems/auto-gpu-switcher/waybar/titan-gpu.sh \
        "$pkgdir/usr/lib/autogpuswitcher/waybar-titan-gpu.sh"
    install -Dm644 subsystems/auto-gpu-switcher/waybar/titan-gpu.css \
        "$pkgdir/usr/lib/autogpuswitcher/waybar-titan-gpu.css"

    # --- Udev rules ---
    install -Dm644 subsystems/auto-gpu-switcher/udev/99-nvidia-power.rules \
        "$pkgdir/usr/lib/udev/rules.d/99-nvidia-power.rules"

    # --- Heavy libs config (etc copy for user overrides) ---
    install -Dm644 analyzer/config/heavy_libs.conf \
        "$pkgdir/etc/autogpuswitcher/heavy_libs.conf"

    # --- Runtime state dir (0755 — read by root hook, not world-writable) ---
    install -dm755 "$pkgdir/var/lib/autogpuswitcher"
}
