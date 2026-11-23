#!/bin/bash
# install-fnos-compat.sh — 将 Droidspaces + 主线内核兼容层注入解压后的 fnOS rootfs
# 用法：install-fnos-compat.sh <rootfs_dir> <fnos_assets_dir> <hooks_build_dir> <trimmedia_dir>
set -euo pipefail

ROOT="${1:?missing rootfs dir}"
ASSETS="${2:?missing fnos assets dir}"
HOOKS_DIR="${3:?missing compiled hooks dir}"
TRIMMEDIA_DIR="${4:?missing extracted trimmedia dir}"

echo "--> [1/7] 安装 LD_PRELOAD 拦截库"
mkdir -p "$ROOT/opt/fnnas/hook"
install -m 0755 "$HOOKS_DIR/nodri.so"                "$ROOT/opt/fnnas/hook/nodri.so"
install -m 0755 "$HOOKS_DIR/nodmaheap.so"            "$ROOT/opt/fnnas/hook/nodmaheap.so"
install -m 0755 "$HOOKS_DIR/fakecompat.so"           "$ROOT/opt/fnnas/hook/fakecompat.so"
install -m 0755 "$HOOKS_DIR/triminit_wait.so"        "$ROOT/opt/fnnas/hook/triminit_wait.so"
install -m 0755 "$HOOKS_DIR/fnacl_faccessat_hook.so" "$ROOT/opt/fnnas/fnacl_faccessat_hook.so"

echo "--> [2/7] 安装 mediasrv 及动态硬解/软解 drop-in"
mkdir -p "$ROOT/opt/trimmedia"
cp -a "$TRIMMEDIA_DIR"/. "$ROOT/opt/trimmedia/"
chmod +x "$ROOT/opt/trimmedia/bin/mediasrv"

mkdir -p "$ROOT/etc/systemd/system/mediasrv.service.d"
install -m 0644 "$ASSETS/systemd/mediasrv-override.conf" \
    "$ROOT/etc/systemd/system/mediasrv.service.d/override.conf"
install -m 0644 "$ASSETS/systemd/mediasrv-socket-perm.conf" \
    "$ROOT/etc/systemd/system/mediasrv.service.d/droidspaces-socket.conf"
# 默认先放软解 drop-in；开机后 fnos-droidspaces-fixes.sh 若检测到 VA-API 驱动与 renderD128 会自动切为硬解
cat > "$ROOT/etc/systemd/system/mediasrv.service.d/droidspaces-media.conf" <<'MEDIA_SW'
[Service]
Environment=LD_PRELOAD=/opt/fnnas/hook/nodri.so:/opt/fnnas/hook/nodmaheap.so:/opt/fnnas/hook/fakecompat.so
MEDIA_SW

echo "--> [3/7] 安装包装器模板与运行时脚本"
mkdir -p "$ROOT/usr/local/share/fnos-droidspaces/wrappers" "$ROOT/usr/local/sbin"
for w in mdadm-wrapper.sh mount-wrapper.sh sshfs-wrapper.sh lvcreate-wrapper.sh; do
    install -m 0755 "$ASSETS/wrappers/$w" "$ROOT/usr/local/share/fnos-droidspaces/wrappers/$w"
done

for s in fnos-droidspaces-fixes.sh fnos-trim-keygen.py fnos-block-view.sh fnos-md-alias.sh fnos-dm-sync.sh fnos-db-selfheal.sh; do
    install -m 0755 "$ASSETS/scripts/$s" "$ROOT/usr/local/sbin/$s"
done

# 构建期先就地打好 wrapper（开机 fixes 服务也会自愈）
if [ -x "$ROOT/usr/sbin/mdadm" ] && [ ! -e "$ROOT/usr/sbin/mdadm.real" ]; then
    cp -a "$ROOT/usr/sbin/mdadm" "$ROOT/usr/sbin/mdadm.real"
    install -m 0755 "$ASSETS/wrappers/mdadm-wrapper.sh" "$ROOT/usr/sbin/mdadm"
fi
if [ -e "$ROOT/usr/trim/bin/mdadm" ] && [ ! -L "$ROOT/usr/trim/bin/mdadm" ]; then
    cp -a "$ROOT/usr/trim/bin/mdadm" "$ROOT/usr/trim/bin/mdadm.real"
    install -m 0755 "$ASSETS/wrappers/mdadm-wrapper.sh" "$ROOT/usr/trim/bin/mdadm"
elif [ -d "$ROOT/usr/trim/bin" ]; then
    ln -sfn /usr/sbin/mdadm "$ROOT/usr/trim/bin/mdadm"
fi
if [ -x "$ROOT/usr/bin/mount" ] && [ ! -e "$ROOT/usr/bin/mount.orig" ]; then
    mv "$ROOT/usr/bin/mount" "$ROOT/usr/bin/mount.orig"
    install -m 0755 "$ASSETS/wrappers/mount-wrapper.sh" "$ROOT/usr/bin/mount"
fi
if [ -x "$ROOT/usr/bin/sshfs" ] && [ ! -e "$ROOT/usr/bin/sshfs.real" ]; then
    cp -a "$ROOT/usr/bin/sshfs" "$ROOT/usr/bin/sshfs.real"
    install -m 0755 "$ASSETS/wrappers/sshfs-wrapper.sh" "$ROOT/usr/bin/sshfs"
fi
if [ -x "$ROOT/usr/sbin/lvm" ]; then
    rm -f "$ROOT/usr/sbin/lvcreate"
    install -m 0755 "$ASSETS/wrappers/lvcreate-wrapper.sh" "$ROOT/usr/sbin/lvcreate"
fi

echo "--> [4/7] 配置 LVM（容器无 udev，支持 discard）与挂载点 /vol1"
if [ -f "$ROOT/etc/lvm/lvm.conf" ]; then
    sed -i -E \
        -e 's/^[[:space:]#]*udev_sync[[:space:]]*=.*/\tudev_sync = 0/' \
        -e 's/^[[:space:]#]*udev_rules[[:space:]]*=.*/\tudev_rules = 0/' \
        -e 's/^[[:space:]#]*issue_discards[[:space:]]*=.*/\tissue_discards = 1/' \
        "$ROOT/etc/lvm/lvm.conf"
fi
mkdir -p "$ROOT/vol1" "$ROOT/mnt"

echo "--> [5/7] 安装并启用 fnOS 专属 systemd 服务（通用 Droidspaces 限制由 fnOS.Dockerfile 统一配置）"
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
for unit in fnos-droidspaces-fixes.service fnos-block-view.service fnos-block-sync.service \
    fnos-db-selfheal.service; do
    install -m 0644 "$ASSETS/systemd/$unit" "$ROOT/etc/systemd/system/$unit"
    ln -sfn "/etc/systemd/system/$unit" "$ROOT/etc/systemd/system/multi-user.target.wants/$unit"
done
# 仅安装 fnos-nat-dhcp.service 单元文件；是否启用或屏蔽由 fnOS.Dockerfile 根据 ENABLE_yj_ARG 统一控制
install -m 0644 "$ASSETS/systemd/fnos-nat-dhcp.service" "$ROOT/etc/systemd/system/fnos-nat-dhcp.service"

mkdir -p "$ROOT/etc/systemd/system/trim_init.service.d"
install -m 0644 "$ASSETS/systemd/trim-init-override.conf" \
    "$ROOT/etc/systemd/system/trim_init.service.d/droidspaces-startup.conf"

# PostgreSQL 开机重试：首次开机时 postgresql@15-main 可能与 fnOS 自身的
# triminit 抢跑而瞬间失败（无任何日志），导致主库 trim 建不出来、
# 所有 fnOS 服务报「初始化数据库失败」。这里让它失败后自动重试，
# 再由 fnos-db-selfheal.service 兜底校验/补建 trim 库。
mkdir -p "$ROOT/etc/systemd/system/postgresql@15-main.service.d"
cat > "$ROOT/etc/systemd/system/postgresql@15-main.service.d/droidspaces-retry.conf" <<'EOT'
[Service]
Restart=on-failure
RestartSec=3s
TimeoutStartSec=120
EOT

# 屏蔽 fnOS 在 Android 容器下会导致报错/循环重启的专属服务
ln -sfn /dev/null "$ROOT/etc/systemd/system/trim_trashbind.service"

echo "--> [6/7] 配置 fnOS DNS 防覆盖保护（通用 systemd/udev/NAT 门控由 fnOS.Dockerfile 统一配置）"
# 禁止 NetworkManager 覆盖 Droidspaces 管理的 /etc/resolv.conf
mkdir -p "$ROOT/etc/NetworkManager/conf.d"
cat > "$ROOT/etc/NetworkManager/conf.d/99-no-dns.conf" <<'NMCONF'
[main]
dns=none
NMCONF

# Debian 的 dhclient-script 会加载此钩子，继续应用 DHCP 地址和路由，但不覆盖 /etc/resolv.conf。
mkdir -p "$ROOT/etc/dhcp/dhclient-enter-hooks.d"
cat > "$ROOT/etc/dhcp/dhclient-enter-hooks.d/zz-fnos-nat-dns" <<'DHCPHOOK'
#!/bin/sh
if [ "${FNOS_NAT_DHCP:-}" = 1 ] && [ "${interface:-}" = eth0 ]; then
    make_resolv_conf() { :; }
fi
DHCPHOOK
chmod 0755 "$ROOT/etc/dhcp/dhclient-enter-hooks.d/zz-fnos-nat-dns"

echo "--> [7/7] 清理物理机 fstab（DNS 交由 Droidspaces container.config 管理）"
cat > "$ROOT/etc/fstab" <<'FSTAB'
# Droidspaces fnOS container fstab
tmpfs  /tmp  tmpfs  defaults,nosuid  0  0
FSTAB

echo "--> fnOS Droidspaces 兼容层注入完成"
