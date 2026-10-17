#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(XCURSOR_SIZE=48 XDG_SESSION_CLASS=user)

    case "$backend" in
        x11)
            assignments+=(DISPLAY=:5)
            ;;
        anland-wayland)
            assignments+=(
                WAYLAND_DISPLAY=wayland-0
                QT_QPA_PLATFORM=wayland
                ANLAND=1
                ANLAND_SOCKET=/run/display.sock
                ANLAND_DRM_DEVICE=/dev/dri/renderD128
                ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
            )
            case "$ID" in
                arch|archarm|archlinux)
                    assignments+=(XWAYLAND_GBM_DEVICE=/dev/dri/renderD128)
                    ;;
            esac
            ;;
        *)
            echo "KDE 显示后端无效：$backend" >&2
            return 1
            ;;
    esac

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
    done
}

install_apt() {
    sed -i 's|^path-exclude=/usr/share/locale/\*/LC_MESSAGES/\*.mo|#&|' \
        /etc/dpkg/dpkg.cfg.d/excludes 2>/dev/null || true

    case "$ID:$VERSION_ID" in
        debian:13)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
                dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools desktop-base dbus-user-session aha clinfo dmidecode libdisplay-info-bin wayland-utils xserver-xorg \
                kfind plasma-systemmonitor filelight glmark2 vkmark systemsettings kde-config-screenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat6-plugins webext-plasma-browser-integration libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop
            ;;
        ubuntu:24.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop kubuntu-settings-desktop kubuntu-wallpapers \
                pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
                dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools dbus-user-session aha clinfo dmidecode libdisplay-info-bin wayland-utils xserver-xorg \
                kfind plasma-systemmonitor filelight glmark2 systemsettings kde-config-screenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat-plugins plasma-browser-integration libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop \
                polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 language-pack-kde-zh-hans language-pack-zh-hans qt6-translations-l10n
            ;;
        ubuntu:25.10|ubuntu:26.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop kubuntu-settings-desktop kubuntu-wallpapers \
                pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
                dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools dbus-user-session aha clinfo dmidecode libdisplay-info-bin wayland-utils xserver-xorg \
                kfind plasma-systemmonitor filelight glmark2 vkmark systemsettings kde-config-screenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat6-plugins plasma-browser-integration libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop \
                polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 plasma-session-x11 language-pack-kde-zh-hans language-pack-zh-hans qt6-translations-l10n
            ;;
        *)
            echo "KDE 不支持当前系统：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "KDE 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    echo '%_install_langs all' > /etc/rpm/macros.image-language-conf
    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 xrandr xset xrdb xhost google-noto-cjk-fonts google-noto-emoji-color-fonts plasma-desktop pipewire pipewire-alsa pipewire-pulseaudio wireplumber powerdevil kscreen plasma-pa ark kwin upower konsole \
        dolphin kate kinfocenter glx-utils pulseaudio-utils vulkan-tools fedora-logos aha clinfo dmidecode libdisplay-info wayland-utils xorg-x11-server-Xorg \
        kfind plasma-systemmonitor filelight glmark2 vkmark systemsettings kscreenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kf6-kimageformats plasma-browser-integration libcanberra-gtk3 gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop plasma-milou plasma-workspace plasma-workspace-x11 kwin-x11
}

install_arch_portal_placeholder() {
    local package
    local portal_stub_dir portal_stub_archive portal_stub_readme portal_stub_size
    local -a portal_packages=()

    # plasma-integration requires xdg-desktop-portal-kde. Remove the real portal
    # packages, then satisfy package dependencies with an empty local provider.
    for package in xdg-desktop-portal-kde xdg-desktop-portal-gtk xdg-desktop-portal; do
        if pacman -Qq "$package" >/dev/null 2>&1; then
            portal_packages+=("$package")
        fi
    done
    if ((${#portal_packages[@]})); then
        pacman -Rdd --noconfirm "${portal_packages[@]}"
    fi
    if pacman -Qq droidspaces-noop-xdg-desktop-portals >/dev/null 2>&1; then
        return 0
    fi

    portal_stub_dir="$(mktemp -d /tmp/droidspaces-noop-portals.XXXXXXXX)"
    portal_stub_archive="$portal_stub_dir/droidspaces-noop-xdg-desktop-portals-1-1-any.pkg.tar.zst"
    portal_stub_readme="$portal_stub_dir/usr/share/doc/droidspaces-noop-xdg-desktop-portals/README"
    install -d "${portal_stub_readme%/*}"
    printf '%s\n' \
        'Dependency placeholder for the Droidspaces KDE container profile.' \
        'This package provides no XDG desktop portal implementation or service.' \
        > "$portal_stub_readme"
    portal_stub_size="$(wc -c < "$portal_stub_readme")"

    cat > "$portal_stub_dir/.PKGINFO" <<EOF
pkgname = droidspaces-noop-xdg-desktop-portals
pkgbase = droidspaces-noop-xdg-desktop-portals
pkgver = 1-1
pkgdesc = Empty dependency provider that disables XDG desktop portal packages
url = https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder
builddate = $(date +%s)
packager = Droidspaces rootfs desktop profile
size = $portal_stub_size
arch = any
license = custom
provides = xdg-desktop-portal
provides = xdg-desktop-portal-kde
provides = xdg-desktop-portal-gtk
EOF

    # Local package signatures may be required by the host pacman.conf.
    sed \
        -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
        -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
        /etc/pacman.conf > "$portal_stub_dir/pacman.conf"
    tar --zstd -cf "$portal_stub_archive" -C "$portal_stub_dir" \
        .PKGINFO usr/share/doc/droidspaces-noop-xdg-desktop-portals/README
    pacman --config "$portal_stub_dir/pacman.conf" -U --noconfirm "$portal_stub_archive"
    rm -rf -- "$portal_stub_dir"
}

install_arch() {
    install_arch_portal_placeholder

    pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji plasma-desktop pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin upower konsole \
        dolphin kate kinfocenter mesa-utils libpulse vulkan-tools aha clinfo dmidecode wayland-utils xorg-server \
        kfind plasma-systemmonitor filelight glmark2 vkmark systemsettings kscreenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kimageformats plasma-browser-integration libcanberra gstreamer gst-plugins-base gst-plugins-good sound-theme-freedesktop
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "KDE 不支持当前发行版：$ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "KDE profile 操作无效：$1" >&2; exit 1 ;;
esac
