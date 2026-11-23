#!/bin/bash
# fnos-md-alias.sh — 生成 md0..md15 合成视图并将 loopNpK 成员名对齐为 sdXK
set -u

VIEW_ROOT="/run/fnos-block-view"
BLK_DIR="$VIEW_ROOT/block"
CLS_DIR="$VIEW_ROOT/class-block"
DEV_DIR="$VIEW_ROOT/dev-block"
MAP_FILE="$VIEW_ROOT/disk-map"

[ -d "$BLK_DIR" ] || exit 0
[ -f "$MAP_FILE" ] || exit 0

# 后台刷新与 mdadm 同步更新时共用一把锁，避免交叉清理成员目录。
exec 9>"$VIEW_ROOT/md-alias.lock"
flock -x 9 || exit 1

# 读取映射表：loopN -> sdX
declare -A LOOP_TO_SD=()
while read -r loop_name sd_name _rest; do
    [ -n "${loop_name:-}" ] && [ -n "${sd_name:-}" ] || continue
    LOOP_TO_SD["$loop_name"]="$sd_name"
done < "$MAP_FILE"

map_member_name() {
    local raw="$1"
    local loop_base part_num sd_name
    if [[ "$raw" =~ ^(loop[0-9]+)p([0-9]+)$ ]]; then
        loop_base="${BASH_REMATCH[1]}"
        part_num="${BASH_REMATCH[2]}"
        sd_name="${LOOP_TO_SD[$loop_base]:-}"
        if [ -n "$sd_name" ]; then
            printf '%s%s\n' "$sd_name" "$part_num"
            return 0
        fi
    elif [[ "$raw" =~ ^(loop[0-9]+)$ ]]; then
        loop_base="${BASH_REMATCH[1]}"
        sd_name="${LOOP_TO_SD[$loop_base]:-}"
        if [ -n "$sd_name" ]; then
            printf '%s\n' "$sd_name"
            return 0
        fi
    fi
    return 1
}

declare -A md_members=() slaves=()
for idx in $(seq 0 15); do
    md_name="md${idx}"
    src="/sys/devices/virtual/block/${md_name}"
    dst="$BLK_DIR/${md_name}"

    if [ ! -d "$src" ]; then
        rm -rf "$dst" "$CLS_DIR/${md_name}"
        continue
    fi

    mkdir -p "$dst"
    for entry in "$src"/*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        base="$(basename "$entry")"
        case "$base" in
            md|slaves) continue ;;
            *) ln -sfn "$entry" "$dst/$base" ;;
        esac
    done

    # md/ 目录：将 dev-loopNpK 映射为 dev-sdXK
    if [ -d "$src/md" ]; then
        mkdir -p "$dst/md"
        md_members=()
        for mentry in "$src/md"/*; do
            [ -e "$mentry" ] || [ -L "$mentry" ] || continue
            mbase="$(basename "$mentry")"
            if [[ "$mbase" == dev-* ]]; then
                raw_dev="${mbase#dev-}"
                if mapped="$(map_member_name "$raw_dev")"; then
                    mbase="dev-${mapped}"
                    if [ -L "$dst/md/$mbase" ]; then
                        rm -f "$dst/md/$mbase"
                    fi
                    mkdir -p "$dst/md/$mbase"
                    for sub in "$mentry"/*; do
                        [ -e "$sub" ] || [ -L "$sub" ] || continue
                        ln -sfn "$sub" "$dst/md/$mbase/$(basename "$sub")"
                    done
                else
                    if [ -d "$dst/md/$mbase" ] && [ ! -L "$dst/md/$mbase" ]; then
                        rm -rf "$dst/md/$mbase"
                    fi
                    ln -sfn "$mentry" "$dst/md/$mbase"
                fi
                md_members["$mbase"]=1
            else
                ln -sfn "$mentry" "$dst/md/$mbase"
            fi
        done
        # 保留现有成员目录，避免 fnOS 校验时看见短暂的空视图。
        for old in "$dst/md"/dev-*; do
            [ -e "$old" ] || [ -L "$old" ] || continue
            [ -n "${md_members[${old##*/}]:-}" ] || rm -rf "$old"
        done
    fi

    # slaves/ 目录：将 loopNpK 映射为 sdXK（fnOS 靠它判断盘归属）
    if [ -d "$src/slaves" ]; then
        mkdir -p "$dst/slaves"
        slaves=()
        for sentry in "$src/slaves"/*; do
            [ -e "$sentry" ] || [ -L "$sentry" ] || continue
            sbase="$(basename "$sentry")"
            if mapped="$(map_member_name "$sbase")"; then
                if [[ "$mapped" =~ ^(sd[a-z]+)([0-9]+)$ ]] && [ -d "$BLK_DIR/${BASH_REMATCH[1]}/${mapped}" ]; then
                    ln -sfn "$BLK_DIR/${BASH_REMATCH[1]}/${mapped}" "$dst/slaves/${mapped}"
                elif [ -d "$BLK_DIR/${mapped}" ]; then
                    ln -sfn "$BLK_DIR/${mapped}" "$dst/slaves/${mapped}"
                else
                    ln -sfn "$sentry" "$dst/slaves/${mapped}"
                fi
            else
                mapped="$sbase"
                ln -sfn "$sentry" "$dst/slaves/$sbase"
            fi
            slaves["$mapped"]=1
        done
        for old in "$dst/slaves"/*; do
            [ -L "$old" ] || continue
            [ -n "${slaves[${old##*/}]:-}" ] || rm -f "$old"
        done
    fi

    ln -sfn "$dst" "$CLS_DIR/${md_name}"

    if [ -r "$src/dev" ]; then
        devnum="$(cat "$src/dev" 2>/dev/null || true)"
        if [ -n "$devnum" ]; then
            ln -sfn "$dst" "$DEV_DIR/$devnum"
            major="${devnum%%:*}"
            minor="${devnum##*:}"
            if [ ! -b "/dev/${md_name}" ]; then
                mknod -m 660 "/dev/${md_name}" b "$major" "$minor" 2>/dev/null || true
            fi
        fi
    fi
done

exit 0
