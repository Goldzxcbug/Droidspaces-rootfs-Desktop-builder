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
        WAYLAND_DISPLAY=wayland-0
        QT_QPA_PLATFORM=wayland
        ANLAND=1
        ANLAND_SOCKET=/run/display.sock
        ANLAND_DRM_DEVICE=/dev/dri/renderD128
        ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "KDE mobile 显示后端无效：$backend" >&2
        return 1
    }
    case "$ID" in
        arch|archarm|archlinux)
            assignments+=(XWAYLAND_GBM_DEVICE=/dev/dri/renderD128)
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
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji wayland-utils xserver-xorg dbus-user-session \
                plasma-nano plasma-mobile plasma-mobile-phone maliit-keyboard maliit-framework \
                kwin-wayland pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil plasma-pa upower pulseaudio-utils \
                konsole dolphin kate kinfocenter mesa-utils vulkan-tools \
                systemsettings plasma-systemmonitor kde-config-screenlocker kio-extras xdg-user-dirs \
                dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kimageformat6-plugins plasma-settings angelfish \
                gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop libcanberra-pulse \
                polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 \
                breeze-icon-theme plasma-desktoptheme libqt6svg6 qt6-svg-plugins \
                qml6-module-org-kde-kirigami qml6-module-qtquick-controls qml6-module-qtquick-layouts qml6-module-qtquick-templates
            apt-get purge -y --auto-remove modemmanager || true
            ;;
        ubuntu:26.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji wayland-utils xserver-xorg dbus-user-session \
                plasma-nano plasma-mobile plasma-mobile-phone maliit-keyboard maliit-framework maliit-server-qt6 \
                kwin-wayland pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil plasma-pa upower pulseaudio-utils \
                konsole dolphin kate kinfocenter mesa-utils vulkan-tools \
                systemsettings plasma-systemmonitor kde-config-screenlocker kio-extras xdg-user-dirs \
                dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kimageformat6-plugins plasma-settings angelfish \
                gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop libcanberra-pulse \
                polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 qml6-module-org-kde-kirigami qml6-module-qtquick-controls \
                qml6-module-qtquick-layouts qml6-module-qtquick-templates language-pack-kde-zh-hans language-pack-zh-hans qt6-translations-l10n
            apt-get purge -y --auto-remove modemmanager || true
            ;;
        *)
            echo "KDE mobile 不支持当前系统：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "KDE mobile 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    echo '%_install_langs all' > /etc/rpm/macros.image-language-conf
    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 xrandr xset xrdb xhost google-noto-cjk-fonts google-noto-emoji-color-fonts xorg-x11-server-Xorg wayland-utils \
        plasma-nano plasma-mobile maliit-keyboard maliit-framework \
        kwin pipewire pipewire-alsa pipewire-pulseaudio wireplumber powerdevil plasma-pa upower pulseaudio-utils \
        konsole dolphin kate kinfocenter glx-utils vulkan-tools \
        systemsettings plasma-systemmonitor kscreenlocker kio-extras xdg-user-dirs \
        dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kf6-kimageformats plasma-settings angelfish \
        gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop libcanberra-gtk3 \
        polkit-kde-agent-1 plasma-workspace breeze-icon-theme plasma-breeze qt6-qtsvg \
        kf6-kirigami qt6-qtquickcontrols2 qt6-qtdeclarative glibc-langpack-zh
    dnf remove -y ModemManager || true
}

install_arch() {
    pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji plasma-desktop plasma-workspace \
        plasma-mobile plasma-settings plasma-camera plasma-keyboard plasma-nano \
        kwin qt6-wayland qt6-svg qt6-virtualkeyboard wayland-utils xorg-server \
        pipewire pipewire-alsa pipewire-pulse wireplumber powerdevil plasma-pa upower \
        kscreen ark konsole qmlkonsole dolphin kate kinfocenter mesa-utils libpulse vulkan-tools \
        aha clinfo dmidecode kfind plasma-systemmonitor filelight glmark2 vkmark \
        systemsettings kscreenlocker kio-extras xdg-user-dirs \
        dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kimageformats \
        plasma-browser-integration angelfish kclock libcanberra \
        gstreamer gst-plugins-base gst-plugins-good sound-theme-freedesktop polkit-kde-agent
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "KDE mobile 不支持当前发行版：$ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "KDE mobile profile 操作无效：$1" >&2; exit 1 ;;
esac
