FROM fedora:43 AS customizer

#######################################################
ARG DESKTOP
ARG DESKTOP_AUTOSTART
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG ENABLE_kfgj_ARG
ARG ENABLE_zip_ARG
ARG ENABLE_docker_ARG
ARG ENABLE_srf_ARG
ARG DISPLAY_BACKEND
ARG ENABLE_8gen2_wayland_ARG
ARG ENABLE_systemd257_ARG
ARG USERNAME
ARG ANLAND_RELEASE_REPOSITORY=Goldzxcbug/droidspaces-package
ARG ANLAND_PACKAGE_REVISION=unknown
######################################################

ENV DEBIAN_FRONTEND=noninteractive

# 通用 Droidspaces USB Manager 安装器
COPY scripts/install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
COPY scripts/systemd257.sh /usr/local/sbin/systemd257
COPY scripts/tui/install-anland-kde.sh /usr/local/sbin/install-anland-kde
COPY scripts/tui/install-anland-gnome.sh /usr/local/sbin/install-anland-gnome
COPY scripts/tui/install-anland-next.sh /usr/local/sbin/install-anland-next
COPY scripts/tui/install-anland-niri.sh /usr/local/sbin/install-anland-niri
COPY scripts/tui/install-anland-hyprland.sh /usr/local/sbin/install-anland-hyprland
COPY scripts/tui/install-anland-mango.sh /usr/local/sbin/install-anland-mango
COPY scripts/tui/install-anland-denial.sh /usr/local/sbin/install-anland-denial
COPY scripts/install-anland-desktop.sh /usr/local/sbin/install-anland-desktop
COPY scripts/tui/install-mesa.sh /usr/local/sbin/install-mesa
COPY scripts/tui/install-hangover-wine.sh /usr/local/sbin/install-hangover-wine
COPY scripts/tui/install-winefonts.sh /usr/local/sbin/install-winefonts
COPY scripts/tui/droidspaces-tui.sh /usr/local/bin/droidspaces-tui
COPY scripts/install-desktop.sh /usr/local/sbin/install-desktop
COPY scripts/configure-desktop.sh /usr/local/sbin/configure-desktop
COPY scripts/configure-chrome.sh /usr/local/sbin/configure-chrome
COPY scripts/start-desktop-session.sh /usr/local/bin/start-desktop-session
COPY scripts/desktops/ /usr/local/lib/droidspaces/desktops/
COPY scripts/etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf /tmp/Anland-Audio.conf
RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        install -D -m 0644 /tmp/Anland-Audio.conf /etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf; \
    fi && \
    rm -f /tmp/Anland-Audio.conf

# 加速下载
RUN echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf && \
    echo "fastestmirror=True" >> /etc/dnf/dnf.conf && \
    echo "defaultyes=True" >> /etc/dnf/dnf.conf

RUN chmod +x /usr/local/sbin/install-anland-* /usr/local/sbin/install-mesa /usr/local/sbin/install-hangover-wine /usr/local/sbin/install-winefonts /usr/local/sbin/install-desktop /usr/local/sbin/configure-desktop /usr/local/sbin/configure-chrome /usr/local/bin/droidspaces-tui /usr/local/bin/start-desktop-session /usr/local/lib/droidspaces/desktops/*.sh && \
    ln -s droidspaces-tui /usr/local/bin/dstui && \
    ln -s droidspaces-tui /usr/local/bin/ds-tui && \
    dnf install -y --setopt=install_weak_deps=False \
    # 核心工具组件
    bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates bash-completion systemd-udev dbus-daemon systemd systemd-pam systemd-resolved fastfetch \
    # 用户请求的基础开发/编辑工具
    git nano sudo \
    # 网络与 SSH 工具（包含 DHCP 客户端）
    openssh-server net-tools iptables iptables-legacy iputils iproute bind-utils dhcp-client \
    # 用于系统监控的 procps 进程工具
    procps-ng \
    # 核心内核模块支持及语言包
    kmod tzdata tar glibc-locale-source glibc-langpack-en glibc-langpack-zh && \
    /usr/local/sbin/install-desktop "$DESKTOP" && \
    # 输入法 fcitx5 (可选)
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        dnf install -y  fcitx5 fcitx5-qt fcitx5-gtk ; \
    fi && \
    if [ "$ENABLE_srf_ARG" = "true" ] && [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False fcitx5-chinese-addons; \
    fi && \
    ## 开发工具集成 (可选)
    if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False \
        gcc gcc-c++ make cmake autoconf automake libtool pkgconf clang llvm python3 python3-pip python3-devel; \
    fi && \
    ## 压缩工具扩展 (可选)
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False \
        zip unzip p7zip p7zip-plugins bzip2 xz tar gzip; \
    fi && \
    ## docker (可选)
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False \
        moby-engine docker-compose docker-cli; \
    fi && \
    dnf upgrade -y && \
    dnf clean all && \
    rm -rf /var/cache/dnf

############################################## Anland Wayland 支持 ################################################
RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        echo "--> [开启] 正在安装 $DESKTOP 的 Anland 包 (${ANLAND_PACKAGE_REVISION})..." && \
        ANLAND_RELEASE_REPOSITORY="$ANLAND_RELEASE_REPOSITORY" \
        /usr/local/sbin/install-anland-desktop "$DESKTOP" --1 && \
        echo "--> [开启] $DESKTOP 的 Anland 支持已安装"; \
    fi

# 强制配置使用 iptables-legacy（兼容 Android 内核的硬性要求）
RUN ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables && \
    ln -sf /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -sf /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore && \
    ln -sf /usr/sbin/ip6tables-legacy-save /usr/sbin/ip6tables-save && \
    ln -sf /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore

RUN if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
        echo "Asia/Shanghai" > /etc/timezone && \
        echo "LANG=zh_CN.UTF-8" > /etc/locale.conf && \
        echo "LC_ALL=zh_CN.UTF-8" >> /etc/locale.conf; \
    else \
        echo "LANG=en_US.UTF-8" > /etc/locale.conf && \
        echo "LC_ALL=en_US.UTF-8" >> /etc/locale.conf; \
    fi && \
    # 配置 SSH 服务
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # 删除默认可能存在的用户并创建新用户
    (userdel -r debian 2>/dev/null || true) && \
    useradd -m -s /bin/bash ${USERNAME} && echo "${USERNAME}:1234" | chpasswd

# 为所有 Fedora RootFS 安装 Droidspaces USB Manager
RUN /usr/local/sbin/install-droidspaces-usb-manager --user "${USERNAME}"

# 初始化环境变量文件；桌面专属变量由对应 profile 管理。
RUN : > /etc/environment

RUN if [ "$ENABLE_mesa_ARG" = "true" ] && [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        echo "MESA_LOADER_DRIVER_OVERRIDE=kgsl" >> /etc/environment; \
        echo "GALLIUM_DRIVER=kgsl" >> /etc/environment; \
        echo "FD_FORCE_KGSL=1" >> /etc/environment; \
    fi

# 修复骁龙8 Gen 2 设备在 Wayland 下的花屏问题
RUN if [ "$ENABLE_8gen2_wayland_ARG" = "true" ]; then \
        echo "FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1" >> /etc/environment; \
    fi
# 音频选择
RUN if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

# 输入法开机自启动
COPY scripts/start/ /tmp/droidspaces-start/
RUN <<'EOF_RUN'
    if [ "$ENABLE_srf_ARG" = "true" ]; then
    mkdir -p /home/${USERNAME}/.config/autostart
    cat <<'EOF' > /home/${USERNAME}/.config/autostart/fcitx5.desktop
[Desktop Entry]
Name=Fcitx5
GenericName=Input Method
Comment=Start Input Method
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
Type=Application
Categories=System;Utility;
StartupNotify=false
NoDisplay=true
EOF
    cat <<'EOF' >> /etc/environment
XMODIFIERS=@im=fcitx5
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
SDL_IM_MODULE=fcitx5
GLFW_IM_MODULE=fcitx
EOF
    fi

    if [ "$ENABLE_mesa_ARG" = "true" ] && [ "$DISPLAY_BACKEND" != "anland-wayland" ] ; then
        cat <<'EOF' >> /etc/environment
MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform
EOF
    fi

    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/${USERNAME}/.bashrc
    /usr/local/sbin/configure-desktop "$DESKTOP" "$DISPLAY_BACKEND" "$DESKTOP_AUTOSTART" "$USERNAME"
    rm -rf /tmp/droidspaces-start
EOF_RUN

RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        /usr/local/sbin/install-mesa --1; \
    else \
        echo "--> [跳过] 未开启 Mesa 驱动安装"; \
    fi

# 安装并配置原生 ARM64 Google Chrome。
RUN /usr/local/sbin/configure-chrome "$DESKTOP" "$DISPLAY_BACKEND"

# 修复容器内的 DHCP 网络服务配置
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

# 应用 Android 运行环境兼容性修复（重点针对 Systemd 和 Udev）
RUN <<'EOF_RUN'

# --- 1. 常规兼容性修复 ---
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu

usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,wheel,droidspaces-gpu ${USERNAME} || true

# --- PipeWire 实时调度权限：修复 Plasma/KWin 反复重启 ---
getent group pipewire >/dev/null || groupadd -r pipewire
usermod -a -G pipewire ${USERNAME} || true
mkdir -p /etc/systemd/system.conf.d /etc/systemd/user.conf.d
printf '[Manager]\nDefaultLimitRTPRIO=70\nDefaultLimitNICE=-19\nDefaultLimitRTTIME=infinity\n' \
    > /etc/systemd/system.conf.d/50-pipewire-rt.conf
cp /etc/systemd/system.conf.d/50-pipewire-rt.conf /etc/systemd/user.conf.d/50-pipewire-rt.conf

# 确保未来通过 useradd 创建的新用户也会进入附加组 (Fedora 通过 /etc/default/useradd 处理)
if [ -f /etc/default/useradd ]; then
    sed -i '/^GROUPS=/d' /etc/default/useradd
    echo 'GROUPS="aid_inet,aid_net_raw,input,video,tty"' >> /etc/default/useradd
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
GUEST_SYSTEMD_PATH="/usr/lib/systemd/system"

if [ -f "$GUEST_SYSTEMD_PATH/dbus.service" ]; then
    ln -sf "$GUEST_SYSTEMD_PATH/dbus.service" "/etc/systemd/system/multi-user.target.wants/dbus.service"
fi

if [ "$ENABLE_yj_ARG" = "true" ]; then
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
            ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
        fi
    done
else
    # 未启用硬件支持时，屏蔽容器内不需要的系统服务
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        ln -sf /dev/null "/etc/systemd/system/$service"
    done
fi

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
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# 仅在 NAT 或网关网络模式下启动网络服务
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

# --- 3. Droidspaces NAT 与 DNS 兼容修复 ---
# 使用标准 glibc 域名解析，/etc/resolv.conf 由 Droidspaces 或 DHCP 解析器管理
sed -i 's/^hosts:.*/hosts: files dns myhostname/' /etc/nsswitch.conf

# 为 NAT 模式创建以 root 权限运行的 DHCP 服务
cat > /etc/systemd/system/ds-dhcp.service << 'EOF_DHCP'
[Unit]
Description=Droidspaces NAT DHCP (Root Bypass)
After=network.target

[Service]
Type=forking
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
ExecStart=/usr/sbin/dhclient
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF_DHCP
ln -sf /etc/systemd/system/ds-dhcp.service /etc/systemd/system/multi-user.target.wants/ds-dhcp.service

if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN


COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/
RUN if [ "$ENABLE_binfmt_ARG" = "false" ]; then \
        rm -rf /usr/local/bin/qemu-binfmt-register.sh && \
        rm -rf /etc/systemd/system/qemu-binfmt-register.service ; \
    fi

# 注意：Fedora 无法像 Debian 的 dpkg 那样直接添加 amd64 异构架构
RUN if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
        chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
        mkdir -p /etc/systemd/system/multi-user.target.wants && \
        ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service && \
        dnf install -y --setopt=install_weak_deps=False qemu-user-static; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service; \
    fi

# 可选：为 systemd 258+ 发行版构建 systemd 257 旧内核兼容运行时。
RUN if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        bash /usr/local/sbin/systemd257; \
    else \
        echo "--> [跳过] 未启用 systemd 257 旧内核兼容"; \
    fi

# 最终清理 DNF 缓存以缩减镜像体积
# 打包前删除仅用于构建的一次性脚本；TUI 和运行时脚本保留。
RUN rm -f \
        /usr/local/sbin/configure-chrome \
        /usr/local/sbin/configure-desktop \
        /usr/local/sbin/install-desktop \
        /usr/local/sbin/install-anland-desktop \
        /usr/local/sbin/install-droidspaces-usb-manager \
        /usr/local/sbin/systemd257 \
        /usr/local/sbin/nosnap && \
    rm -rf /usr/local/lib/droidspaces/desktops && \
    dnf clean all && \
    rm -rf /var/cache/dnf/* /tmp/* /var/tmp/*

# 阶段 2：将完整的根文件系统导出到 scratch
FROM scratch AS export

COPY --from=customizer / /
