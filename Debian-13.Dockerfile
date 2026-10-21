FROM debian:trixie AS customizer

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

# 启用 APT 并行连接、HTTP(S) pipeline 和下载重试
RUN printf '%s\n' \
    'Acquire::Queue-Mode "host";' \
    'Acquire::http::Pipeline-Depth "10";' \
    'Acquire::https::Pipeline-Depth "10";' \
    'Acquire::Retries "3";' \
    > /etc/apt/apt.conf.d/99parallel-downloads

# 更新基础系统并启用 non-free（非自由）和 contrib 软件源
RUN (sed -i 's/main/main contrib non-free/g' /etc/apt/sources.list 2>/dev/null || sed -i 's/Components: main/Components: main contrib non-free/g' /etc/apt/sources.list.d/debian.sources) && \
    apt-get update && \
    apt-get upgrade -y

# 优先复制自定义脚本
COPY scripts/download-firmware /usr/local/bin/

# 将自定义的 bashrc 脚本复制到根文件系统的 profile 目录
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh

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

# 赋予相关脚本可执行权限
RUN chmod +x /usr/local/bin/download-firmware /etc/profile.d/ds-aliases.sh /usr/local/sbin/install-anland-* /usr/local/sbin/install-mesa /usr/local/sbin/install-hangover-wine /usr/local/sbin/install-winefonts /usr/local/sbin/install-desktop /usr/local/sbin/configure-desktop /usr/local/sbin/configure-chrome /usr/local/bin/droidspaces-tui /usr/local/bin/start-desktop-session /usr/local/lib/droidspaces/desktops/*.sh && \
    ln -s droidspaces-tui /usr/local/bin/dstui && \
    ln -s droidspaces-tui /usr/local/bin/ds-tui

# Debian 基础镜像默认通过 dpkg path-exclude 跳过 .mo 翻译文件；全局放开，
# 保证所有桌面 profile 安装的软件带完整语言翻译。
RUN sed -i 's|^path-exclude=/usr/share/locale/\*/LC_MESSAGES/\*.mo|#&|' \
        /etc/dpkg/dpkg.cfg.d/excludes 2>/dev/null || true

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # 核心工具组件
    bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates locales bash-completion udev dbus systemd-sysv systemd-resolved fastfetch \
    # 用户请求的基础开发/编辑工具
    git nano  sudo \
    # 网络与 SSH 工具
    openssh-server net-tools iptables iputils-ping iproute2 dnsutils \
    # 用于系统监控的 procps 进程工具
    procps \
    # 核心内核模块支持
    kmod tzdata tar && \
    /usr/local/sbin/install-desktop "$DESKTOP" && \
    ############################################## Anland Wayland 支持 ################################################
    if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        echo "--> [开启] 正在安装 $DESKTOP 的 Anland 包 (${ANLAND_PACKAGE_REVISION})..." && \
        ANLAND_RELEASE_REPOSITORY="$ANLAND_RELEASE_REPOSITORY" \
        /usr/local/sbin/install-anland-desktop "$DESKTOP" --1 && \
        echo "--> [开启] $DESKTOP 的 Anland 支持已安装"; \
    fi && \
    ######################################################################################################
    #输入法 fcitx5 (可选)
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        apt-get install -y fcitx5; \
    fi && \
    if [ "$ENABLE_srf_ARG" = "true" ] && [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        apt-get install -y  fcitx5-chinese-addons; \
    fi && \
    ## 开发工具集成 (可选)
    if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        apt-get install -y --no-install-recommends \
        build-essential gcc g++ make cmake autoconf automake libtool pkg-config clang llvm python3 python3-pip python3-dev python3-venv python-is-python3; \
    fi && \
    ## 压缩工具扩展 (可选)
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        apt-get install -y --no-install-recommends \
        zip unzip p7zip-full bzip2 xz-utils tar gzip; \
    fi && \
    ## docker (可选)
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        apt-get install -y --no-install-recommends \
        docker.io docker-compose docker-cli; \
    fi && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 强制配置使用 iptables-legacy（这是兼容 Android 内核的硬性要求）
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy && \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

RUN sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        export DEBIAN_FRONTEND=noninteractive && \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
        echo "Asia/Shanghai" > /etc/timezone && \
        dpkg-reconfigure -f noninteractive tzdata && \
        sed -i '/zh_CN.UTF-8/s/^# //' /etc/locale.gen && \
        locale-gen && \
        update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8; \
    else \
        locale-gen && \
        update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; \
    fi && \
    # 配置 SSH 服务（禁用 root 密码登录，但允许常规密码认证）
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # 如果容器内存在默认的 debian 用户，则将其连同家目录一起删除
    (deluser --remove-home debian || true) && \
    useradd -m -s /bin/bash ${USERNAME} && echo "${USERNAME}:1234" | chpasswd

# 为所有 Debian RootFS 安装 Droidspaces USB Manager
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

# 修复anland 音频堵塞
# RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
#        mkdir -p /home/${USERNAME}/.config && \
#       echo -e "\n[Sounds]\nEnable=false" >> /home/${USERNAME}/.config/kdeglobals ; \
#     fi

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


# Mesa 驱动适配
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
# 建立 Android 网络权限组（在 Android 内核上运行 Linux 容器时，必须有这些 GID 才能正常访问网络 socket）
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# 检查并创建 droidspaces-gpu 组
getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
# 为 root 用户赋予访问 Android 硬件及网络的权限组
usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,sudo,droidspaces-gpu ${USERNAME} || true

# 将 _apt 的主用户组改为 aid_inet，确保 apt 包管理器在 Android 环境下可以正常联网
grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true

# 确保未来通过 adduser 创建的所有新用户，都会被默认加入这些 Android 硬件与网络组
if [ -f /etc/adduser.conf ]; then
    sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf
    echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
    echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty"' >> /etc/adduser.conf
fi

# --- 2. 针对 Systemd 的特定修复 ---
# 屏蔽在 Android 内核下容易引发报错或死锁的阻塞服务
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

# 优化 Journald 日志配置（跳过内核审计、KMsg 等 Android 内核不兼容或权限受限的日志源）
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
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        ln -sf /dev/null "/etc/systemd/system/$service"
    done
fi

# 在 systemd-logind 中禁用电源键行为处理（防止容器误拦截或处理宿主机的实体电源按键事件）
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
# 1. 触发器覆盖：限制 udevadm trigger 的扫描范围（防止冷插拔时全面扫描 Android 宿主机硬件导致卡死或冲突）
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# 2. 针对只读文件系统路径（ConditionPathIsReadWrite）的覆盖，防止 udev 相关服务因为路径只读而报错中断
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# 限制特定的网络服务：只有当容器配置为 NAT 模式时才允许启动
# 这可以有效防止容器在“主机网络模式（Host Mode）”下运行时破坏手机原本的蜂窝移动数据网络
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
# 仅在启用硬件访问时限制 udev 服务启动
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



# 写入修复完成的标记和时间戳
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN


COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/
RUN if [ "$ENABLE_binfmt_ARG" = "false" ]; then \
        rm -rf /usr/local/bin/qemu-binfmt-register.sh && \
        rm -rf /etc/systemd/system/qemu-binfmt-register.service ; \
    fi

RUN if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
        chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
        mkdir -p /etc/systemd/system/multi-user.target.wants && \
        ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service && \
        (apt-get purge -y qemu-* binfmt-support || true) && \
        apt-get autoremove -y && \
        apt-get autoclean && \
        rm -rf /var/lib/binfmts/* /etc/binfmt.d/* /usr/lib/binfmt.d/qemu-* && \
        apt-get update && \
        apt-get install -y qemu-user-static binfmt-support && \
        # 显式添加 amd64 异构架构支持
        dpkg --add-architecture amd64 && \
        apt-get update && \
        apt-get install -y libc6:amd64; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service; \
    fi

# Debian 13 当前为 systemd 257，脚本会自动检测并跳过；保留统一选项便于未来版本。
RUN if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        bash /usr/local/sbin/systemd257; \
    else \
        echo "--> [跳过] 未启用 systemd 257 旧内核兼容"; \
    fi

# 最终清理 APT 包管理器缓存，尽可能缩减镜像层体积
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
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 阶段 2：将完整的根文件系统导出到 scratch（空白层），以便外部直接提取或打包成 tarfs
FROM scratch AS export

# 从 customizer 编译阶段将所有定制好的根文件系统内容整体拷贝出来
COPY --from=customizer / /
