#!/bin/bash
# 过滤飞牛私有挂载参数 trimacl，保留 prjquota 等标准参数
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

exec "$REAL" "${ARGS[@]}"
