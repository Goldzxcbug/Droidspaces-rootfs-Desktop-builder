#!/usr/bin/env bash
# Install Droidspaces runtime tools into the fnOS rootfs from a read-only scripts mount.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEST_ROOT=/
TUI_DIR=''

die() { printf 'install-rootfs-tools: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-rootfs-tools.sh --tui-dir DIRECTORY [--root DIRECTORY] [--desktop NAME] [--display-backend NAME]

Install Droidspaces runtime commands and Mesa/video helper tools for fnOS.
--tui-dir supplies scripts downloaded and verified by sync-tui.sh.
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
    local name source
    local -a libraries=()
    while (($#)); do
        case "$1" in
            --root|--tui-dir|--desktop|--display-backend)
                (($# >= 2)) || die "$1 requires a value"
                case "$1" in
                    --root) DEST_ROOT="$2" ;;
                    --tui-dir) TUI_DIR="$2" ;;
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
        install-mesa.sh Gold-bug-tui-manifest Gold-bug-tui-files; do
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

    install_file download-firmware /usr/local/bin/download-firmware
    install_file bashrc.sh /etc/profile.d/ds-aliases.sh

    for source in "${libraries[@]}"; do
        install_tui_file "lib/${source##*/}" "/usr/local/lib/droidspaces/tui/${source##*/}" 0644
    done
    install_tui_file install-mesa.sh /usr/local/sbin/install-mesa
    install_tui_file droidspaces-tui.sh /usr/local/bin/droidspaces-tui
    install_tui_file droidspaces-gpu.sh /usr/local/bin/droidspaces-gpu
    install_tui_file droidspaces-video.sh /usr/local/bin/droidspaces-video.sh
    install_tui_file Gold-bug-tui-manifest /usr/local/share/droidspaces-tui/Gold-bug-tui-manifest 0644
    install_tui_file Gold-bug-tui-files /usr/local/share/droidspaces-tui/Gold-bug-tui-files 0644

    ln -sfn -- droidspaces-tui "$DEST_ROOT/usr/local/bin/dstui"
    ln -sfn -- droidspaces-tui "$DEST_ROOT/usr/local/bin/ds-tui"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
