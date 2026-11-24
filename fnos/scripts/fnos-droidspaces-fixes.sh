#!/bin/bash
# fnos-droidspaces-fixes.sh — 开机自愈 Droidspaces 容器中的 fnOS 兼容层
set -u

WRAP_DIR="/usr/local/share/fnos-droidspaces/wrappers"
HOOK="/opt/fnnas/fnacl_faccessat_hook.so"

# 1. 为依赖 libnperm 伪 dirfd 的飞牛服务写入 LD_PRELOAD drop-in
if [ -f "$HOOK" ]; then
    for pair in \
        "trim_main:trim" \
        "trim_upload:uploadsrv" \
        "trim_open_gateway:trim_open_gateway" \
        "trim_app_center:trim_app_center" \
        "filestor_service:filestor_service" \
        "finder_service:finder_service" \
        "sysinfo_service:sysinfo_service" \
        "share_service:share_service" \
        "backup_service:backup_service" \
        "dlcenter:dlcenter" \
        "imagesrv:imagesrv" \
        "multiple-downloads:multiple-downloads" \
        "trim_sharelink:trim-sharelink" \
        "webdav:webdav"; do
        unit="${pair%%:*}"
        bin="${pair##*:}"
        [ -x "/usr/trim/bin/$bin" ] || continue
        d="/etc/systemd/system/${unit}.service.d"
        mkdir -p "$d"
        printf '[Service]\nEnvironment="LD_PRELOAD=%s"\n' "$HOOK" > "$d/droidspaces-fnacl.conf"
    done
fi

# 2. 动态配置 mediasrv：有 Droidspaces VA-API 硬解驱动 + renderD128 时放行 /dev/dri，
#    否则自动挂载 nodri/nodmaheap/fakecompat 走 CPU 软解兜底
mkdir -p /etc/systemd/system/mediasrv.service.d
if [ -c /dev/dri/renderD128 ] && {
    [ -f /usr/lib/aarch64-linux-gnu/dri/msm_drm_drv_video.so ] ||
    [ -f /usr/lib/dri/msm_drm_drv_video.so ];
}; then
    cat > /etc/systemd/system/mediasrv.service.d/droidspaces-media.conf <<'MEDIA_HW'
[Service]
Environment=MESA_LOADER_DRIVER_OVERRIDE=kgsl
Environment=TU_DEBUG=noconform
MEDIA_HW
else
    cat > /etc/systemd/system/mediasrv.service.d/droidspaces-media.conf <<'MEDIA_SW'
[Service]
Environment=LD_PRELOAD=/opt/fnnas/hook/nodri.so:/opt/fnnas/hook/nodmaheap.so:/opt/fnnas/hook/fakecompat.so
MEDIA_SW
fi

# 3. 自愈 /usr/trim/etc/trim.key.enc
if [ -x /usr/local/sbin/fnos-trim-keygen.py ]; then
    python3 /usr/local/sbin/fnos-trim-keygen.py 2>/dev/null || true
fi

# 4. mdadm wrapper：同时覆盖 /usr/sbin/mdadm 和 /usr/trim/bin/mdadm
if [ -f "$WRAP_DIR/mdadm-wrapper.sh" ]; then
    if [ -x /usr/sbin/mdadm ] && ! head -1 /usr/sbin/mdadm 2>/dev/null | grep -q '^#!'; then
        cp -f /usr/sbin/mdadm /usr/sbin/mdadm.real
        install -m 0755 "$WRAP_DIR/mdadm-wrapper.sh" /usr/sbin/mdadm
    fi
    if [ -e /usr/trim/bin/mdadm ] && [ ! -L /usr/trim/bin/mdadm ]; then
        if ! head -1 /usr/trim/bin/mdadm 2>/dev/null | grep -q '^#!'; then
            cp -f /usr/trim/bin/mdadm /usr/trim/bin/mdadm.real
            install -m 0755 "$WRAP_DIR/mdadm-wrapper.sh" /usr/trim/bin/mdadm
        fi
    elif [ -d /usr/trim/bin ] && [ -x /usr/sbin/mdadm ]; then
        ln -sfn /usr/sbin/mdadm /usr/trim/bin/mdadm
    fi
fi

# 5. mount wrapper：过滤 trimacl
if [ -f "$WRAP_DIR/mount-wrapper.sh" ]; then
    if [ -x /usr/bin/mount ] && [ ! -e /usr/bin/mount.orig ] && ! head -1 /usr/bin/mount 2>/dev/null | grep -q '^#!'; then
        mv /usr/bin/mount /usr/bin/mount.orig
    fi
    if [ -x /usr/bin/mount.orig ]; then
        install -m 0755 "$WRAP_DIR/mount-wrapper.sh" /usr/bin/mount
    fi
fi

# 6. sshfs wrapper：默认补充 umask=022
if [ -f "$WRAP_DIR/sshfs-wrapper.sh" ] && [ -x /usr/bin/sshfs ]; then
    if [ ! -e /usr/bin/sshfs.real ] && ! head -1 /usr/bin/sshfs 2>/dev/null | grep -q '^#!'; then
        cp -a /usr/bin/sshfs /usr/bin/sshfs.real
    fi
    if [ -x /usr/bin/sshfs.real ]; then
        install -m 0755 "$WRAP_DIR/sshfs-wrapper.sh" /usr/bin/sshfs
    fi
fi

# 7. lvcreate wrapper：容器无 udev，返回前同步 dm-* 视图与 /dev/dm-N
if [ -f "$WRAP_DIR/lvcreate-wrapper.sh" ] && [ -x /usr/sbin/lvm ]; then
    if [ -L /usr/sbin/lvcreate ] || ! head -1 /usr/sbin/lvcreate 2>/dev/null | grep -q '^#!'; then
        rm -f /usr/sbin/lvcreate
        install -m 0755 "$WRAP_DIR/lvcreate-wrapper.sh" /usr/sbin/lvcreate
    fi
fi

# 8. 确保 lvm.conf 关闭 udev_sync / udev_rules 并开启 issue_discards
if [ -f /etc/lvm/lvm.conf ]; then
    sed -i -E \
        -e 's/^[[:space:]#]*udev_sync[[:space:]]*=.*/\tudev_sync = 0/' \
        -e 's/^[[:space:]#]*udev_rules[[:space:]]*=.*/\tudev_rules = 0/' \
        -e 's/^[[:space:]#]*issue_discards[[:space:]]*=.*/\tissue_discards = 1/' \
        /etc/lvm/lvm.conf
fi

# 9. DNS 兜底：尊重 Droidspaces 注入的 /etc/resolv.conf，仅在完全无 nameserver 时补写
#    （空 resolv.conf 会导致 pgbouncer evdns_base_new 失败并 SEGV）
if ! grep -q '^nameserver[[:space:]]' /etc/resolv.conf 2>/dev/null; then
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'DNS'
nameserver 223.5.5.5
nameserver 114.114.114.114
nameserver 8.8.8.8
DNS
    chmod 644 /etc/resolv.conf
fi

exit 0
