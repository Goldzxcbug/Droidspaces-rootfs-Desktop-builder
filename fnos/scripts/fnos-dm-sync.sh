#!/bin/bash
# fnos-dm-sync.sh — 同步所有 dm-* 设备进合成 /sys/block 视图并补齐 /dev/dm-N 节点
set -u

VIEW_ROOT="/run/fnos-block-view"
BLK_DIR="$VIEW_ROOT/block"
CLS_DIR="$VIEW_ROOT/class-block"
DEV_DIR="$VIEW_ROOT/dev-block"

[ -d "$BLK_DIR" ] || exit 0

for src in /sys/devices/virtual/block/dm-*; do
    [ -d "$src" ] || continue
    name="$(basename "$src")"
    dst="$BLK_DIR/$name"

    mkdir -p "$dst"
    for entry in "$src"/*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        base="$(basename "$entry")"
        ln -sfn "$entry" "$dst/$base"
    done

    ln -sfn "$dst" "$CLS_DIR/$name"

    if [ -r "$src/dev" ]; then
        devnum="$(cat "$src/dev" 2>/dev/null || true)"
        if [ -n "$devnum" ]; then
            ln -sfn "$dst" "$DEV_DIR/$devnum"
            major="${devnum%%:*}"
            minor="${devnum##*:}"
            if [ ! -b "/dev/$name" ]; then
                mknod -m 660 "/dev/$name" b "$major" "$minor" 2>/dev/null || true
            fi
        fi
    fi
done

exit 0
