#!/usr/bin/env bash
#
# 为桌面用户配置 USB 大容量存储（尤其是相机 / 采集卡这类"晚挂载介质"设备）。
#
# 安装内容：
#   /usr/local/sbin/droidspaces-usb-storage-fixup    设备节点创建 + 介质重新校验
#   /usr/local/sbin/droidspaces-usb-storage-cleanup  拔出时释放容器侧挂载
#   /etc/udev/rules.d/85-droidspaces-usb-storage.rules
#   /etc/systemd/system/droidspaces-usb-storage-fixup.service
#   /etc/polkit-1/rules.d/49-droidspaces-udisks2.rules
#   external_storage 组（gid 1077，对齐 Android 的 AID_EXTERNAL_STORAGE）
#
# 为什么需要三个独立的问题一起修（见各脚本头部注释）：
#   1. Droidspaces 容器内 /dev 不包含容器启动后新出现的块设备节点，/dev/sdX
#      根本不存在，任何程序都无法 open / probe / mount；
#   2. 相机类设备先以"无介质"枚举，用户在机身上确认后才挂上真实存储，而
#      内核只有在该设备被 open 时才会重新校验容量（sd_check_events() ->
#      revalidate_disk()），节点不存在就永远没人 open，容量一直是 0；
#   3. Android GKI 的 exfat 驱动忽略 uid=/gid=/umask= 挂载参数，硬编码
#      gid=1077（AID_EXTERNAL_STORAGE）+ fmask/dmask=0007，因此普通用户必须
#      属于 gid 1077 才能读取 exFAT 介质（镜像里 NTFS 用的是同一种做法：
#      ntfsusb 组 gid 1023）。
#   4. Plasma/anland 会话没有 logind seat、也没有 polkit 认证代理，
#      udisks2 默认的 allow_active 永远不成立，Dolphin 挂载会报
#      "PolicyKit 身份验证系统不可用"。这里显式放行本地管理员组。
#
# 用法: install-droidspaces-usb-storage --user USER
#
set -euo pipefail

INSTALL_DIR="/usr/local/sbin"
UDEV_RULES="/etc/udev/rules.d/85-droidspaces-usb-storage.rules"
UNIT_FILE="/etc/systemd/system/droidspaces-usb-storage-fixup.service"
POLKIT_RULES="/etc/polkit-1/rules.d/49-droidspaces-udisks2.rules"
FIXUP="${INSTALL_DIR}/droidspaces-usb-storage-fixup"
CLEANUP="${INSTALL_DIR}/droidspaces-usb-storage-cleanup"

TARGET_USER=""

usage() {
    cat <<EOF
用法: $0 --user USER

  --user USER   加入 external_storage 组的桌面用户。
  -h, --help    显示此帮助。
EOF
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            --user)
                (($# >= 2)) || { echo "--user 缺少用户名。" >&2; exit 1; }
                TARGET_USER="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "未知参数: $1" >&2
                exit 1
                ;;
        esac
    done
    [[ -n "$TARGET_USER" ]] || { usage >&2; exit 1; }
    getent passwd "$TARGET_USER" >/dev/null || {
        echo "用户不存在: $TARGET_USER" >&2
        exit 1
    }
}

install_runtime_scripts() {
    for f in "$FIXUP" "$CLEANUP"; do
        [[ -f "$f" ]] || {
            echo "缺少运行时脚本: $f（Dockerfile 需要先 COPY scripts/droidspaces-usb-storage-*）" >&2
            exit 1
        }
        bash -n "$f"
        chmod 0755 "$f"
    done
}

install_udev_rules() {
    cat > "$UDEV_RULES" <<'EOF'
# Droidspaces: 容器启动后才插入的 USB 大容量存储设备没有 /dev 节点；相机
# （如哈苏 X2D）还要等机身确认后才会把真实存储挂到 gadget 上，而内核只在设备
# 被 open 时才重新校验介质。这里触发一个 helper 补齐节点并重新校验，让
# udisks2 / Dolphin 能看到文件系统。
# 详见 /usr/local/sbin/droidspaces-usb-storage-fixup。
#
# 只有 "add" 会启动 helper；helper 自己会用 "change" 重新触发 udev，
# 不能让 "change" 再次启动 helper（否则会无限循环）。
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd*[!0-9]", ENV{ID_BUS}=="usb", TAG+="systemd", ENV{SYSTEMD_WANTS}+="droidspaces-usb-storage-fixup.service"
# 拔出时释放容器侧挂载，避免内核块设备一直被占用：被占用会让 Android vold
# 下次插入时 fsck 失败，Android 会提示"格式化"相机存储。
ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd*[!0-9]", ENV{ID_BUS}=="usb", RUN+="/usr/local/sbin/droidspaces-usb-storage-cleanup %k"
EOF
    chmod 0644 "$UDEV_RULES"
}

install_unit() {
    cat > "$UNIT_FILE" <<'EOF'
[Unit]
Description=Droidspaces USB storage fix-up (device nodes + media revalidation)
Documentation=file:/usr/local/sbin/droidspaces-usb-storage-fixup
After=systemd-udevd.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/droidspaces-usb-storage-fixup
TimeoutStartSec=300
Nice=10
IOSchedulingClass=idle
EOF
    chmod 0644 "$UNIT_FILE"
}

install_polkit_rule() {
    # 会话没有 seat 也没有认证代理，因此必须显式放行；三种管理员组都覆盖，
    # 并把本机桌面用户直接写进去，避免不同发行版 wheel/sudo 组差异。
    cat > "$POLKIT_RULES" <<EOF
/* Droidspaces / anland 桌面：Plasma 会话没有 logind seat（Seat= 为空、
 * Type=unspecified），也没有运行 polkit 认证代理，于是 udisks2 默认的
 * allow_active 永远不成立，Dolphin 挂载可移动介质会报
 *   "Not authorized to perform operation / PolicyKit 身份验证系统不可用"
 * 这里对本地管理员组显式返回 YES。这些镜像都是单用户桌面，
 * 该用户本来就有完整 sudo 权限，不构成额外提权。
 */
polkit.addRule(function(action, subject) {
    var removable = [
        "org.freedesktop.udisks2.filesystem-mount",
        "org.freedesktop.udisks2.filesystem-mount-system",
        "org.freedesktop.udisks2.filesystem-mount-other-seat",
        "org.freedesktop.udisks2.filesystem-unmount-others",
        "org.freedesktop.udisks2.eject-media",
        "org.freedesktop.udisks2.power-off-drive",
        "org.freedesktop.udisks2.power-off-drive-other-seat"
    ];
    if (removable.indexOf(action.id) >= 0 &&
        (subject.isInGroup("wheel") || subject.isInGroup("sudo") ||
         subject.user === "${TARGET_USER}")) {
        return polkit.Result.YES;
    }
});
EOF
    chmod 0644 "$POLKIT_RULES"
}

configure_groups() {
    # gid 1077 = Android AID_EXTERNAL_STORAGE。Android GKI 的 exfat 驱动把
    # 所有 exFAT 介质的属主硬编码为 root:1077、权限 0770，普通用户必须属于
    # 该 gid 才能读写。与 install-usb-manager.sh 里 ntfsusb(1023) 的做法一致。
    if command -v groupadd >/dev/null 2>&1; then
        groupadd -g 1077 external_storage 2>/dev/null || true
        usermod -aG external_storage "$TARGET_USER" 2>/dev/null || true
    fi
}

reload_services() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload >/dev/null 2>&1 || true
    fi
}

main() {
    parse_args "$@"
    install_runtime_scripts
    install_udev_rules
    install_unit
    install_polkit_rule
    configure_groups
    reload_services

    echo "[usb-storage] 已配置 USB 大容量存储访问。"
    echo "[usb-storage] 已把 ${TARGET_USER} 加入 external_storage 组；"
    echo "[usb-storage] 需要注销重新登录（或重启容器）后，桌面应用才能读到 exFAT 介质。"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
