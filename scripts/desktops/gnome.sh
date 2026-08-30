#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(
        XCURSOR_SIZE=48
        XDG_SESSION_TYPE=wayland
        XDG_CURRENT_DESKTOP=GNOME
        XDG_SESSION_DESKTOP=gnome
        GNOME_SHELL_SESSION_MODE=gnome
        WAYLAND_DISPLAY=wayland-0
        GNOME_WAYLAND_DISPLAY=wayland-0
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
        dbus-x11 dbus-user-session fonts-noto-cjk fonts-noto-color-emoji
        gnome-shell gnome-session gnome-control-center gnome-settings-daemon mutter
        gnome-terminal nautilus gnome-system-monitor gnome-tweaks
        gnome-keyring libpam-gnome-keyring polkitd upower
        pipewire pipewire-pulse wireplumber pulseaudio-utils
        mesa-utils vulkan-tools aha clinfo dmidecode glmark2 vkmark
        wayland-utils xwayland xdg-user-dirs xdg-desktop-portal-gnome
        file-roller evince eog gstreamer1.0-plugins-base gstreamer1.0-plugins-good
        libcanberra-pulse sound-theme-freedesktop
    )

    sed -i 's|^path-exclude=/usr/share/locale/\*/LC_MESSAGES/\*.mo|#&|' \
        /etc/dpkg/dpkg.cfg.d/excludes 2>/dev/null || true

    case "$ID:$VERSION_ID" in
        debian:13)
            packages+=(desktop-base)
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
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        *) echo "GNOME 不支持当前发行版：$ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *)
        echo "GNOME profile 操作无效：$1" >&2
        exit 1
        ;;
esac
