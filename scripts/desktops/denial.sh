#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

desktop=denial
xdg_desktop=Denial

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
        alacritty fuzzel wl-clipboard pipewire pipewire-alsa pipewire-pulse wireplumber upower \
        mesa-utils vulkan-tools wayland-utils xdg-user-dirs \
        fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
}

# Denial's plugin manager links the Dart SDK it finds in PATH instead of
# shipping a private copy, so compiling plugins depends on the image providing
# one. Arch packages dart; Debian, Ubuntu and Fedora do not, so the official SDK
# is installed from the upstream distribution channels here.
install_dart_deb() {
    local keyring=/etc/apt/keyrings/dart.asc
    local architecture list
    architecture="$(dpkg --print-architecture)"
    command -v curl >/dev/null 2>&1 || apt-get install -y --no-install-recommends curl
    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    if ! curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub -o "$keyring"; then
        rm -f -- "$keyring"
        echo '无法下载 Dart 软件包签名密钥。' >&2
        return 1
    fi
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$keyring" || {
        rm -f -- "$keyring"
        echo 'Dart 软件包签名密钥格式无效。' >&2
        return 1
    }
    chmod 0644 "$keyring"
    list=/etc/apt/sources.list.d/dart_stable.list
    printf 'deb [arch=%s signed-by=%s] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main\n' \
        "$architecture" "$keyring" > "$list"
    apt-get update
    if ! apt-get install -y --no-install-recommends dart; then
        # A failed install must not leave the image with an index the rest of the
        # build cannot use.
        rm -f -- "$list" "$keyring"
        apt-get update
        return 1
    fi
}

install_dart_fedora() {
    local architecture url temporary
    # Dart publishes these archives as arm64/x64, while uname reports the kernel
    # name; map the one onto the other before building the download URL.
    case "$(uname -m)" in
        aarch64|arm64) architecture=arm64 ;;
        x86_64|amd64) architecture=x64 ;;
        *) echo "Dart SDK 不支持的架构：$(uname -m)" >&2; return 1 ;;
    esac
    url="https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-${architecture}-release.zip"
    temporary="$(mktemp -d)"
    dnf install -y --setopt=install_weak_deps=False unzip curl
    if ! curl -fsSL -o "$temporary/dart.zip" "$url"; then
        rm -rf -- "$temporary"
        echo "无法下载 Dart SDK：$url" >&2
        return 1
    fi
    unzip -q "$temporary/dart.zip" -d /usr/lib/
    rm -rf -- "$temporary"
    ln -sfn /usr/lib/dart-sdk/bin/dart /usr/bin/dart
    ln -sfn /usr/lib/dart-sdk/bin/dartaotruntime /usr/bin/dartaotruntime
}

install_minimal_fedora() {
    dnf install -y --setopt=install_weak_deps=False \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        alacritty fuzzel wl-clipboard pipewire pipewire-alsa pipewire-pulseaudio wireplumber upower \
        glx-utils vulkan-tools wayland-utils xdg-user-dirs \
        google-noto-sans-fonts google-noto-sans-cjk-fonts google-noto-color-emoji-fonts
}

install_minimal_arch() {
    pacman -S --noconfirm --needed \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        alacritty fuzzel wl-clipboard pipewire pipewire-alsa pipewire-pulse wireplumber upower \
        mesa-utils vulkan-tools wayland-utils xdg-user-dirs \
        noto-fonts noto-fonts-cjk noto-fonts-emoji dart
}

install_profile() {
    case "$ID:${VERSION_ID:-}" in
        debian:13*|ubuntu:26.04*)
            install_minimal_deb
            install_dart_deb
            ;;
        fedora:43*|fedora:44*)
            install_minimal_fedora
            install_dart_fedora
            ;;
        arch:*|archarm:*|archlinux:*)
            # The official Arch dart package is already pulled in above, which
            # matches how Denial declares the dependency for this distribution.
            install_minimal_arch
            ;;
        *) echo "$desktop 不支持当前发行版：$ID $VERSION_ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "$desktop profile 操作无效：$1" >&2; exit 1 ;;
esac
