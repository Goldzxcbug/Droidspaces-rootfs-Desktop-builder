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
    case "$ID:$VERSION_ID" in
        debian:13)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop pipewire pipewire-alsa pipewire-pulse wireplumber xdg-desktop-portal xdg-desktop-portal-kde powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
                dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools desktop-base dbus-user-session aha clinfo dmidecode libdisplay-info-bin wayland-utils xserver-xorg \
                kfind plasma-systemmonitor filelight glmark2 vkmark systemsettings kde-config-screenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat6-plugins webext-plasma-browser-integration libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop
            ;;
        ubuntu:24.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop kubuntu-settings-desktop kubuntu-wallpapers \
                pipewire pipewire-alsa pipewire-pulse wireplumber xdg-desktop-portal xdg-desktop-portal-kde powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
                dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools dbus-user-session aha clinfo dmidecode libdisplay-info-bin wayland-utils xserver-xorg \
                kfind plasma-systemmonitor filelight glmark2 systemsettings kde-config-screenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat-plugins plasma-browser-integration libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop \
                polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 language-pack-kde-zh-hans language-pack-zh-hans qt6-translations-l10n
            ;;
        ubuntu:25.10|ubuntu:26.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop kubuntu-settings-desktop kubuntu-wallpapers \
                pipewire pipewire-alsa pipewire-pulse wireplumber xdg-desktop-portal xdg-desktop-portal-kde powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
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
    local settings_package=systemsettings
    local -a x11_session_packages=(plasma-workspace-x11 kwin-x11)

    case "$VERSION_ID" in
        43|44) ;;
        45)
            settings_package=plasma-systemsettings
            # Fedora 45 Plasma 6.8 replaces the old X11 session packages.
            x11_session_packages=()
            ;;
        *) echo "KDE 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 xrandr xset xrdb xhost google-noto-cjk-fonts google-noto-emoji-color-fonts plasma-desktop pipewire pipewire-alsa pipewire-pulseaudio wireplumber xdg-desktop-portal xdg-desktop-portal-kde powerdevil kscreen plasma-pa ark kwin upower konsole \
        dolphin kate kinfocenter glx-utils pulseaudio-utils vulkan-tools fedora-logos aha clinfo dmidecode libdisplay-info wayland-utils xorg-x11-server-Xorg \
        kfind plasma-systemmonitor filelight glmark2 vkmark "$settings_package" kscreenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kf6-kimageformats plasma-browser-integration libcanberra-gtk3 gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop plasma-milou plasma-workspace "${x11_session_packages[@]}"
}

install_arch() {
    pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji plasma-desktop pipewire pipewire-alsa pipewire-pulse wireplumber xdg-desktop-portal xdg-desktop-portal-kde powerdevil kscreen plasma-pa ark kwin upower konsole \
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
