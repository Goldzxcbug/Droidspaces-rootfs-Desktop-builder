#!/usr/bin/env bash

write_rootfs_config() {
    local output="${1:?}" desktop="${2:?}" backend="${3:?}"
    local audio="${4:?}" docker_enabled="${5:?}" gpu_enabled="${6:?}"
    local zh_tz_enabled="${7:-false}"
    local anland=0 x11=0 pulse=0 userns=0 gpu=0

    case "$desktop" in none|kde|kde-mobile|gnome|anland-next|niri|hyprland|mango|denial) ;; *) return 1 ;; esac
    case "$backend" in
        anland-wayland) anland=1 ;;
        x11) x11=1 ;;
        *) return 1 ;;
    esac
    case "$audio" in socket|tcp|none) ;; *) return 1 ;; esac
    case "$docker_enabled:$gpu_enabled" in true:true|true:false|false:true|false:false) ;; *) return 1 ;; esac
    case "$zh_tz_enabled" in true|false) ;; *) return 1 ;; esac
    [[ "$backend" == x11 && "$audio" == socket ]] && pulse=1
    [[ "$desktop" == kde || "$desktop" == kde-mobile ]] && userns=1
    [[ "$gpu_enabled" == true ]] && gpu=1

    {
        printf '%s\n' '# Droidspaces 推荐配置'
        printf 'enable_anland=%s\nenable_termux_x11=%s\nenable_pulseaudio=%s\n' "$anland" "$x11" "$pulse"
        printf 'allow_userns=%s\nenable_gpu_mode=%s\n' "$userns" "$gpu"
        if [[ "$zh_tz_enabled" == true ]]; then
            printf '%s\n' 'dns_servers=114.114.114.114'
        fi
        if [[ "$docker_enabled" == true ]]; then
            printf '%s\n' 'net_mode=nat'
        fi
        if [[ "$desktop" == anland-next ]]; then
            printf '%s\n' 'bind_mounts=/data/local/tmp/awl:/run/anland'
        fi
    } > "$output"
}

package_rootfs_with_config() (
    set -euo pipefail
    local archive="${1:?}" output="${2:?}"
    shift 2
    local config_dir pending_output config_size config_blocks member
    local -a old_config=()
    config_dir=$(mktemp -d)
    pending_output=""
    trap 'rm -rf "$config_dir"; if [[ -n "$pending_output" ]]; then rm -f "$pending_output"; fi' EXIT
    write_rootfs_config "$config_dir/container.config" "$@"

    # 重建后的基础镜像可能已包含推荐配置；仅保留本次构建的设置。
    tar -tf "$archive" > "$config_dir/members"
    for member in container.config ./container.config container.config/ ./container.config/; do
        if grep -Fxq -- "$member" "$config_dir/members"; then
            old_config+=("$member")
        fi
    done
    if ((${#old_config[@]})); then
        tar --delete -f "$archive" -- "${old_config[@]}"
    fi

    # USTAR 可将配置放在第一个物理文件头中，避免前置 PAX 文件头。
    tar --format=ustar --owner=0 --group=0 --numeric-owner \
        -cf "$config_dir/config.tar" -C "$config_dir" container.config
    config_size=$(stat -c %s "$config_dir/container.config")
    config_blocks=$((1 + (config_size + 511) / 512))
    pending_output=$(mktemp "${output}.tmp.XXXXXX")
    # 略去小型 tar 归档的结束块，并将两部分直接流式传入 XZ。这样可避免再生成一份
    # 未压缩的 rootfs 副本，同时固定归档成员顺序。
    {
        dd if="$config_dir/config.tar" bs=512 count="$config_blocks" status=none &&
        cat "$archive"
    } | xz -T0 -9 -c > "$pending_output"
    mv -f "$pending_output" "$output"
    pending_output=""
    rm -f "$archive"
)
