#!/usr/bin/env bash
set -euo pipefail

desktop="${1:-}"
profile_dir="${DROIDSPACES_DESKTOP_PROFILE_DIR:-/usr/local/lib/droidspaces/desktops}"

case "${ENABLE_systemd257_ARG:-false}" in
    true)
        case "$desktop" in
            none|kde) ;;
            *)
                echo "systemd 257 构建只支持 none 和普通 KDE，拒绝安装：$desktop" >&2
                exit 1
                ;;
        esac
        ;;
    false) ;;
    *)
        echo "ENABLE_systemd257_ARG 只支持 true 或 false。" >&2
        exit 1
        ;;
esac

case "$desktop" in
    none)
        echo "--> 桌面配置：none"
        exit 0
        ;;
esac

if [[ ! "$desktop" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "不支持的桌面配置：$desktop" >&2
    exit 1
fi

profile_desktop="$desktop"
case "$desktop" in
    hyprland|mango|denial) profile_desktop="niri" ;;
esac
profile="$profile_dir/$profile_desktop.sh"
if [[ ! -x "$profile" ]]; then
    echo "桌面配置脚本不存在或不可执行：$profile" >&2
    exit 1
fi

echo "--> 正在安装桌面配置：$desktop"
DROIDSPACES_DESKTOP="$desktop" exec "$profile" install
