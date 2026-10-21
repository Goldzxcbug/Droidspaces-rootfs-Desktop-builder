#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(
        XDG_SESSION_CLASS=user
        XCURSOR_SIZE=48
        XDG_SESSION_TYPE=wayland
        XDG_CURRENT_DESKTOP=GNOME
        XDG_SESSION_DESKTOP=gnome
        GNOME_SHELL_SESSION_MODE=gnome
        WAYLAND_DISPLAY=wayland-anland
        GNOME_WAYLAND_DISPLAY=wayland-anland
        QT_QPA_PLATFORM=wayland
        ANLAND=1
        ANLAND_SOCKET=/run/display.sock
        ANLAND_DRM_DEVICE=/dev/dri/renderD128
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "GNOME 显示后端无效：$backend" >&2
        return 1
    }

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
    done
}

install_apt() {
    local -a packages=(
        dbus-x11 dbus-user-session libdisplay-info-bin
        fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon mutter
        gnome-terminal gnome-text-editor nautilus gnome-system-monitor gnome-tweaks
        gnome-keyring libpam-gnome-keyring polkitd upower
        pipewire pipewire-alsa pipewire-pulse wireplumber pulseaudio-utils
        mesa-utils vulkan-tools aha clinfo dmidecode glmark2 vkmark
        wayland-utils xwayland xdg-user-dirs xdg-desktop-portal-gnome xdg-desktop-portal-gtk
        file-roller evince eog gnome-calculator gnome-disk-utility
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good
        libcanberra-pulse sound-theme-freedesktop
    )

    case "$ID:$VERSION_ID" in
        debian:13)
            packages+=(desktop-base gnome firefox-esr gnome-music)
            ;;
        ubuntu:26.04)
            packages+=(
                ubuntu-settings ubuntu-wallpapers
                yaru-theme-gnome-shell yaru-theme-gtk yaru-theme-icon yaru-theme-sound
                language-pack-gnome-zh-hans language-pack-zh-hans
            )
            ;;
        *)
            echo "GNOME 不支持当前系统：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac

    apt-get install -y --no-install-recommends "${packages[@]}"

    if [[ "$ID:$VERSION_ID" == debian:13 ]]; then
        systemctl --root=/ disable gdm3.service display-manager.service
        systemctl --root=/ mask gdm3.service display-manager.service
    fi
}

install_arch() {
    pacman -S --noconfirm --needed \
        noto-fonts noto-fonts-cjk noto-fonts-emoji \
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon mutter \
        gnome-terminal gnome-text-editor nautilus gnome-system-monitor gnome-tweaks \
        gnome-keyring polkit upower \
        pipewire pipewire-alsa pipewire-pulse wireplumber \
        mesa-utils vulkan-tools aha clinfo dmidecode glmark2 vkmark \
        wayland-utils xorg-xwayland xdg-user-dirs xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
        file-roller evince eog gnome-calculator gnome-disk-utility gst-plugins-base gst-plugins-good \
        libcanberra sound-theme-freedesktop gnome-backgrounds
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "GNOME 不支持当前发行版：$ID" >&2; return 1 ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "GNOME 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 libdisplay-info \
        google-noto-sans-cjk-fonts google-noto-color-emoji-fonts \
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon mutter \
        gnome-terminal gnome-text-editor nautilus gnome-system-monitor gnome-tweaks \
        gnome-keyring polkit upower pipewire pipewire-alsa pipewire-pulseaudio wireplumber \
        glx-utils vulkan-tools pulseaudio-utils aha clinfo dmidecode glmark2 vkmark \
        wayland-utils xorg-x11-server-Xwayland xdg-user-dirs \
        xdg-desktop-portal-gnome xdg-desktop-portal-gtk \
        file-roller evince eog gnome-calculator gnome-disk-utility \
        gstreamer1-plugins-base gstreamer1-plugins-good libcanberra sound-theme-freedesktop \
        gnome-backgrounds
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *)
        echo "GNOME profile 操作无效：$1" >&2
        exit 1
        ;;
esac
