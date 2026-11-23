#!/bin/bash
# fnos-block-view.sh — 自动发现 /mnt/fn-*.img（兼容 /mnt/sd.img），
#                      构造合成 /sys/block sda..sdz 视图并恢复 md/LVM。
#
# 用法：
#   fnos-block-view.sh              完整初始化（幂等，开机调用）
#   fnos-block-view.sh --refresh    仅增量刷新分区、md 别名与 dm 设备
set -u

VIEW_ROOT="/run/fnos-block-view"
BLK_DIR="$VIEW_ROOT/block"
CLS_DIR="$VIEW_ROOT/class-block"
DEV_DIR="$VIEW_ROOT/dev-block"
FAKE_ROOT="$VIEW_ROOT/fake-device"
MAP_FILE="$VIEW_ROOT/disk-map"
LOOP_START="${FNOS_LOOP_START:-50}"
LOOP_END="${FNOS_LOOP_END:-99}"

log() { echo "[fnos-block-view] $*"; }

# 同步单个 loopN 的分区 loopNp1..loopNp7 为真实目录 sdX1..sdX7 及 /dev/sdXK
sync_disk_partitions() {
    local loop_name="$1"
    local sd_name="$2"
    local src_disk="/sys/devices/virtual/block/${loop_name}"
    local dst_disk="$BLK_DIR/${sd_name}"

    [ -d "$src_disk" ] && [ -d "$dst_disk" ] || return 0

    # 确保整盘 /dev/sdX 节点存在
    if [ -r "$src_disk/dev" ]; then
        local dnum maj min
        dnum="$(cat "$src_disk/dev" 2>/dev/null || true)"
        if [ -n "$dnum" ]; then
            maj="${dnum%%:*}"
            min="${dnum##*:}"
            if [ ! -b "/dev/${sd_name}" ]; then
                mknod -m 660 "/dev/${sd_name}" b "$maj" "$min" 2>/dev/null || true
            fi
            ln -sfn "$dst_disk" "$DEV_DIR/$dnum"
        fi
    fi

    local p src_part part_name dst_part pnum pmaj pmin
    for p in $(seq 1 15); do
        src_part="${src_disk}/${loop_name}p${p}"
        part_name="${sd_name}${p}"
        dst_part="${dst_disk}/${part_name}"
        if [ ! -d "$src_part" ]; then
            rm -rf "$dst_part" "$CLS_DIR/${part_name}"
            continue
        fi

        # 关键：分区必须是真实目录，不能是符号链接，否则 fnOS 无法识别分区归属
        mkdir -p "$dst_part"
        for entry in "$src_part"/*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            local base
            base="$(basename "$entry")"
            [ "$base" = "uevent" ] && continue
            ln -sfn "$entry" "$dst_part/$base"
        done

        if [ -r "$src_part/dev" ]; then
            pnum="$(cat "$src_part/dev" 2>/dev/null || true)"
            if [ -n "$pnum" ]; then
                pmaj="${pnum%%:*}"
                pmin="${pnum##*:}"
                printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=partition\nPARTN=%s\n' \
                    "$pmaj" "$pmin" "$part_name" "$p" > "$dst_part/uevent"
                ln -sfn "$dst_part" "$DEV_DIR/$pnum"
                if [ ! -b "/dev/${part_name}" ]; then
                    mknod -m 660 "/dev/${part_name}" b "$pmaj" "$pmin" 2>/dev/null || true
                fi
                if [ ! -b "/dev/${loop_name}p${p}" ]; then
                    mknod -m 660 "/dev/${loop_name}p${p}" b "$pmaj" "$pmin" 2>/dev/null || true
                fi
            fi
        fi

        ln -sfn "$dst_part" "$CLS_DIR/${part_name}"
    done
}

refresh_all() {
    [ -f "$MAP_FILE" ] || return 0
    while read -r loop_name sd_name _img; do
        [ -n "${loop_name:-}" ] && [ -n "${sd_name:-}" ] || continue
        sync_disk_partitions "$loop_name" "$sd_name"
    done < "$MAP_FILE"
    /usr/local/sbin/fnos-md-alias.sh 2>/dev/null || true
    /usr/local/sbin/fnos-dm-sync.sh 2>/dev/null || true
}

if [ "${1:-}" = "--refresh" ]; then
    refresh_all
    exit 0
fi

# 1. 扫描镜像文件：优先 /mnt/fn-*.img（按字母序），兼容 /mnt/sd.img
IMAGES=()
while IFS= read -r img; do
    [ -f "$img" ] && IMAGES+=("$img")
done < <(LC_ALL=C find /mnt -maxdepth 1 -type f -name 'fn-*.img' 2>/dev/null | LC_ALL=C sort)

if [ -f /mnt/sd.img ]; then
    IMAGES+=("/mnt/sd.img")
fi

if [ "${#IMAGES[@]}" -eq 0 ]; then
    log "未在 /mnt/ 下发现 fn-*.img 或 sd.img，跳过虚拟盘视图初始化"
    exit 0
fi

# 2. 确保 /sys 可写（用于 bind mount 覆盖 /sys/block 等）
mount -o remount,rw /sys 2>/dev/null || mount -o remount,rw,bind /sys /sys 2>/dev/null || true

# 3. 幂等清理旧 bind mount（避免重复启动叠加挂载）
for mp in /sys/block /sys/class/block /sys/dev/block; do
    while mountpoint -q "$mp" 2>/dev/null; do
        umount -l "$mp" 2>/dev/null || break
    done
done

rm -rf "$VIEW_ROOT"
mkdir -p "$BLK_DIR" "$CLS_DIR" "$DEV_DIR" "$FAKE_ROOT"
: > "$MAP_FILE"

# 辅助：寻找或复用镜像对应的 loop 设备
attach_loop() {
    local img="$1"
    local existing
    existing="$(losetup -j "$img" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    if [ -n "$existing" ] && [ -b "$existing" ]; then
        partx -u "$existing" 2>/dev/null || true
        printf '%s\n' "$(basename "$existing")"
        return 0
    fi

    local idx dev minor
    for idx in $(seq "$LOOP_START" "$LOOP_END"); do
        dev="/dev/loop${idx}"
        minor=$((idx * 8))
        if [ ! -b "$dev" ]; then
            mknod -m 660 "$dev" b 7 "$minor" 2>/dev/null || true
        fi
        if losetup "$dev" >/dev/null 2>&1; then
            continue
        fi
        if losetup --partscan "$dev" "$img" 2>/dev/null; then
            partx -u "$dev" 2>/dev/null || true
            printf 'loop%s\n' "$idx"
            return 0
        fi
    done
    return 1
}

# 辅助：按文件名生成稳定的 fake SCSI device 属性
create_fake_device() {
    local sd_name="$1"
    local img_path="$2"
    local fdir="$FAKE_ROOT/$sd_name"
    local hash short_id
    hash="$(printf '%s' "$(basename "$img_path")" | sha256sum | awk '{print $1}')"
    short_id="$(printf '%s' "${hash:0:12}" | tr '[:lower:]' '[:upper:]')"

    mkdir -p "$fdir"
    printf 'Droidspaces Virtual Disk\n' > "$fdir/model"
    printf 'FNDS%s\n' "$short_id" > "$fdir/serial"
    printf 'FNOS    \n' > "$fdir/vendor"
    printf 'naa.5000c500%s\n' "${hash:0:8}" > "$fdir/wwid"
    printf '1.0 \n' > "$fdir/rev"
    printf 'running\n' > "$fdir/state"
    printf '0\n' > "$fdir/type"
    printf 'none\n' > "$fdir/raid_level"
}

# 4. 为每个镜像分配 sdX 并构建真实目录视图
LETTERS=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
disk_idx=0
for img in "${IMAGES[@]}"; do
    if [ "$disk_idx" -ge "${#LETTERS[@]}" ]; then
        log "警告：镜像数量超过 26 块，忽略 $img"
        break
    fi

    loop_name="$(attach_loop "$img" || true)"
    if [ -z "$loop_name" ]; then
        log "警告：无法为 $img 分配 loop 设备，跳过"
        continue
    fi

    sd_name="sd${LETTERS[$disk_idx]}"
    disk_idx=$((disk_idx + 1))
    printf '%s %s %s\n' "$loop_name" "$sd_name" "$img" >> "$MAP_FILE"
    log "映射 $img -> /dev/$loop_name -> /sys/block/$sd_name"

    src_disk="/sys/devices/virtual/block/${loop_name}"
    dst_disk="$BLK_DIR/${sd_name}"
    mkdir -p "$dst_disk"
    create_fake_device "$sd_name" "$img"

    for entry in "$src_disk"/*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        base="$(basename "$entry")"
        case "$base" in
            device|uevent|"${loop_name}"p*) continue ;;
            *) ln -sfn "$entry" "$dst_disk/$base" ;;
        esac
    done

    ln -sfn "$FAKE_ROOT/$sd_name" "$dst_disk/device"

    if [ -r "$src_disk/dev" ]; then
        dnum="$(cat "$src_disk/dev" 2>/dev/null || true)"
        if [ -n "$dnum" ]; then
            dmaj="${dnum%%:*}"
            dmin="${dnum##*:}"
            printf 'MAJOR=%s\nMINOR=%s\nDEVNAME=%s\nDEVTYPE=disk\n' \
                "$dmaj" "$dmin" "$sd_name" > "$dst_disk/uevent"
        fi
    fi

    ln -sfn "$dst_disk" "$CLS_DIR/${sd_name}"
    sync_disk_partitions "$loop_name" "$sd_name"
done

# 5. 将合成视图 bind mount 到 /sys/{block,class/block,dev/block}
mount --bind "$BLK_DIR" /sys/block
mount --bind "$CLS_DIR" /sys/class/block
mount --bind "$DEV_DIR" /sys/dev/block

# 6. 组装已有 MD 阵列、激活 LVM 并同步视图
mkdir -p /vol1
/usr/local/sbin/fnos-md-alias.sh 2>/dev/null || true
mdadm --assemble --scan 2>/dev/null || true
/usr/local/sbin/fnos-md-alias.sh 2>/dev/null || true
vgchange -ay 2>/dev/null || true
/usr/local/sbin/fnos-dm-sync.sh 2>/dev/null || true

log "完成：已映射 ${disk_idx} 块虚拟盘"
exit 0
