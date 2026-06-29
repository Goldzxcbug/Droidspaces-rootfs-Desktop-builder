ARG TARGETPLATFORM
FROM ubuntu:26.04 AS customizer

#######################################################
ARG BUILD_KDE
ARG BUILD_KDE_plus
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG ENABLE_kfgj_ARG
ARG ENABLE_zip_ARG
ARG ENABLE_docker_ARG
ARG ENABLE_srf_ARG
ARG ENABLE_tmoe_ARG
ARG ENABLE_anland_kde_ARG
ARG USERNAME
######################################################

ENV DEBIAN_FRONTEND=noninteractive

RUN sed -i 's/Components: main/Components: main restricted universe multiverse/g' /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || \
    sed -i 's/main/main restricted universe multiverse/g' /etc/apt/sources.list 2>/dev/null && \
    apt-get update && \
    apt-get upgrade -y

# 优先复制自定义脚本
COPY scripts/download-firmware /usr/local/bin/

# 将自定义的 bashrc 脚本复制到根文件系统的 profile 目录
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh

# 复制本仓库内预编译的 anland_kde deb 包
COPY anland-build/ubuntu2604/kwin/*.deb /tmp/anland-build/ubuntu2604/kwin/
COPY anland-build/ubuntu2604/xwayland/*.deb /tmp/anland-build/ubuntu2604/xwayland/

# 赋予相关脚本可执行权限
RUN chmod +x /usr/local/bin/download-firmware /etc/profile.d/ds-aliases.sh

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # 核心工具组件
    bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates locales bash-completion udev dbus systemd-sysv systemd-resolved fastfetch \
    # 用户请求的基础开发/编辑工具
    git nano sudo \
    # 网络与 SSH 工具
    openssh-server net-tools iptables iputils-ping iproute2 dnsutils \
    # 用于系统监控的 procps 进程工具
    procps \
    # 核心内核模块支持
    kmod tzdata && \
    ############################################## KDE支持 ################################################
    # 解除底层系统对中文等翻译文件(.mo)的剔除规则，防止安装桌面时丢包
    sed -i 's|^path-exclude=/usr/share/locale/\*/LC_MESSAGES/\*.mo|#&|' /etc/dpkg/dpkg.cfg.d/excludes || true && \
    # 最小化KDE
    if [ "$BUILD_KDE" = "min" ]; then \
        apt-get install -y --no-install-recommends \
        dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop kubuntu-settings-desktop kubuntu-wallpapers \
        pipewire pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
        dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools dbus-user-session \
        polkit-kde-agent-1 libpam-systemd libpam-modules plasma-session-x11; \
    fi && \
    # 精简KDE
    if [ "$BUILD_KDE" = "conc" ]; then \
        apt-get install -y --no-install-recommends \
        dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji kde-plasma-desktop kubuntu-settings-desktop kubuntu-wallpapers \
        pipewire pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin-x11 upower konsole \
        dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools dbus-user-session aha clinfo dmidecode libdisplay-info-bin pciutils wayland-utils xserver-xorg \
        kfind plasma-systemmonitor filelight glmark2 vkmark systemsettings kde-config-screenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kimageformat6-plugins plasma-browser-integration libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop \
        polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 plasma-session-x11 language-pack-kde-zh-hans language-pack-zh-hans qt6-translations-l10n; \
    fi && \
    ############################################## KDE Mobile 支持（移动端适配） ################################################
    # 使用 Plasma Mobile Shell 替代标准 KDE 桌面，专为触屏手机/平板优化
    if [ "$BUILD_KDE" = "mobile" ]; then \
        apt-get install -y --no-install-recommends \
        # 基础 X11/Wayland 支持
        dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji wayland-utils xserver-xorg dbus-user-session \
        # Plasma Mobile 核心组件
        plasma-nano plasma-mobile plasma-mobile-phone \
        # 虚拟键盘（触屏必需）
        maliit-keyboard maliit-framework maliit-server-qt6 \
        # Wayland 合成器（Mobile 必须走 Wayland）
        kwin-wayland \
        # 音频与电源管理
        pipewire pipewire-pulse wireplumber powerdevil plasma-pa upower pulseaudio-utils \
        # 常用应用
        konsole dolphin kate kinfocenter \
        # Mesa 与 Vulkan
        mesa-utils vulkan-tools \
        # 系统管理工具
        systemsettings plasma-systemmonitor kde-config-screenlocker kio-extras xdg-user-dirs \
        dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers kimageformat6-plugins \
        # 移动端应用
        plasma-settings angelfish \
        # 多媒体支持
        gstreamer1.0-plugins-base gstreamer1.0-plugins-good sound-theme-freedesktop libcanberra-pulse \
        # 认证与安全
        polkit-kde-agent-1 libpam-systemd libpam-modules libpam-kwallet5 \
        # QML 模块（Plasma Mobile UI 依赖，Qt6 命名）
        qml6-module-org-kde-kirigami qml6-module-qtquick-controls \
        qml6-module-qtquick-layouts qml6-module-qtquick-templates \
        # 中文支持
        language-pack-kde-zh-hans language-pack-zh-hans qt6-translations-l10n; \
    fi && \
    ############################################## anland_kde(wayland) 支持 ################################################
    if [ "$ENABLE_anland_kde_ARG" = "true" ] && ([ "$BUILD_KDE" = "min" ] || [ "$BUILD_KDE" = "conc" ] || [ "$BUILD_KDE" = "mobile" ]); then \
        echo "--> [开启] 正在安装 anland_kde..." && \
        echo "--> [开启] 正在安装预编译的 kwin deb 包..." && \
        dpkg -i /tmp/anland-build/ubuntu2604/kwin/*.deb || apt-get install -f -y && \
        echo "--> [开启] 正在安装预编译的 xwayland deb 包..." && \
        dpkg -i /tmp/anland-build/ubuntu2604/xwayland/*.deb || apt-get install -f -y && \
        echo "--> [开启] 设置预编译 deb 包为 hold 模式，防止被 apt 更新覆盖..." && \
        for f in /tmp/anland-build/ubuntu2604/kwin/*.deb /tmp/anland-build/ubuntu2604/xwayland/*.deb; do \
            pkgname=$(dpkg-deb -f "$f" Package) && \
            apt-mark hold "$pkgname" && \
            echo "    hold: $pkgname"; \
        done && \
        echo "--> [开启] 清理临时文件..." && \
        rm -rf /tmp/anland-build && \
        echo "--> [开启] anland_kde 支持已安装"; \
    else \
        rm -rf /tmp/anland-build; \
    fi && \
    ######################################################################################################
    #输入法 fcitx5 (可选)
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        apt-get install -y fcitx5; \
    fi && \
    if [ "$ENABLE_srf_ARG" = "true" ] && [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        apt-get install -y fcitx5-chinese-addons; \
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
        docker.io docker-compose-v2; \
    fi && \
    ## 集成tmoe (可选)
    if [ "$ENABLE_tmoe_ARG" = "true" ]; then \
        git clone --depth=1 https://github.com/2moe/tmoe-linux.git /usr/local/etc/tmoe-linux/git && \
        ln -sf /usr/local/etc/tmoe-linux/git/debian.sh /usr/local/bin/tmoe && \
        chmod -R 755 /usr/local/etc/tmoe-linux; \
    fi && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 强制配置使用 iptables-legacy
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
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # Ubuntu 默认用户是 ubuntu，删除它避免冲突
    deluser --remove-home ubuntu || true && \
    # 创建自定义用户并直接加入 shadow 组，确保锁屏验证权限
    useradd -m -s /bin/bash -G shadow ${USERNAME} && echo "${USERNAME}:1234" | chpasswd && \
    systemctl enable ssh


# 添加环境变量
RUN cat <<'EOF' > /etc/environment
XCURSOR_SIZE=48
EOF

# wayland 显示服务器环境变量配置
# Mobile 模式强制走 Wayland + anland
RUN if [ "$BUILD_KDE" = "mobile" ]; then \
        echo "WAYLAND_DISPLAY=wayland-0" >> /etc/environment; \
        echo "DISPLAY=:0" >> /etc/environment; \
        echo "QT_QPA_PLATFORM=wayland" >> /etc/environment; \
        echo "QT_QPA_PLATFORMTHEME=KDE" >> /etc/environment; \
        echo "QT_ENABLE_HIGHDPI_SCALING=1" >> /etc/environment; \
        echo "PLASMA_PLATFORM=phone" >> /etc/environment; \
        echo "XCURSOR_SIZE=32" >> /etc/environment; \
        echo "ANLAND=1" >> /etc/environment; \
        echo "ANLAND_SOCKET=/run/display.sock" >> /etc/environment; \
        echo "ANLAND_DRM_DEVICE=/dev/dri/renderD128" >> /etc/environment; \
        echo "MESA_LOADER_DRIVER_OVERRIDE=kgsl" >> /etc/environment; \
        echo "GALLIUM_DRIVER=kgsl" >> /etc/environment; \
        echo "FD_FORCE_KGSL=1" >> /etc/environment; \
    elif [ "$ENABLE_anland_kde_ARG" != "true" ]; then \
        echo "DISPLAY=:5" >> /etc/environment; \
    else \
        echo "WAYLAND_DISPLAY=wayland-0" >> /etc/environment; \
        echo "DISPLAY=:0" >> /etc/environment; \
        echo "QT_QPA_PLATFORM=wayland" >> /etc/environment; \
        echo "ANLAND=1" >> /etc/environment; \
        echo "ANLAND_SOCKET=/run/display.sock" >> /etc/environment; \
        echo "ANLAND_DRM_DEVICE=/dev/dri/renderD128" >> /etc/environment; \
        echo "MESA_LOADER_DRIVER_OVERRIDE=kgsl" >> /etc/environment; \
        echo "GALLIUM_DRIVER=kgsl" >> /etc/environment; \
        echo "FD_FORCE_KGSL=1" >> /etc/environment; \
    fi

# 音频选择
RUN if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

# 输入法开机自启动及 KDE 配置
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
    if [ "$ENABLE_mesa_ARG" = "true" ] && [ "$ENABLE_anland_kde_ARG" != "true" ] && [ "$BUILD_KDE" != "mobile" ]; then
        cat <<'EOF' >> /etc/environment
MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform
EOF
    fi

    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/${USERNAME}/.bashrc

    mkdir -p /home/${USERNAME}/.config

    # 标准 KDE 桌面（min/conc）配置：禁用合成器以提升性能
    if [ "$BUILD_KDE" = "min" ] || [ "$BUILD_KDE" = "conc" ]; then
    cat <<'EOF' > /home/${USERNAME}/.config/kwinrc
[Compositing]
Enabled=false
EOF
    fi

    # KDE Mobile 配置：启用合成器，适配触屏
    if [ "$BUILD_KDE" = "mobile" ]; then
    cat <<'EOF' > /home/${USERNAME}/.config/kwinrc
[Compositing]
Enabled=true
Backend=Wayland
AnimationSpeed=3

[Windows]
BorderlessMaximizedWindows=true
Placement=Smart

[Plugins]
kwin4_effect_scaleEnabled=false
kwin4_effect_fadeEnabled=false
kwin4_effect_blurEnabled=false
kwin4_effect_squashEnabled=false
EOF
    # Plasma Mobile Shell 配置
    cat <<'EOF' > /home/${USERNAME}/.config/plasmarc
[Theme]
name=breeze-mobile
EOF
    # 禁用锁屏（容器环境下不需要）
    cat <<'EOF' > /home/${USERNAME}/.config/kscreenlockerrc
[Daemon]
Autolock=false
LockOnResume=false
EOF
    # 触控板/鼠标配置
    cat <<'EOF' > /home/${USERNAME}/.config/touchpadrc
[Touchpad]
NaturalScroll=true
TapToClick=true
EOF
    fi

    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

    # KDE X11 自启动（仅标准桌面 min/conc 使用）
    if [ "$BUILD_KDE_plus" = "true" ] && [ "$ENABLE_anland_kde_ARG" = "false" ] && [ "$BUILD_KDE" != "mobile" ]; then
    cat <<EOF > /etc/systemd/system/plasma-x11.service
[Unit]
Description=Start Plasma X11
After=network.target display-manager.service

[Service]
Type=simple
User=${USERNAME}
EnvironmentFile=-/etc/environment
ExecStart=/bin/bash -lc 'DISPLAY=:5 startplasma-x11'
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/plasma-x11.service /etc/systemd/system/multi-user.target.wants/plasma-x11.service
    fi

    # KDE 标准桌面 Wayland 自启动（min/conc + anland）
    if [ "$BUILD_KDE_plus" = "true" ] && [ "$ENABLE_anland_kde_ARG" = "true" ] && [ "$BUILD_KDE" != "mobile" ]; then
    cat <<EOF > /etc/systemd/system/plasma-wayland.service
[Unit]
Description=Start Plasma Wayland
After=network.target display-manager.service

[Service]
Type=simple
User=${USERNAME}
Group=${USERNAME}
PAMName=login

EnvironmentFile=-/etc/environment
ExecStart=/bin/bash -lc 'startplasma-wayland'
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/plasma-wayland.service /etc/systemd/system/multi-user.target.wants/plasma-wayland.service
    fi

    # KDE Mobile Wayland 自启动（mobile 模式，使用 startplasma-mobile）
    if [ "$BUILD_KDE_plus" = "true" ] && [ "$BUILD_KDE" = "mobile" ]; then
    cat <<EOF > /etc/systemd/system/plasma-wayland.service
[Unit]
Description=Start Plasma Mobile Wayland
After=network.target display-manager.service

[Service]
Type=simple
User=${USERNAME}
Group=${USERNAME}
PAMName=login

EnvironmentFile=-/etc/environment
ExecStart=/bin/bash -lc 'startplasma-mobile'
Restart=no

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/plasma-wayland.service /etc/systemd/system/multi-user.target.wants/plasma-wayland.service
    fi

EOF_RUN

# Mesa 驱动适配
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        echo "--> [开启] 正在下载并安装最新版 Mesa 驱动..." && \
        URL=$(curl -s https://api.github.com/repos/lfdevs/mesa-for-android-container/releases/latest | \
        jq -r '.assets[] | select(.name | test("mesa-for-android-container_.*_ubuntu_resolute_arm64\\.tar\\.gz")) | .browser_download_url' | head -1) && \
        if [ -z "$URL" ] || [ "$URL" = "null" ]; then echo "获取下载链接失败，可能是源仓库还没有提供 Ubuntu 版本的 Mesa 驱动或触发了限制"; exit 1; fi && \
        wget -q --tries=5 --waitretry=3 -O /tmp/mesa.tar.gz "$URL" && \
        tar -zxf /tmp/mesa.tar.gz -C / && \
        rm /tmp/mesa.tar.gz && \
        ldconfig; \
    else \
        echo "--> [跳过] 未开启 Mesa 驱动安装"; \
    fi

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
usermod -a -G aid_inet,aid_net_raw,input,video,tty,sudo,droidspaces-gpu ${USERNAME} || true

grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true

if [ -f /etc/adduser.conf ]; then
    sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf
    echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
    echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty"' >> /etc/adduser.conf
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

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

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

RUN if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
        chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
        mkdir -p /etc/systemd/system/multi-user.target.wants && \
        ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service && \
        (apt-get purge -y qemu-* binfmt-support || true) && \
        apt-get autoremove -y && \
        apt-get autoclean && \
        rm -rf /var/lib/binfmts/* /etc/binfmt.d/* /usr/lib/binfmt.d/qemu-* && \
        dpkg --add-architecture amd64 && \
        sed -i '/^Types: deb/a Architectures: arm64' /etc/apt/sources.list.d/ubuntu.sources && \
        printf "Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: resolute resolute-updates resolute-security\nComponents: main universe restricted multiverse\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n" > /etc/apt/sources.list.d/ubuntu-amd64.sources && \
        apt-get update && \
        (apt-get install -y --no-install-recommends qemu-user-binfmt libc6:amd64 libc6:arm64 libc-bin || \
         apt-get install -y --no-install-recommends qemu-user-binfmt) && \
        apt-get clean; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service; \
    fi

RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/*

FROM scratch AS export
COPY --from=customizer / /
