#!/bin/bash
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/scripts/lib/desktop-config.sh"
source "$REPO_DIR/scripts/lib/anland-build.sh"
source "$REPO_DIR/scripts/lib/rootfs-config.sh"

: "${VERSION:=dev}"
ARCH=$(uname -m)          # 获取当前系统架构
ENABLE_binfmt="false"
DESKTOP_AUTOSTART="false"
ENABLE_nosnap="false"
ENABLE_8gen2_wayland="false"
ENABLE_systemd257="false"
DISPLAY_BACKEND_INPUT="X11"
# 解析输入参数 (-i 指定 Dockerfile，-v 指定版本号)
while getopts "i:v:K:L:B:P:a:b:c:d:e:f:g:h:n:S:t:u:A:" opt; do
  case $opt in
    i) DOCKERFILE="$OPTARG" ;; # -i 参数赋值给 DOCKERFILE 变量
    v) VERSION="$OPTARG" ;;    # -v 参数赋值给 VERSION 变量
    K) DESKTOP_INPUT="$OPTARG"  ;;
    L) DESKTOP_AUTOSTART="$OPTARG"  ;;
    B) DISPLAY_BACKEND_INPUT="$OPTARG" ;;
    P) PulseAudio="$OPTARG"  ;;
    g) ENABLE_zh_tz="$OPTARG"  ;; # 中文支持
    a) ENABLE_binfmt="$OPTARG" ;; # -a 跨架构支持
    b) ENABLE_yj="$OPTARG" ;;
    c) ENABLE_mesa="$OPTARG" ;;
    d) ENABLE_kfgj="$OPTARG" ;;
    e) ENABLE_zip="$OPTARG" ;;
    f) ENABLE_docker="$OPTARG" ;;
    h) ENABLE_srf="$OPTARG" ;; # 输入法 fcitx5
    n) ENABLE_nosnap="$OPTARG" ;; # Ubuntu nosnap
    S) ENABLE_systemd257="$OPTARG" ;; # systemd 257 旧内核兼容
    t) ENABLE_8gen2_wayland="$OPTARG" ;; # 修复骁龙8 Gen 2 Wayland 花屏
    u) USERNAME="$OPTARG" ;; # 自定义用户名
    A) LEGACY_ANLAND_INPUT="$OPTARG" ;; # 兼容旧参数
    *) echo "用法: $0 -i <template.Dockerfile> -K <none|KDE|'KDE mobile'|GNOME> [-B <x11|anland-wayland>]" ; exit 1 ;;
  esac
done

: "${USERNAME:=Gold}"
: "${ANLAND_RELEASE_REPOSITORY:=Goldzxcbug/droidspaces-package}"
: "${ANLAND_PACKAGE_REVISION:=}"

if ! DESKTOP="$(desktop_normalize "${DESKTOP_INPUT:-}")"; then
  echo "错误：-K 桌面名称无效。" >&2
  exit 1
fi
if [[ -n "${LEGACY_ANLAND_INPUT:-}" ]]; then
  case "$LEGACY_ANLAND_INPUT" in
    true) DISPLAY_BACKEND_INPUT="anland-wayland" ;;
    false) DISPLAY_BACKEND_INPUT="x11" ;;
    *) echo "错误：旧参数 -A 只支持 true 或 false。" >&2; exit 1 ;;
  esac
fi
if ! DISPLAY_BACKEND="$(display_backend_normalize "$DISPLAY_BACKEND_INPUT")"; then
  echo "错误：-B 只支持 x11 或 anland-wayland。" >&2
  exit 1
fi
case "$DESKTOP_AUTOSTART" in true|false) ;; *) echo "错误：-L 只支持 true 或 false。" >&2; exit 1 ;; esac
case "$ENABLE_systemd257" in
  true)
    case "$DESKTOP" in
      kde)
        echo "提示：systemd 257 已启用，普通 KDE 位于验证支持白名单中。"
        ;;
      none)
        DISPLAY_BACKEND="x11"
        DESKTOP_AUTOSTART="false"
        ;;
      *)
        echo "提示：systemd 257 尚不支持 $DESKTOP，强制使用 none 桌面并关闭桌面自启动。"
        DESKTOP="none"
        DISPLAY_BACKEND="x11"
        DESKTOP_AUTOSTART="false"
        ;;
    esac
    ;;
  false) ;;
  *) echo "错误：-S 只支持 true 或 false。" >&2; exit 1 ;;
esac

if [[ "$DESKTOP" == kde-mobile || "$DESKTOP" == gnome || "$DESKTOP" == anland-next || \
      "$DESKTOP" == niri || "$DESKTOP" == hyprland || "$DESKTOP" == mango || "$DESKTOP" == denial ]]; then
  DISPLAY_BACKEND="anland-wayland"
fi
if [[ "$DISPLAY_BACKEND" == anland-wayland ]]; then
  PulseAudio="none"
fi
ANLAND_PACKAGE_FAMILY="$(anland_package_family "$DESKTOP" "$DISPLAY_BACKEND" || true)"

# 校验：检查是否传递了 Dockerfile 模板文件
if [ -z "$DOCKERFILE" ]; then
    echo "错误：必须使用 -i 参数指定模板文件。"
    exit 1
fi

# 校验：检查指定的 Dockerfile 文件在本地是否存在
if [ ! -f "$DOCKERFILE" ]; then
    echo "错误：找不到模板文件 '$DOCKERFILE'。"
    exit 1
fi

# 提取发行版目标名称（例如：Debian-13.Dockerfile -> Debian-13）
PREFIX="$(basename "${DOCKERFILE%.Dockerfile}")"

if ! desktop_target_supported "$PREFIX" "$DESKTOP"; then
  echo "错误：$PREFIX 不支持桌面 $DESKTOP。" >&2
  exit 1
fi
if ! desktop_backend_supported "$PREFIX" "$DESKTOP" "$DISPLAY_BACKEND"; then
  echo "错误：$PREFIX 不支持 $DESKTOP/$DISPLAY_BACKEND 组合。" >&2
  exit 1
fi
if [[ "$DESKTOP" == none && "$DESKTOP_AUTOSTART" == true ]]; then
  echo "错误：桌面为 none 时不能启用桌面自启动。" >&2
  exit 1
fi

echo "========================================================="
echo " 开始构建项目 : $PREFIX"
echo " 使用模板文件 : $DOCKERFILE"
echo " 当前构建版本 : $VERSION"
echo " 跨架构 : $ENABLE_binfmt"
echo " 容器识别部分硬件和网络：$ENABLE_yj"
echo " Ubuntu nosnap：$ENABLE_nosnap"
echo " systemd 257 旧内核兼容：$ENABLE_systemd257"
echo " 修复骁龙8 Gen 2 Wayland 花屏：$ENABLE_8gen2_wayland"
echo " 桌面：$DESKTOP"
echo " 显示后端：$DISPLAY_BACKEND"
echo " 桌面自启动：$DESKTOP_AUTOSTART"
echo "========================================================="

if [ -n "$ANLAND_PACKAGE_FAMILY" ]; then
  if ! anland_prepare_release "$ANLAND_PACKAGE_FAMILY" "$ANLAND_RELEASE_REPOSITORY" "$ANLAND_PACKAGE_REVISION"; then
    exit 1
  fi
  ANLAND_RELEASE_TAG="$ANLAND_RESOLVED_RELEASE_TAG"
  ANLAND_PACKAGE_REVISION="$ANLAND_RESOLVED_REVISION"
  echo " Anland ${ANLAND_PACKAGE_FAMILY^^} 包 Release：$ANLAND_RELEASE_REPOSITORY @ $ANLAND_RELEASE_TAG"
else
  ANLAND_PACKAGE_REVISION="disabled"
fi

# 1. 环境初始化（原生架构模式）
echo "确保处于原生构建环境..."
# 在原生（Native）模式下，不需要初始化 QEMU 模拟器或 binfmt 跨架构支持

# 2. 跨平台编译器（Buildx Builder）设置
# 检查是否存在名为 'droidspaces-builder' 的 buildx 构建器，如果没有则创建
if ! docker buildx inspect droidspaces-builder >/dev/null 2>&1; then
    echo "正在创建新的 buildx 构建器: droidspaces-builder"
    docker buildx create --name droidspaces-builder --driver docker-container --use
else
    echo "使用已存在的 buildx 构建器: droidspaces-builder"
    docker buildx use droidspaces-builder
fi

# 引导启动构建器，确保其处于就绪状态
docker buildx inspect --bootstrap || echo "警告: 引导失败，尝试继续执行..."

# 开启严格模式：后续任何一行命令执行失败（返回非0状态码），脚本立即熔断退出
set -e

# 3. 核心构建流程
TEMP_TAR="custom-${PREFIX}-${DESKTOP}-rootfs.tar"
if [ "$DESKTOP" = "none" ]; then
  DISPLAY_LABEL="CLI"
else
  DISPLAY_LABEL="$(display_backend_label "$DISPLAY_BACKEND")"
fi
FINAL_NAME="${PREFIX}-${DESKTOP}-${DISPLAY_LABEL}-Droidspaces-rootfs-${ARCH}-${VERSION}.tar.xz"

echo "正在运行 Docker Build (原生模式)..."




docker buildx build \
  --target export \
  --output type=tar,dest="$TEMP_TAR" \
  --build-arg DESKTOP="$DESKTOP" \
  --build-arg DESKTOP_AUTOSTART="$DESKTOP_AUTOSTART" \
  --build-arg DISPLAY_BACKEND="$DISPLAY_BACKEND" \
  --build-arg PulseAudio="$PulseAudio" \
  --build-arg ENABLE_zh_tz_ARG="$ENABLE_zh_tz" \
  --build-arg ENABLE_binfmt_ARG="$ENABLE_binfmt" \
  --build-arg ENABLE_yj_ARG="$ENABLE_yj" \
  --build-arg ENABLE_mesa_ARG="$ENABLE_mesa" \
  --build-arg ENABLE_kfgj_ARG="$ENABLE_kfgj" \
  --build-arg ENABLE_zip_ARG="$ENABLE_zip" \
  --build-arg ENABLE_docker_ARG="$ENABLE_docker" \
  --build-arg ENABLE_srf_ARG="$ENABLE_srf" \
  --build-arg ENABLE_nosnap_ARG="$ENABLE_nosnap" \
  --build-arg ENABLE_systemd257_ARG="$ENABLE_systemd257" \
  --build-arg ENABLE_8gen2_wayland_ARG="$ENABLE_8gen2_wayland" \
  --build-arg ANLAND_RELEASE_REPOSITORY="$ANLAND_RELEASE_REPOSITORY" \
  --build-arg ANLAND_PACKAGE_REVISION="$ANLAND_PACKAGE_REVISION" \
  --build-arg USERNAME="$USERNAME" \
  -f "$DOCKERFILE" \
  .





echo "正在写入推荐配置并压缩构建产物..."
package_rootfs_with_config "$TEMP_TAR" "$FINAL_NAME" "$DESKTOP" "$DISPLAY_BACKEND" \
  "${PulseAudio:-none}" "${ENABLE_docker:-false}" "${ENABLE_mesa:-false}" "${ENABLE_zh_tz:-false}"

echo "========================================================="
echo " 恭喜！构建成功完成: $FINAL_NAME"
echo "========================================================="
