#!/bin/bash

# 禁止 apt 在执行过程中弹出交互式配置界面，适用于无人值守构建。
export DEBIAN_FRONTEND=noninteractive

# 停止服务、卸载挂载点和修改 apt 配置都需要 root 权限。
if [ "$EUID" -ne 0 ]; then
  echo "请用 root 运行：sudo bash nosnap.sh"
  exit 1
fi

echo "[nosnap] 正在停止 snapd 服务"
# 某些精简 RootFS 中可能没有 systemctl，因此先检查命令是否存在。
# stop 终止当前进程，disable 防止 snapd 在下次启动时再次运行。
if command -v systemctl >/dev/null 2>&1; then
  for unit in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] 正在卸载 Snap 挂载点"
# 删除 snapd 文件前先卸载其 loop/bind 挂载，避免目录仍被占用。
# sort -r 让较深的子挂载点优先卸载；-l/-f 用于处理容器中的残留挂载。
if command -v mount >/dev/null 2>&1 && command -v umount >/dev/null 2>&1; then
  for mountpoint in $(mount | awk '$3 ~ "^/snap" || $3 ~ "^/var/snap" || $3 ~ "^/var/lib/snapd" { print $3 }' | sort -r); do
    umount -lf "$mountpoint" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] 正在清除 snapd 软件包"
# 仅处理已经安装的软件包，避免 apt 因找不到可删除目标而中断构建。
# 同时移除 GNOME Software、Discover 等桌面环境中的 Snap 后端。
if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
  for package in snapd gnome-software-plugin-snap snapd-desktop-integration plasma-discover-backend-snap; do
    if dpkg -s "$package" >/dev/null 2>&1; then
      apt-get purge -y "$package" >/dev/null 2>&1 || true
    fi
  done
  apt-get autoremove -y --purge >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
fi

echo "[nosnap] 正在清理 Snap 残留"
# 清理卸载软件包后仍可能保留的挂载目录、缓存、用户数据和 systemd 单元。
rm -rf \
  /snap \
  /var/snap \
  /var/lib/snapd \
  /var/cache/snapd \
  /usr/lib/snapd \
  /etc/systemd/system/snapd* \
  /etc/apt/apt.conf.d/*snap* \
  "$HOME/snap" \
  /home/*/snap

echo "[nosnap] 正在阻止 APT 重新安装 snapd"
# 使用负优先级阻止后续依赖解析重新安装 snapd 及桌面集成组件。
# 屏蔽浏览器和邮件客户端的 Snap 过渡包，并优先选择 Mozilla Team 的 deb。
mkdir -p /etc/apt/preferences.d
if ! cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
Package: snapd snapd-desktop-integration gnome-software-plugin-snap plasma-discover-backend-snap
Pin: release a=*
Pin-Priority: -10

Package: chromium-browser
Pin: release o=Ubuntu
Pin-Priority: -10

Package: firefox:any firefox-*:any thunderbird:any thunderbird-*:any
Pin: version /^([0-9]+:)?1snap[0-9]/
Pin-Priority: -10

Package: firefox:any firefox-*:any thunderbird:any thunderbird-*:any
Pin: release o=LP-PPA-mozillateam
Pin-Priority: 1001
EOF
then
  echo "[nosnap] 写入 APT 锁定配置失败"
  exit 1
fi

# 优先使用 UBUNTU_CODENAME，并兼容只提供 VERSION_CODENAME 的系统。
ubuntu_codename=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
fi

# 下载文本并输出到标准输出，供 API 查询和仓库可用性探测使用。
download_stdout() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
  else
    return 1
  fi
}

# 从已发布的候选仓库中选取一个代号，并为该 PPA 配置独立的签名密钥。
add_ppa() {
  local ppa="$1"
  shift
  local url="https://ppa.launchpadcontent.net/${ppa}/ubuntu"
  local name="${ppa/\//-}"
  local candidate suite="" key keyring key_tmp source_tmp

  echo "[nosnap] 正在添加 ppa:$ppa"
  for candidate in "$@"; do
    if download_stdout "$url/dists/$candidate/Release" >/dev/null 2>&1; then
      suite="$candidate"
      break
    fi
  done
  if [ -z "$suite" ]; then
    echo "[nosnap] ppa:$ppa 没有可用的 ${ubuntu_codename} 仓库，已跳过"
    return 1
  fi

  # Launchpad API 会把多个 JSON 字段放在同一行，按字段名提取完整指纹。
  key="$(download_stdout "https://api.launchpad.net/1.0/~${ppa%/*}/+archive/ubuntu/${ppa##*/}" 2>/dev/null |
    sed -nE 's/.*"signing_key_fingerprint"[[:space:]]*:[[:space:]]*"([[:xdigit:]]{40})".*/\1/p')"
  if [ -z "$key" ]; then
    echo "[nosnap] 获取 ppa:$ppa 签名密钥指纹失败，已跳过"
    return 1
  fi

  mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d || return 1
  keyring="/etc/apt/keyrings/$name.asc"
  key_tmp="$(mktemp "/etc/apt/keyrings/.$name.XXXXXX")" || return 1
  if ! download_stdout "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$key" > "$key_tmp" ||
     ! grep -Fxq -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_tmp" ||
     ! grep -Fxq -- '-----END PGP PUBLIC KEY BLOCK-----' "$key_tmp" ||
     ! chmod 0644 "$key_tmp" ||
     ! mv -fT "$key_tmp" "$keyring"; then
    rm -f "$key_tmp"
    echo "[nosnap] 配置 ppa:$ppa 签名密钥失败，已跳过"
    return 1
  fi

  source_tmp="$(mktemp "/etc/apt/sources.list.d/.$name.XXXXXX")" || return 1
  if ! printf 'deb [signed-by=%s] %s %s main\n' "$keyring" "$url" "$suite" > "$source_tmp" ||
     ! chmod 0644 "$source_tmp" ||
     ! mv -fT "$source_tmp" "/etc/apt/sources.list.d/$name.list"; then
    rm -f "$source_tmp"
    echo "[nosnap] 写入 ppa:$ppa 软件源失败，已跳过"
    return 1
  fi

  if [ "$suite" != "$ubuntu_codename" ]; then
    echo "[nosnap] ppa:$ppa 未发布 ${ubuntu_codename}，改用 ${suite}"
  fi
}

if [ -n "$ubuntu_codename" ]; then
  # 保留 XtraDeb 在新版本尚未发布仓库时的候选顺序。
  xtradeb_candidates=("$ubuntu_codename")
  case "$ubuntu_codename" in
    resolute)
      xtradeb_candidates+=(questing plucky noble)
      ;;
    questing)
      xtradeb_candidates+=(plucky noble)
      ;;
    plucky|oracular)
      xtradeb_candidates+=(noble)
      ;;
  esac

  add_ppa xtradeb/apps "${xtradeb_candidates[@]}" || true
  # Firefox 和 Thunderbird 使用为目标 Ubuntu 版本构建的软件包。
  add_ppa mozillateam/ppa "$ubuntu_codename" || true
else
  echo "[nosnap] 无法检测 Ubuntu 代号，跳过 PPA 配置"
fi

echo "[nosnap] 处理完成"
