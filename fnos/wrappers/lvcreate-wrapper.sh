#!/bin/sh
# 容器内无 udev：lvcreate 返回前同步 dm-* 进合成 /sys/block 视图并补齐 /dev/dm-N
/usr/sbin/lvm lvcreate "$@"
rc=$?
if [ -x /usr/local/sbin/fnos-dm-sync.sh ]; then
    /usr/local/sbin/fnos-dm-sync.sh >/dev/null 2>&1 || true
fi
exit "$rc"
