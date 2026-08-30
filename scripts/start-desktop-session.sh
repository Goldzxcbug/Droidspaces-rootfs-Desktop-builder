#!/usr/bin/env bash
set -euo pipefail

config="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"
[[ -r "$config" ]] || { echo "缺少桌面配置文件：$config" >&2; exit 1; }
source "$config"

# Maintain persistent X11 authorization for Mutter Xwayland
(
    sleep 3
    for authfile in /run/user/1000/.mutter-Xwaylandauth.*; do
        if [[ -f "$authfile" ]]; then
            cp "$authfile" /home/mikasa/.Xauthority 2>/dev/null || true
            chown mikasa:mikasa /home/mikasa/.Xauthority 2>/dev/null || true
            break
        fi
    done
    export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XAUTHORITY=/home/mikasa/.Xauthority
    xhost +local: 2>/dev/null || xhost + 2>/dev/null || true
) &

case "${DESKTOP:-}:${DISPLAY_BACKEND:-}" in
    none:x11) command_line='exit 0' ;;
    kde:x11) command_line='export DISPLAY="${DISPLAY:-:5}"; exec startplasma-x11' ;;
    kde:anland-wayland) command_line='exec startplasma-wayland' ;;
    kde-mobile:anland-wayland) command_line='exec startplasmamobile' ;;
    gnome:anland-wayland) command_line='gnome-session --session=gnome & exec gnome-shell --wayland' ;;
    *)
        echo "不支持的桌面会话：${DESKTOP:-未设置}/${DISPLAY_BACKEND:-未设置}" >&2
        exit 1
        ;;
esac

if [[ "${DROIDSPACES_SESSION_DRY_RUN:-false}" == true ]]; then
    printf '%s\n' "$command_line"
    exit 0
fi

exec /bin/bash -lc "$command_line"
