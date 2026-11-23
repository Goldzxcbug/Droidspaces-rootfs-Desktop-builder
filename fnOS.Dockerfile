# syntax=docker/dockerfile:1.7
# fnOS.Dockerfile — 构建适用于 Droidspaces 的飞牛 fnOS ARM64 RootFS
#
# 阶段 1（BUILDPLATFORM 原生，零 QEMU）：下载/解压 trimfs.tgz、交叉编译 hooks、注入兼容层与 Droidspaces TUI 工具链
# 阶段 2/3（arm64 目标架构）：补齐 Android 权限组（含 droidspaces-gpu），可选按 Debian-13 方式安装 Mesa KGSL GPU 驱动
# 阶段 4（scratch AS export）：导出干净 rootfs 供 buildx --target export 使用

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS builder

ARG TRIMFS_URL=https://github.com/kesry/mainline-linux-mt6771/releases/download/source/trimfs.tgz
ARG TRIMLIB_URL=https://github.com/kesry/mainline-linux-mt6771/releases/download/source/trim-media-lib.zip

ENV DEBIAN_FRONTEND=noninteractive

# 1. 安装构建工具（原生架构交叉编译 aarch64 hooks + 解包工具）
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash ca-certificates curl gzip p7zip-full tar xz-utils \
      gcc-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu && \
    rm -rf /var/lib/apt/lists/*

# 2. 下载并校验飞牛 ARM rootfs (trimfs.tgz) 与媒体服务包 (trim-media-lib.zip)
#    单独成层，便于 BuildKit 缓存 1.9GB 素材
RUN mkdir -p /work/dl /rootfs /work/trimmedia && \
    for attempt in 1 2 3; do \
      echo "--> 下载 trimfs.tgz (尝试 ${attempt}/3)..."; \
      rm -f /work/dl/trimfs.tgz; \
      curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 900 \
        -o /work/dl/trimfs.tgz "${TRIMFS_URL}" && \
      gzip -t /work/dl/trimfs.tgz && break; \
      echo "--> 下载不完整或校验失败，重试..."; \
    done && \
    gzip -t /work/dl/trimfs.tgz && \
    echo "--> 解压 trimfs.tgz 到 /rootfs..." && \
    tar --numeric-owner --exclude='./dev/*' --exclude='dev/*' -xzf /work/dl/trimfs.tgz -C /rootfs && \
    mkdir -p /rootfs/dev && \
    test -f /rootfs/etc/os-release && \
    rm -f /work/dl/trimfs.tgz && \
    echo "--> 下载并解压 trim-media-lib.zip..." && \
    curl -fsSL --retry 3 -o /work/dl/trim-media-lib.zip "${TRIMLIB_URL}" && \
    7z x -y -o/work/trimmedia /work/dl/trim-media-lib.zip >/dev/null && \
    test -f /work/trimmedia/bin/mediasrv && \
    rm -f /work/dl/trim-media-lib.zip

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
    bash /run/fnos/install-fnos-compat.sh /rootfs /run/fnos /work/hooks /work/trimmedia

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

# 套用 Debian-13 的 Android 权限组（含 droidspaces-gpu，供 GPU 与 /dev/video32/33 VA-API 编解码使用）
RUN grep -q '^aid_inet:' /etc/group      || echo 'aid_inet:x:3003:'      >> /etc/group && \
    grep -q '^aid_net_raw:' /etc/group   || echo 'aid_net_raw:x:3004:'   >> /etc/group && \
    grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group && \
    getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu && \
    usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true && \
    (grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true) && \
    if [ -f /etc/adduser.conf ]; then \
      sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf; \
      echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf; \
      echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty droidspaces-gpu"' >> /etc/adduser.conf; \
    fi && \
    echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces

# GPU 适配（套用 Debian-13.Dockerfile 的 Mesa KGSL 逻辑；开启后自动配合 droidspaces-video VA-API）
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
      echo "--> [开启] 正在安装 Mesa KGSL 驱动（套用 Debian-13 方案）..." && \
      cat <<'EOF' >> /etc/environment
MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform
LIBVA_DRIVER_NAME=msm_drm
EOF
      /usr/local/sbin/install-mesa --1; \
    else \
      echo "--> [跳过] 未开启 Mesa 驱动安装（启动后也可通过 droidspaces-gpu / droidspaces-video.sh 随时安装）"; \
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
