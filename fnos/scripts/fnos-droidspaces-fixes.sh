#!/bin/bash
# fnos-droidspaces-fixes.sh — 开机自愈 Droidspaces 容器中的 fnOS 兼容层
set -u

WRAP_DIR="/usr/local/share/fnos-droidspaces/wrappers"
HOOK="/opt/fnnas/fnacl_faccessat_hook.so"

# 1. 全局注入 fnacl_faccessat_hook.so（覆盖系统服务与应用中心安装的所有 App），
#    并保留核心飞牛服务的 LD_PRELOAD drop-in
if [ -f "$HOOK" ]; then
    if ! grep -qx "$HOOK" /etc/ld.so.preload 2>/dev/null; then
        echo "$HOOK" >> /etc/ld.so.preload
        chmod 0644 /etc/ld.so.preload
    fi
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

# 2. 移除飞腾 ftg340 全局 ld.so 劫持，并动态配置 mediasrv 硬解/软解：
#    有高通 VA-API 驱动 (msm_drm_drv_video.so) + renderD128 时，通过 qcom_vaapi.so
#    引导 mediasrv 走 VA-API 硬解/硬编 + Adreno Turnip Vulkan 零拷贝缩放；
#    否则自动挂载 nodri/nodmaheap/fakecompat 走 CPU 软解兜底。
if [ -f /etc/ld.so.conf ] && grep -qx '/usr/lib/aarch64-linux-gnu/ftg340' /etc/ld.so.conf; then
    sed -i '\|^/usr/lib/aarch64-linux-gnu/ftg340$|d' /etc/ld.so.conf
    ldconfig 2>/dev/null || true
fi

mkdir -p /etc/systemd/system/mediasrv.service.d
VA_DRV=""
if [ -f /usr/lib/aarch64-linux-gnu/dri/msm_drm_drv_video.so ]; then
    VA_DRV="/usr/lib/aarch64-linux-gnu/dri/msm_drm_drv_video.so"
elif [ -f /usr/lib/dri/msm_drm_drv_video.so ]; then
    VA_DRV="/usr/lib/dri/msm_drm_drv_video.so"
fi

if [ -c /dev/dri/renderD128 ] && [ -n "$VA_DRV" ]; then
    DRI_DIR="$(dirname "$VA_DRV")"
    if [ -e "$DRI_DIR/ftd330_drv_video.so" ] && [ ! -L "$DRI_DIR/ftd330_drv_video.so" ] &&
       [ ! -e "$DRI_DIR/ftd330_drv_video.so.orig" ]; then
        mv "$DRI_DIR/ftd330_drv_video.so" "$DRI_DIR/ftd330_drv_video.so.orig" 2>/dev/null || true
    fi
    ln -sfn "$VA_DRV" "$DRI_DIR/ftd330_drv_video.so"

    if [ -f /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json ]; then
        mkdir -p /etc/vulkan/icd.d
        if [ -e /etc/vulkan/icd.d/d3000m_icd.json ] && [ ! -L /etc/vulkan/icd.d/d3000m_icd.json ] &&
           [ ! -e /etc/vulkan/icd.d/d3000m_icd.json.disabled ]; then
            mv /etc/vulkan/icd.d/d3000m_icd.json /etc/vulkan/icd.d/d3000m_icd.json.disabled 2>/dev/null || true
        fi
        ln -sfn /usr/share/vulkan/icd.d/freedreno_icd.aarch64.json /etc/vulkan/icd.d/d3000m_icd.json
    fi

    cat > /etc/systemd/system/mediasrv.service.d/droidspaces-media.conf <<MEDIA_HW
[Service]
Environment=MESA_LOADER_DRIVER_OVERRIDE=kgsl
Environment=TU_DEBUG=noconform
Environment=LIBVA_DRIVERS_PATH=$DRI_DIR
Environment=LD_PRELOAD=/opt/fnnas/hook/qcom_vaapi.so
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
