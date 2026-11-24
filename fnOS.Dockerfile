# syntax=docker/dockerfile:1.7
# fnOS.Dockerfile — 构建适用于 Droidspaces 的飞牛 fnOS ARM64 RootFS
#
# 阶段 1（BUILDPLATFORM 原生，零 QEMU）：从飞牛官方 ARM ISO 提取并解压 trimfs.tgz、交叉编译 hooks、注入兼容层与 Droidspaces TUI 工具链
# 阶段 2/3（arm64 目标架构）：补齐 Android 权限组（含 droidspaces-gpu），可选按 Debian-13 方式安装 Mesa KGSL GPU 驱动
# 阶段 4（scratch AS export）：导出干净 rootfs 供 buildx --target export 使用

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder

# 默认自动从飞牛官网 ARM 下载页解析最新 UEFI ARM ISO (armsr) 直链并提取 trimfs.tgz；
# 也可通过 --build-arg FNOS_ISO_URL=... 指定固定 ISO 链接，或传入 TRIMFS_URL=... 直接下载 trimfs.tgz
ARG FNOS_ISO_URL=auto
ARG FNOS_ISO_MD5=
ARG FNOS_FALLBACK_ISO_URL=http://thunder.liveupdate.fnnas.com:8080/arm/iso/armsr/fnos_Mainland-PE_arm_1.2.1011_armsr_3133.iso
ARG FNOS_FALLBACK_ISO_MD5=1e2073528f7ffee774012a6a9646bd98
ARG TRIMFS_URL=

ENV DEBIAN_FRONTEND=noninteractive

# 1. 安装构建工具（原生架构交叉编译 aarch64 hooks + ISO/压缩包解包工具）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash ca-certificates curl gzip p7zip-full python3 tar xz-utils \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu && \
    rm -rf /var/lib/apt/lists/*

# 2. 从飞牛官方 ARM ISO 获取并校验飞牛 ARM rootfs (trimfs.tgz)
#    单独成层，便于 BuildKit 缓存素材
RUN <<'EOF_DL'
#!/bin/bash
set -euo pipefail

mkdir -p /work/dl /rootfs

if [ -n "${TRIMFS_URL}" ]; then
    for attempt in 1 2 3; do
        echo "--> 直接下载 trimfs.tgz (尝试 ${attempt}/3): ${TRIMFS_URL}"
        rm -f /work/dl/trimfs.tgz
        curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 900 \
            -o /work/dl/trimfs.tgz "${TRIMFS_URL}" && \
        gzip -t /work/dl/trimfs.tgz && break
        echo "--> 下载不完整或校验失败，重试..."
    done
    gzip -t /work/dl/trimfs.tgz
else
    ISO_URL="${FNOS_ISO_URL}"
    ISO_MD5="${FNOS_ISO_MD5}"

    if [ "${ISO_URL}" = "auto" ]; then
        echo "--> 正在从飞牛官网解析最新 UEFI ARM ISO (armsr) 下载地址..."
        if curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 \
            https://www.fnnas.com/download-arm -o /work/dl/download-arm.html; then
            RESOLVED="$(python3 - /work/dl/download-arm.html <<'PY' || true
import base64, re, sys
html = open(sys.argv[1], encoding="utf-8", errors="ignore").read().replace('\\"', '"')
for blk in re.findall(r'\{[^{}]*armsr/[^{}]*\.iso[^{}]*\}', html):
    tm = re.search(r'"thunder":"thunder://([A-Za-z0-9+/=]+)"', blk)
    hm = re.search(r'"hash":"([0-9a-fA-F]{32})"', blk)
    if not tm:
        continue
    raw = base64.b64decode(tm.group(1)).decode("utf-8", errors="ignore")
    if raw.startswith("AA") and raw.endswith("ZZ"):
        url = raw[2:-2]
        md5 = hm.group(1).lower() if hm else ""
        print(f"{url}\t{md5}")
        sys.exit(0)
sys.exit(1)
PY
)"
            rm -f /work/dl/download-arm.html
            if [ -n "${RESOLVED}" ]; then
                ISO_URL="${RESOLVED%%	*}"
                [ -z "${ISO_MD5}" ] && ISO_MD5="${RESOLVED#*	}"
                echo "--> 解析到官方 ARM ISO: ${ISO_URL}"
                [ -n "${ISO_MD5}" ] && echo "--> 官方 ISO MD5: ${ISO_MD5}"
            fi
        fi

        if [ -z "${ISO_URL}" ] || [ "${ISO_URL}" = "auto" ]; then
            echo "--> [提示] 官网动态解析失败，回退至内置官方 ARM ISO 直链"
            ISO_URL="${FNOS_FALLBACK_ISO_URL}"
            [ -z "${ISO_MD5}" ] && ISO_MD5="${FNOS_FALLBACK_ISO_MD5}"
        fi
    fi

    ISO_OK=0
    for attempt in 1 2 3; do
        echo "--> 下载飞牛官方 ARM ISO (尝试 ${attempt}/3): ${ISO_URL}"
        if curl -fL -C - --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 1800 \
            -o /work/dl/fnos-arm.iso "${ISO_URL}"; then
            if [ -n "${ISO_MD5}" ]; then
                echo "--> 校验 ISO MD5 (${ISO_MD5})..."
                if echo "${ISO_MD5}  /work/dl/fnos-arm.iso" | md5sum -c -; then
                    ISO_OK=1
                    break
                else
                    echo "--> ISO MD5 校验失败，删除后重试..."
                    rm -f /work/dl/fnos-arm.iso
                fi
            else
                ISO_OK=1
                break
            fi
        else
            echo "--> ISO 下载中断，重试..."
        fi
    done

    [ "${ISO_OK}" = "1" ] || { echo "--> 飞牛官方 ARM ISO 下载或校验失败" >&2; exit 1; }

    echo "--> 从官方 ARM ISO 提取 trimfs.tgz..."
    7z e -y -o/work/dl /work/dl/fnos-arm.iso trimfs.tgz >/dev/null
    rm -f /work/dl/fnos-arm.iso
    test -f /work/dl/trimfs.tgz
    gzip -t /work/dl/trimfs.tgz
fi

echo "--> 解压 trimfs.tgz 到 /rootfs..."
tar --numeric-owner --exclude='./dev/*' --exclude='dev/*' -xzf /work/dl/trimfs.tgz -C /rootfs
mkdir -p /rootfs/dev
test -f /rootfs/etc/os-release
rm -f /work/dl/trimfs.tgz
EOF_DL

# 3. 注入 Droidspaces TUI / GPU / Video 工具链（含 droidspaces-tui、droidspaces-gpu、droidspaces-video.sh、install-mesa）
RUN --mount=type=bind,source=scripts,target=/run/droidspaces-scripts \
    --mount=type=bind,from=droidspaces-tui,target=/run/droidspaces-tui \
    bash /run/droidspaces-scripts/install-rootfs-tools.sh \
      --root /rootfs \
      --tui-dir /run/droidspaces-tui \
      --desktop none \
      --display-backend x11

# 4. 交叉编译 LD_PRELOAD 拦截库并注入 fnOS Droidspaces 兼容层
RUN --mount=type=bind,source=fnos,target=/run/fnos \
    mkdir -p /work/hooks && \
    cp -a /run/fnos/ld-hooks/. /work/hooks/ && \
    bash /work/hooks/build-hooks.sh aarch64-linux-gnu-gcc && \
    bash /run/fnos/install-fnos-compat.sh /rootfs /run/fnos /work/hooks

# =====================================================================
# 阶段 2 & 3：arm64 目标环境定制（Android 权限组 + 可选 Mesa KGSL GPU 驱动）
# =====================================================================
FROM scratch AS rootfs-base
COPY --from=builder /rootfs /

FROM rootfs-base AS customizer

ARG DESKTOP=none
ARG DESKTOP_AUTOSTART=false
ARG DISPLAY_BACKEND=x11
ARG PulseAudio=none
ARG ENABLE_zh_tz_ARG=true
ARG ENABLE_binfmt_ARG=false
ARG ENABLE_yj_ARG=false
ARG ENABLE_mesa_ARG=false
ARG ENABLE_kfgj_ARG=false
ARG ENABLE_zip_ARG=false
ARG ENABLE_docker_ARG=false
ARG ENABLE_srf_ARG=false
ARG ENABLE_nosnap_ARG=false
ARG ENABLE_systemd257_ARG=false
ARG ENABLE_8gen2_wayland_ARG=false
ARG ANLAND_RELEASE_REPOSITORY=Goldzxcbug/droidspaces-package
ARG ANLAND_PACKAGE_REVISION=disabled
ARG USERNAME=Gold

ENV DEBIAN_FRONTEND=noninteractive

# 强制配置使用 iptables-legacy（兼容 Android 内核，按 Debian 发行版保持一致）
RUN if [ -x /usr/sbin/iptables-legacy ]; then \
        update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    fi && \
    if [ -x /usr/sbin/ip6tables-legacy ]; then \
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true; \
    fi

# 修复容器内的 DHCP 网络服务配置（与 Debian-13 保持一致）
RUN mkdir -p /etc/systemd/network && \
    cat <<'EOF' > /etc/systemd/network/10-eth-dhcp.network
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# 应用 Android 运行环境兼容性修复（按 Debian 12 方式与 Debian-13 保持一致，重点针对 Systemd、NAT 与 Udev）
RUN <<'EOF_RUN'
set -e

# --- 1. 常规兼容性修复 ---
grep -q '^aid_inet:' /etc/group      || echo 'aid_inet:x:3003:'      >> /etc/group
grep -q '^aid_net_raw:' /etc/group   || echo 'aid_net_raw:x:3004:'   >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
(grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true)

if [ -f /etc/adduser.conf ]; then
    sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf
    echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
    echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty droidspaces-gpu"' >> /etc/adduser.conf
fi

# --- 2. 针对 Systemd 的特定修复 ---
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

cat >> /etc/systemd/journald.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH="/lib/systemd/system"
[ -d "$GUEST_SYSTEMD_PATH" ] || GUEST_SYSTEMD_PATH="/usr/lib/systemd/system"

if [ -f "$GUEST_SYSTEMD_PATH/dbus.service" ]; then
    ln -sf "$GUEST_SYSTEMD_PATH/dbus.service" "/etc/systemd/system/multi-user.target.wants/dbus.service"
fi

# 按其他发行版统一规则响应 ENABLE_yj_ARG（开启 NAT 和硬件识别）
if [ "$ENABLE_yj_ARG" = "true" ]; then
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
            ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
        fi
    done
    # fnOS 默认 enable_hw_access=0 时无 udev，由 fnos-nat-dhcp.service 在 NAT 模式下兜底 DHCP
    if [ -f /etc/systemd/system/fnos-nat-dhcp.service ]; then
        ln -sf /etc/systemd/system/fnos-nat-dhcp.service /etc/systemd/system/multi-user.target.wants/fnos-nat-dhcp.service
    fi
else
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        ln -sf /dev/null "/etc/systemd/system/$service"
    done
    rm -f /etc/systemd/system/multi-user.target.wants/fnos-nat-dhcp.service
    ln -sf /dev/null /etc/systemd/system/fnos-nat-dhcp.service
fi

# 在 systemd-logind 中禁用电源键行为处理
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# 应用 udev 覆盖配置
# 1. 触发器覆盖：限制 udevadm trigger 的扫描范围（防止全量扫描触发 Android 内核 panic）
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# 2. 清除只读路径检查（ConditionPathIsReadWrite），防止容器 /sys 只读导致 udev 被跳过
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# 仅在 NAT/Gateway 模式下允许启动网络管理服务，避免 Host Mode 破坏手机网络
for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
EOF
    fi
done

# 仅在启用硬件访问（enable_hw_access=1）时允许启动 udev 相关服务
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-hwaccess-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q 'enable_hw_access=1' /run/droidspaces/container.config"
EOF
    fi
done

# 针对 Android 环境微调日志轮转（logrotate）的最大容量限制
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# GPU / VA-API 适配：
# - fnOS 当前底层为 Debian 12 (bookworm)，不兼容仅支持 Debian 13 的 install-mesa；
# - 但无桌面 NAS 的视频硬解/硬编（droidspaces-media-decode VA-API）本身不依赖定制 Mesa，
#   只需保留 enable_gpu_mode=1 透传 /dev/dri/renderD128 与 /dev/video32/33，并配置 LIBVA_DRIVER_NAME=msm_drm。
# - 若未来 fnOS 升级到 Debian 13，则自动调用 install-mesa --1。
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
      . /etc/os-release && \
      printf '%s\n' 'LIBVA_DRIVER_NAME=msm_drm' >> /etc/environment && \
      if [ "${ID:-}" = "debian" ] && [ "${VERSION_ID:-}" = "13" ]; then \
        echo "--> [开启] 检测到 Debian 13，安装 Mesa KGSL 驱动..." && \
        printf '%s\n' \
          'MESA_LOADER_DRIVER_OVERRIDE=kgsl' \
          'TU_DEBUG=noconform' \
          >> /etc/environment && \
        /usr/local/sbin/install-mesa --1; \
      else \
        echo "--> [提示] 当前 fnOS 底层为 ${PRETTY_NAME:-Debian 12}，跳过 Debian 13 专属 install-mesa；已保留 GPU 透传与 VA-API 环境（启动后可运行 droidspaces-video.sh 安装 msm_drm_drv_video.so）"; \
      fi; \
    else \
      echo "--> [跳过] 未开启 GPU/VA-API 透传配置"; \
    fi

# 清理仅用于桌面构建的一次性脚本（保留 droidspaces-tui、droidspaces-gpu、droidspaces-video.sh、install-mesa）
RUN rm -f \
      /usr/local/sbin/configure-chrome \
      /usr/local/sbin/configure-desktop \
      /usr/local/sbin/install-desktop \
      /usr/local/sbin/install-fcitx5 \
      /usr/local/sbin/install-anland-desktop \
      /usr/local/sbin/install-anland-* \
      /usr/local/sbin/install-droidspaces-usb-manager \
      /usr/local/sbin/systemd257 \
      /usr/local/sbin/nosnap && \
    rm -rf /usr/local/lib/droidspaces/desktops && \
    apt-get clean 2>/dev/null || true && \
    rm -rf /var/lib/apt/lists/*

# 阶段 4：导出干净的 rootfs 供 buildx --target export --output type=tar 使用
FROM scratch AS export
COPY --from=customizer / /
