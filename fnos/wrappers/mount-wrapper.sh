#!/bin/bash
# 准备飞牛存储卷的挂载目录，过滤私有参数 trimacl 并保留 prjquota
REAL=/usr/bin/mount.orig
[ -x "$REAL" ] || { echo "mount wrapper: $REAL not found" >&2; exit 127; }

filter_opts() {
    local options="$1"
    local -a items filtered=()
    IFS=',' read -ra items <<< "$options"
    local item
    for item in "${items[@]}"; do
        [[ -n "$item" && "$item" != "trimacl" ]] && filtered+=("$item")
    done
    (IFS=','; echo "${filtered[*]}")
}

ARGS=()
while (($#)); do
    if [[ "$1" == "-o" && $# -ge 2 ]]; then
        out="$(filter_opts "$2")"
        shift 2
        [[ -n "$out" ]] && ARGS+=("-o" "$out")
    elif [[ "$1" == -o* && "$1" != "-o" ]]; then
        out="$(filter_opts "${1#-o}")"
        shift
        [[ -n "$out" ]] && ARGS+=("-o" "$out")
    else
        ARGS+=("$1")
        shift
    fi
done

# fnOS 把块设备与 /volN 作为最后两个参数传入。挂载目录可能已被清理，
# 在交给真实 mount 前补齐，首次挂载和重新挂载都走这里。
if ((${#ARGS[@]} >= 2)); then
    source="${ARGS[-2]}"
    target="${ARGS[-1]}"
    if [[ "$target" =~ ^/vol[1-9][0-9]*$ && "$source" == /dev/* && -b "$source" &&
          ! -e "$target" && ! -L "$target" ]]; then
        mkdir -p -- "$target" || exit "$?"
    fi
fi

exec "$REAL" "${ARGS[@]}"
