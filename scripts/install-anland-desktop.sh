#!/usr/bin/env bash
set -euo pipefail

[[ $# -ge 1 ]] || { echo "必须指定桌面 slug。" >&2; exit 1; }
desktop="$1"
shift

case "$desktop" in
    kde|kde-mobile) installer="/usr/local/sbin/install-anland-kde" ;;
    gnome) installer="/usr/local/sbin/install-anland-gnome" ;;
    anland-next) installer="/usr/local/sbin/install-anland-next" ;;
    niri) installer="/usr/local/sbin/install-anland-niri" ;;
    hyprland) installer="/usr/local/sbin/install-anland-hyprland" ;;
    mango) installer="/usr/local/sbin/install-anland-mango" ;;
    denial) installer="/usr/local/sbin/install-anland-denial" ;;
    *)
        echo "桌面 $desktop 没有 Anland 软件包安装器。" >&2
        exit 1
        ;;
esac

[[ -x "$installer" ]] || { echo "Anland 安装器不存在或不可执行：$installer" >&2; exit 1; }
exec "$installer" "$@"
