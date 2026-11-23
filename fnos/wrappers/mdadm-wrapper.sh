#!/bin/sh
# 将飞牛硬编码的私有参数 --bitmap=lockless 替换为上游内核支持的 --bitmap=internal
REAL=/usr/sbin/mdadm.real
[ -x "$REAL" ] || REAL=/usr/trim/bin/mdadm.real
[ -x "$REAL" ] || { echo "mdadm wrapper: real mdadm not found" >&2; exit 127; }

[ $# -eq 0 ] && exec "$REAL"

n=$#
i=1
create=no
while [ "$i" -le "$n" ]; do
    eval "arg=\${$i}"
    case "$arg" in
        --create|-C) create=yes; set -- "$@" "$arg" ;;
        --bitmap=lockless) set -- "$@" --bitmap=internal ;;
        *) set -- "$@" "$arg" ;;
    esac
    i=$((i + 1))
done
shift "$n"

if [ "$create" != yes ] || [ ! -s /run/fnos-block-view/disk-map ] ||
    ! mountpoint -q /sys/block; then
    exec "$REAL" "$@"
fi

# 新阵列需要立刻出现在 mdadm 的 sysfs 中，飞牛的合成视图只在外层命名空间保留。
unshare --mount --propagation private /bin/sh -ec '
    umount /sys/block /sys/class/block /sys/dev/block
    exec "$@"
' sh "$REAL" "$@" || exit "$?"

# 飞牛在 mdadm 返回后立刻校验成员名，不能等后台刷新。
/usr/local/sbin/fnos-md-alias.sh
