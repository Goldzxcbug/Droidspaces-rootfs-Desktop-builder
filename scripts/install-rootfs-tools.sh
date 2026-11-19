#!/usr/bin/env bash
# Install the build's selected runtime files from a read-only scripts mount.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEST_ROOT=/
TUI_DIR=''
DESKTOP_NAME="${DESKTOP:-none}"
BACKEND="${DISPLAY_BACKEND:-x11}"

die() { printf 'install-rootfs-tools: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-rootfs-tools.sh --tui-dir DIRECTORY [--root DIRECTORY] [--desktop NAME] [--display-backend NAME]

Install Droidspaces commands, desktop profiles and selected audio configuration.
--tui-dir supplies scripts downloaded and verified by sync-tui.sh.
The target's /etc/os-release selects the distribution-specific files.
DESKTOP and DISPLAY_BACKEND provide the defaults during Docker builds.
EOF
}

install_file() {
    local source="$1" target="$2" mode="${3:-0755}"
    install -D -m "$mode" -- "$SCRIPT_DIR/$source" "$DEST_ROOT$target"
}

install_tui_file() {
    install -D -m "${3:-0755}" -- "$TUI_DIR/$1" "$DEST_ROOT$2"
}

main() {
    local ID='' VERSION_ID='' name source
    local full_anland=true
    local -a libraries=()
    while (($#)); do
        case "$1" in
            --root|--tui-dir|--desktop|--display-backend)
                (($# >= 2)) || die "$1 requires a value"
                case "$1" in
                    --root) DEST_ROOT="$2" ;;
                    --tui-dir) TUI_DIR="$2" ;;
                    --desktop) DESKTOP_NAME="$2" ;;
                    --display-backend) BACKEND="$2" ;;
                esac
                shift 2
                ;;
            -h|--help) usage; return ;;
            *) die "unsupported argument: $1" ;;
        esac
    done
    [[ -d "$DEST_ROOT" ]] || die "target directory does not exist: $DEST_ROOT"
    DEST_ROOT="$(cd -- "$DEST_ROOT" && pwd -P)"
    DEST_ROOT="${DEST_ROOT%/}"
    [[ -n "$TUI_DIR" && -d "$TUI_DIR" ]] || die '--tui-dir must name a verified download directory'
    TUI_DIR="$(cd -- "$TUI_DIR" && pwd -P)"
    for name in droidspaces-tui.sh droidspaces-gpu.sh droidspaces-video.sh \
        install-anland-{kde,gnome,next,niri,hyprland,mango,denial}.sh \
        install-{mesa,hangover-wine,winefonts}.sh Gold-bug-tui-manifest Gold-bug-tui-files \
        lib/anland-common.sh lib/anland-archive-common.sh lib/anland-compositor-common.sh; do
        [[ -f "$TUI_DIR/$name" && ! -L "$TUI_DIR/$name" ]] || die "missing regular TUI file: $name"
    done
    [[ -d "$TUI_DIR/lib" && ! -L "$TUI_DIR/lib" ]] || die 'TUI lib/ must be a regular directory'
    shopt -s nullglob
    libraries=("$TUI_DIR"/lib/*.sh)
    shopt -u nullglob
    for source in "${libraries[@]}"; do
        name="${source##*/}"
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.sh$ && "$name" != *..* &&
           -f "$source" && ! -L "$source" ]] || die "invalid TUI library: $name"
    done
    [[ -r "$DEST_ROOT/etc/os-release" ]] || die 'target /etc/os-release is missing'
    # The base image owns this file. No package-manager or network call is made.
    # shellcheck disable=SC1091
    source "$DEST_ROOT/etc/os-release"
    case "$ID" in
        ubuntu)
            case "$VERSION_ID" in 24.04|25.10) full_anland=false ;; esac
            install_file nosnap.sh /usr/local/sbin/nosnap
            ;;
        debian|fedora|arch|archarm|archlinux) ;;
        *) die "unsupported target distribution: $ID" ;;
    esac
    case "$ID" in
        debian|ubuntu)
            install_file download-firmware /usr/local/bin/download-firmware
            install_file bashrc.sh /etc/profile.d/ds-aliases.sh
            ;;
    esac

    for source in "${libraries[@]}"; do
        install_tui_file "lib/${source##*/}" "/usr/local/lib/droidspaces/tui/${source##*/}" 0644
    done
    install_file install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
    install_file systemd257.sh /usr/local/sbin/systemd257
    for name in kde gnome next; do
        install_tui_file "install-anland-$name.sh" "/usr/local/sbin/install-anland-$name"
    done
    if [[ "$full_anland" == true ]]; then
        for name in niri hyprland mango denial; do
            install_tui_file "install-anland-$name.sh" "/usr/local/sbin/install-anland-$name"
        done
        install_file install-anland-desktop.sh /usr/local/sbin/install-anland-desktop
    fi
    for name in mesa hangover-wine winefonts; do
        install_tui_file "install-$name.sh" "/usr/local/sbin/install-$name"
    done
    install_tui_file droidspaces-tui.sh /usr/local/bin/droidspaces-tui
    install_tui_file droidspaces-gpu.sh /usr/local/bin/droidspaces-gpu
    install_tui_file droidspaces-video.sh /usr/local/bin/droidspaces-video.sh
    install_tui_file Gold-bug-tui-manifest /usr/local/share/droidspaces-tui/Gold-bug-tui-manifest 0644
    install_tui_file Gold-bug-tui-files /usr/local/share/droidspaces-tui/Gold-bug-tui-files 0644
    for name in install-desktop install-fcitx5 configure-desktop configure-chrome; do
        install_file "$name.sh" "/usr/local/sbin/$name"
    done
    install_file start-desktop-session.sh /usr/local/bin/start-desktop-session
    for source in "$SCRIPT_DIR"/desktops/*.sh; do
        install_file "desktops/${source##*/}" "/usr/local/lib/droidspaces/desktops/${source##*/}"
    done
    ln -sfn -- droidspaces-tui "$DEST_ROOT/usr/local/bin/dstui"
    ln -sfn -- droidspaces-tui "$DEST_ROOT/usr/local/bin/ds-tui"

    if [[ "$DESKTOP_NAME" == kde || "$DESKTOP_NAME" == kde-mobile ]]; then
        install_file etc/pipewire/client.conf.d/90-droidspaces-portal-rt-workaround.conf \
            /etc/pipewire/client.conf.d/90-droidspaces-portal-rt-workaround.conf 0644
    fi
    if [[ "$BACKEND" == anland-wayland ]]; then
        install_file etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf \
            /etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf 0644
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
