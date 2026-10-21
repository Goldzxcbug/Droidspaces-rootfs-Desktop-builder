#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

desktop=mango
xdg_desktop=mango

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(
        XDG_SESSION_CLASS=user
        XDG_SESSION_TYPE=wayland
        QT_QPA_PLATFORM=wayland
        ANLAND=1
        ANLAND_PRESENT_BACKEND=legacy
        ANLAND_SOCKET=/run/display.sock
        ANLAND_DRM_DEVICE=/dev/dri/renderD128
        ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
        XWAYLAND_GBM_DEVICE=/dev/dri/renderD128
        MESA_LOADER_DRIVER_OVERRIDE=kgsl
        GALLIUM_DRIVER=kgsl
        FD_FORCE_KGSL=1
        MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE=1
        FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "$desktop 显示后端无效：$backend" >&2
        return 1
    }
    assignments+=("XDG_CURRENT_DESKTOP=$xdg_desktop" "XDG_SESSION_DESKTOP=$xdg_desktop")
    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
    done
}

install_minimal_deb() {
    apt-get install -y --no-install-recommends \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        rofi foot alacritty fuzzel wl-clipboard \
        pipewire pipewire-alsa pipewire-pulse wireplumber upower \
        mesa-utils vulkan-tools wayland-utils xdg-user-dirs \
        fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
}

install_minimal_fedora() {
    dnf install -y --setopt=install_weak_deps=False \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        rofi foot alacritty fuzzel wl-clipboard \
        pipewire pipewire-alsa pipewire-pulseaudio wireplumber upower \
        glx-utils vulkan-tools wayland-utils xdg-user-dirs \
        google-noto-sans-fonts google-noto-sans-cjk-fonts google-noto-color-emoji-fonts
}

install_minimal_arch() {
    pacman -S --noconfirm --needed \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        rofi foot alacritty fuzzel wl-clipboard \
        pipewire pipewire-alsa pipewire-pulse wireplumber upower \
        mesa-utils vulkan-tools wayland-utils xdg-user-dirs \
        noto-fonts noto-fonts-cjk noto-fonts-emoji
}

install_profile() {
    case "$ID:${VERSION_ID:-}" in
        debian:13*|ubuntu:26.04*) install_minimal_deb ;;
        fedora:43*|fedora:44*) install_minimal_fedora ;;
        arch:*|archarm:*|archlinux:*) install_minimal_arch ;;
        *) echo "$desktop 不支持当前发行版：$ID $VERSION_ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "$desktop profile 操作无效：$1" >&2; exit 1 ;;
esac
