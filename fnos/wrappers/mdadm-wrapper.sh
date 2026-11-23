#!/bin/sh
# 将飞牛硬编码的私有参数 --bitmap=lockless 替换为上游内核支持的 --bitmap=internal
REAL=/usr/sbin/mdadm.real
[ -x "$REAL" ] || REAL=/usr/trim/bin/mdadm.real
[ -x "$REAL" ] || { echo "mdadm wrapper: real mdadm not found" >&2; exit 127; }

[ $# -eq 0 ] && exec "$REAL"

n=$#
i=1
while [ "$i" -le "$n" ]; do
    eval "arg=\${$i}"
    case "$arg" in
        --bitmap=lockless) set -- "$@" --bitmap=internal ;;
        *) set -- "$@" "$arg" ;;
    esac
    i=$((i + 1))
done
shift "$n"
exec "$REAL" "$@"
