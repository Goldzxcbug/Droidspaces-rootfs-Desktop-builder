中文 | [English](README_english.md) | [返回项目主页](../README.md)

# scripts 目录说明

本目录存放 RootFS 构建期间使用的安装器、写入 RootFS 的维护工具以及 systemd 服务模板。多数文件由 Dockerfile 或 GitHub Actions 调用；运行前请先确认脚本应在 Linux 容器还是构建环境中执行。

## 文件一览

| 文件 | 运行位置 | 作用 |
| --- | --- | --- |
| `install-rootfs-tools.sh` | RootFS 构建环境 | 统一安装镜像内的命令、桌面 profile、TUI 来源记录及所选音频配置。 |
| `install-desktop.sh`、`desktops/*.sh` | RootFS 构建环境 | 按稳定 slug 分发桌面 profile，并维护软件包集合和桌面专属环境变量。 |
| `configure-desktop.sh` | RootFS 构建环境 | 写入桌面/显示后端配置，调用 profile 环境配置并按需安装统一自启动服务。 |
| `configure-chrome.sh` | RootFS 构建环境 | 在所有支持 Chrome 的镜像中安装 Chrome；Anland Wayland 镜像额外配置硬件加速启动参数和桌面入口。 |
| `start-desktop-session.sh` | Linux 容器 | 根据 `/etc/droidspaces-desktop.conf` 启动实际桌面会话。 |
| `install-anland-desktop.sh` | RootFS 构建环境 | 根据桌面 slug 分发到 KDE、GNOME、Niri、Hyprland、Mango、Denial 或 Anland Next 安装器。 |
| `lib/anland-build.sh` | RootFS 构建宿主 | 为 native/QEMU 构建统一解析 Anland 包族、Release tag 和 revision。 |
| `sync-tui.sh` | 开发与构建环境 | 从 `Gold-bug-tui` Release 下载并解压 TUI 压缩包，校验清单、摘要、大小、归档结构和脚本语法。 |
| `install-usb-manager.sh` | Linux 容器 | 安装 Droidspaces USB Manager、发行版依赖、菜单入口和用户权限。 |
| `systemd257.sh` | RootFS 构建环境 | 在需要时安装由包管理器管控的 systemd 257 完整包族，供旧 Android 内核使用。 |
| `download-firmware` | Debian/Ubuntu 容器 | 安装并解压 `linux-firmware` 中的 `.zst` 固件。 |
| `nosnap.sh` | Ubuntu RootFS 构建环境 | 移除 Snap、阻止其重新安装，并配置传统 deb 软件源。 |
| `bashrc.sh` | Linux 用户 shell | 提供 Docker 快捷命令、温度查看和 SSH 文件传输等辅助函数。 |
| `start/desktop-session.service` | Linux 容器的 systemd | 通过统一入口自动启动所选桌面会话。 |
| `binfmt/*` | Linux 容器的 systemd/内核 | 检查并挂载 `binfmt_misc`，为 QEMU 跨架构执行做准备。 |

构建入口先运行 `sync-tui.sh` 获取并解压 `Gold-bug-tui.tar.gz`，再将解压目录和 `scripts/` 作为 BuildKit 只读挂载交给 `install-rootfs-tools.sh` 安装。七个 Anland 入口分别保留，共享函数安装到 `/usr/local/lib/droidspaces/tui/`。KDE/KDE Mobile 镜像安装 PipeWire 配置；Anland Wayland 镜像安装 WirePlumber 配置。

镜像内提供 `droidspaces-tui`、`droidspaces-gpu`、`droidspaces-video.sh`，以及 `install-mesa`、`install-hangover-wine`、`install-winefonts` 和各 `install-anland-*` 命令。TUI 与安装器的功能随构建时获取的发布版本提供。

## Droidspaces TUI

在容器终端或 `adb shell -t` 中运行 `droidspaces-tui`，也可使用别名 `dstui`、`ds-tui`：

```bash
droidspaces-tui
# 以下两个命令等价
dstui
ds-tui
```

在仓库检出目录中，先下载发布文件再运行：

```bash
bash scripts/sync-tui.sh --output .build/tui
bash .build/tui/droidspaces-tui.sh
```

主菜单提供以下组件。输入数字或字母快捷键，再按 Enter 确认。

| 入口 | 操作 |
| --- | --- |
| `[1] Mesa + VA-API` | 安装、更新和卸载 Mesa，选择历史版本，配置 OpenGL/Vulkan，管理视频驱动。 |
| `[2] Anland` | 查看桌面组件版本，安装、更新或卸载匹配的 Anland 组件。 |
| `[3] Hangover Wine` | 安装、更新或卸载 Hangover Wine。 |
| `[4] Wine 字体` | 安装、更新或卸载字体包。 |
| `F` | 刷新组件状态和上游版本。 |
| `C` | 清理 Hangover 清单缓存或全部下载缓存。 |
| `U` | 检查更新，更新 TUI、受管安装脚本或全部内容。 |

Anland 入口按 `/etc/droidspaces-desktop.conf` 显示对应桌面组件；`none` 或未知桌面进入组件选择页。旧镜像缺少配置时，按已安装的组件识别桌面。卸载 Mesa、KWin、Mutter 或 compositor 补丁时恢复发行版软件包；Hangover Wine 和 Wine 字体移除各自内容。

组件状态包括未安装、已是最新、可更新、本地较新、版本未知和安装记录漂移。上游查询在后台运行，显示查询进度或具体错误。过期缓存自动刷新；断网时显示历史结果及检查时间。安装、卸载或切换下载源后自动刷新状态。

### 下载源与更新

首次运行时，中文环境默认使用 CNB，其他语言环境默认使用 GitHub。下载源可选自动测速、GitHub、`gh-proxy.com` 或 CNB，也可在启动时指定：

```bash
droidspaces-tui --source cnb
droidspaces-tui --source github
```

来源偏好保存在当前用户配置目录。GitHub/代理模式使用 GitHub Release API 与发布清单交叉校验；CNB 模式使用同步清单中的 SHA-256 和大小。旧发布缺少摘要时会提示，并检查归档结构和包元数据。

`U` 从 `Gold-bug-tui` Release 获取更新，校验后备份并替换文件。`C` 可清理 `/var/cache/hangover-wine` 下的下载缓存；清空后，下次安装会重新下载软件包。

### GPU 与视频编解码

GPU 菜单分为概览、OpenGL 和 Vulkan 页面，驱动清单支持分页选择。

Mesa 页的 `[5] 视频编解码` 提供视频驱动安装、更新、卸载和实时监控。单独操作视频驱动使用 `--media-only`；`[4] 选择 Mesa 版本` 使用 `--mesa-only`。视频版本和文件摘要记录在 `/var/lib/droidspaces-tui/components/video.version`。更新或卸载后需重启相关应用。

实时监控读取当前用户有权访问的驱动会话，按应用及 UID 显示方向、格式、处理尺寸、输出 FPS 和硬件状态。绿色表示驱动已确认硬件工作完成，黄色表示待确认或未知，红色表示错误。可读的 mpv、VLC、OBS 进程也会列出；没有驱动遥测时，状态显示未知。

输出 FPS 是相邻采样的驱动输出帧速率，首次采样显示 `--`，暂停后显示 0。它与屏幕播放帧率口径不同。处理尺寸可能包含硬件对齐，例如 1920×1088。旧驱动、其他接口或进程权限限制可能使会话不可见。按 `q`、`Esc` 或 `Ctrl+C` 返回菜单。

独立运行监控：

```bash
droidspaces-video.sh --once
droidspaces-video.sh --json
droidspaces-video.sh --interval 2
```

监控使用 Bash、awk、jq 和 GNU coreutils/findutils，构建的镜像已包含这些工具。`--no-color` 关闭彩色输出。

### 日志与故障恢复

安装器和 GPU 配置操作共用修改锁。日志与阶段记录位于 `/var/lib/droidspaces-tui/operations/transactions`；非 root 预下载日志位于 `~/.local/state/droidspaces-tui/logs`。

失败或中断后恢复已备份的配置；未完成的 TUI 文件更新在下次运行时恢复。软件包事务可能已完成，配置恢复不能回滚整次包安装。请根据日志重新运行对应安装器核验或修复。

输出诊断状态：

```bash
droidspaces-tui --status
droidspaces-tui --json
```

## Mesa 安装器

`install-mesa` 在 GitHub/代理模式从分发 Release 选择当前发行版对应的 ARM64 Mesa 资产；CNB 模式则只读取同一 CNB Release 的 `mesa-distribution-manifest`。随后安装其中同步的 `msm_drm_drv_video.so`。支持 Debian 13、Ubuntu 24.04/25.10/26.04、Fedora 43/44/45 和 Arch Linux。视频编解码驱动按发行版安装到 libva 的默认驱动目录：Debian/Ubuntu 为 `/usr/lib/aarch64-linux-gnu/dri`，Fedora 为 `/usr/lib64/dri`，Arch Linux 为 `/usr/lib/dri`。

安装器会严格检查 Release tag、资产名和下载内容。GitHub/代理模式保留 GitHub Release API 的 SHA-256 交叉校验；CNB 模式只使用 CNB 分发清单中的 SHA-256 与大小，并继续校验随 Release 同步的媒体驱动 `SHA256SUMS`。下载支持断点续传，临时文件在退出时自动清理。

在容器内交互运行：

```bash
sudo install-mesa
```

未指定参数时，脚本会测试三个下载源并提示选择。也可以直接指定来源，适合无人值守构建：

```bash
sudo install-mesa --1  # GitHub
sudo install-mesa --2  # gh-proxy.com
sudo install-mesa --3  # CNB
```

三个来源选项互斥，并同时作用于 Mesa 与视频编解码驱动下载。`-1`、`-2`、`-3` 是对应的短参数，`--help` 可查看内置帮助。

安装完成后，脚本按发行版写入持久锁定：

| 发行版 | 锁定位置与机制 |
| --- | --- |
| Debian/Ubuntu | `/etc/apt/preferences.d/hold-anland-package`，`Pin-Priority: -1` |
| Fedora | `/etc/dnf/dnf.conf` 中脚本管理的 `exclude` 块 |
| Arch | `/etc/pacman.conf` 中脚本管理的 `IgnorePkg` 块 |

锁定范围仅根据归档中实际安装的 Mesa 包生成。KWin/Xwayland 与 Mutter/Xwayland 分别由 `install-anland-kde.sh` 和 `install-anland-gnome.sh` 锁定。托管配置可重复运行，不会不断追加相同块；已有的非托管配置会保留。

## 新增桌面 profile

桌面名称、发行版能力和显示后端矩阵集中在 `lib/desktop-config.sh`。新增桌面时：

1. 在 `desktop_normalize`、`desktop_label` 和支持矩阵中登记稳定 slug。
2. 新建可执行的 `desktops/<slug>.sh`，默认操作按 `/etc/os-release` 安装软件包，并实现 `configure-environment <backend>` 配置桌面专属环境变量。
3. 在 `start-desktop-session.sh` 添加会话命令；`install-desktop.sh` 会自动发现合法 slug 对应的可执行 profile。
4. 在中英文工作流入口的 `desktop` 下拉中加入显示名称。

依赖 patched Wayland 包的 profile 还需在 `lib/anland-build.sh` 的 `anland_package_family` 中登记包族。

桌面翻译文件由 Dockerfile 统一配置：Fedora 写入 `%_install_langs all`，Debian/Ubuntu 取消 dpkg 的 locale `path-exclude`，Arch 移除 `NoExtract`。

KDE/KDE Mobile profile 安装 `xdg-desktop-portal`、`xdg-desktop-portal-kde`，并将 `etc/pipewire/client.conf.d/90-droidspaces-portal-rt-workaround.conf` 安装到 `/etc/pipewire/client.conf.d/`。该配置设置 `rtportal.enabled = false`。相关问题见 [xdg-desktop-portal #2110](https://github.com/flatpak/xdg-desktop-portal/issues/2110) 和 [#2139](https://github.com/flatpak/xdg-desktop-portal/pull/2139)。

## Anland KDE 安装器

`install-anland-kde` 默认从 `Goldzxcbug/droidspaces-package` 的固定滚动 Release `anland-kde-packages` 读取 `anland-kde-manifest`，为 Debian 13、Ubuntu 26.04、Fedora 43/44/45 或 Arch Linux ARM64 安装匹配版本的 patched KWin/Xwayland 包。

```bash
sudo install-anland-kde
```

使用 `--1`、`--2`、`--3` 选择 GitHub、`gh-proxy.com` 或 CNB；省略时测速后交互选择。GitHub/代理模式使用 GitHub API 摘要校验，CNB 模式使用同步清单校验。脚本按系统 locale 输出中文或英文，并通过 APT hold、DNF exclude 或 Pacman `IgnorePkg` 锁定相关包。

安装公开 Fork 发布的包时只需覆盖仓库；Fork 必须提供固定标签 `anland-kde-packages`：

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  install-anland-kde --1
```

Anland 宿主模块、App、SELinux、绑定挂载和 Droidspaces 权限仍需按[Wayland 与 Anland 配置教程](../docs/zh/桌面与Anland.md#wayland-和-anland-宿主端配置)完成。

## Anland GNOME 安装器

`install-anland-gnome` 从固定滚动 Release `anland-gnome-packages` 的 `anland-gnome-manifest` 读取匹配归档，为 Debian 13、Ubuntu 26.04、Fedora 43/44/45 或 Arch Linux ARM64 安装 patched Mutter 运行时包。相关包通过 APT hold、DNF exclude 或 Pacman `IgnorePkg` 锁定。下载源和命令行参数与 KDE 安装器一致。

```bash
sudo install-anland-gnome
```

使用公开 Fork 的包时覆盖仓库变量：

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  install-anland-gnome --1
```

## Anland Next 安装器

`install-anland-next` 默认从固定滚动 Release `anland-session-packages` 读取 `anland-session-manifest`，为 Debian 13、Ubuntu 26.04、Fedora 43/44/45 或 Arch Linux ARM64 安装 `anland-session` 包。下载源选择、镜像 digest 校验和命令行参数与 KDE 安装器一致。

```bash
sudo install-anland-next
```

包内包含 `anland-miniwm`、patched Xwayland 和 patched bubblewrap。后两者位于 `/usr/lib/anland/`，由会话加入 PATH。

会话入口为 `/usr/bin/anland-session`，配合 `/usr/lib/systemd/user/anland-session.service` 使用。

Anland Next profile 默认让 Qt 6 应用使用原生 Wayland，并显式安装对应平台插件；直接通过终端启动时，用户 shell 会读取运行中的 `~/.anlandx-env`。

使用公开 Fork 的包时覆盖仓库变量：

```bash
sudo ANLAND_NEXT_RELEASE_REPOSITORY=owner/repository \
  install-anland-next --1
```

## Anland Niri、Hyprland、Mango 和 Denial 安装器

Niri、Hyprland、Mango 和 Denial 安装器从各自固定滚动 Release 安装 compositor 与 patched `xorg-xwayland`，支持 Debian 13、Ubuntu 26、Fedora 43/44/45 和 Arch ARM64。四个桌面在 `scripts/desktops/<slug>.sh` 各有独立 profile；profile 提供终端、XDG portal、音频和字体等基础服务，Niri 在 Arch 上还包含常用桌面工具。各 compositor 共用 patched Xwayland；安装器会阻止互相覆盖，并在卸载时保留其他组件使用的包。

按桌面选择其中一个命令：

```bash
sudo install-anland-niri
sudo install-anland-hyprland
sudo install-anland-mango
sudo install-anland-denial
```

## USB Manager 安装器

`install-usb-manager.sh` 支持 Debian/Ubuntu、Fedora 和 Arch，自动安装 PyQt5、ADB、udev、NTFS、exFAT 等依赖，并安装 `usb-manager`、`usb-passthrough` 和 `usb-storage-passthrough` 命令。

```bash
sudo ./scripts/install-usb-manager.sh --user "$USER"
```

`--user USER` 指定获得 USB 管理权限和桌面入口的用户。省略时依次尝试 `SUDO_USER`、当前登录用户和第一个普通用户。开发或离线测试可以通过 `--source DIR` 使用本地 Droidspaces-USB-Manager 源码目录；运行 `--help` 查看完整参数。

Arch 系统存在 `/etc/droidspaces-systemd257` 时，安装器保留 systemd 的 Pacman 锁定，并安装其余依赖。

RootFS 导入 Droidspaces 时必须开启硬件访问，否则容器无法看到 `/sys/bus/usb` 和 `/sys/bus/scsi`。

## systemd 257 兼容脚本

`systemd257.sh` 供 Dockerfile 在 `enable_systemd257=true` 时调用。它检查已安装的 systemd 主版本：257 或更低版本直接跳过，更高版本则从 `Goldzxcbug/droidspaces-package` 的冻结兼容 Release `systemd257-packages` 安装对应发行版的完整原生包族，并锁定 systemd 相关包。新包先发布到包含源码版本和仓库提交的不可变标签；RootFS 只有在该 Release 完整发布后，才会一次性更新标签、各平台 SHA-256、预期包数和包仓库提交。

```bash
sudo ./scripts/systemd257.sh
```

这是面向旧 Android 内核的实验性兼容步骤。生成 RootFS 后应实际验证 systemd、D-Bus、udev、网络和桌面会话。

## 固件工具

`download-firmware` 会被复制为 Debian 13 和 Ubuntu 24/25/26 RootFS 中的 `/usr/local/bin/download-firmware`，但不会自动执行。需要时在容器中运行：

```bash
sudo download-firmware
```

脚本安装 `zstd` 和 `linux-firmware`，解压 `/lib/firmware` 下的 `.zst` 文件，并修复指向压缩文件的软链接。成功后创建 `/var/lib/.fw-setup-completed`；该标记目前不用于跳过重复运行。

## 其他构建和启动文件

- `nosnap.sh` 仅用于 Ubuntu。它停止并卸载 Snap、清理残留、写入 APT pin 防止重新安装，并配置项目所需的传统 deb 来源。它会修改系统软件包和 APT 配置，应在目标 RootFS 或构建层中以 root 运行。
- `start/desktop-session.service` 是通用服务模板，通过 `start-desktop-session.sh` 读取桌面配置，以 RootFS 的 UID 1000 用户启动对应会话，并对异常退出进行限频重启。
- `binfmt/qemu-binfmt-register.sh` 与对应 service 检查内核是否支持 `binfmt_misc`，必要时挂载它；不支持时安全跳过。实际跨架构执行仍需要 QEMU 解释器。
- `bashrc.sh` 是追加到用户 shell 环境的辅助配置，不应作为独立安装器执行。

## TUI 下载与维护

TUI 源码在 [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) 仓库维护。RootFS 构建从该仓库的 `Gold-bug-tui` 滚动 Release 获取当前发布。

在本仓库根目录下载：

```bash
bash scripts/sync-tui.sh --output .build/tui
```

使用 CNB 镜像：

```bash
bash scripts/sync-tui.sh --output .build/tui --source cnb
```

下载器使用 Bash、curl、GNU tar/coreutils、gzip 和 util-linux 的 `flock`。先校验发布清单与 `Gold-bug-tui.tar.gz` 的 SHA-256 和大小，再检查归档路径、文件类型、重复条目及展开大小，拒绝链接和目录穿越；解压后按 `Gold-bug-tui-files` 校验各入口与 `lib/*.sh` 的摘要、大小和 Shell 语法。压缩包上限为 32 MiB，展开文件合计上限为 64 MiB，单个脚本上限为 8 MiB，归档最多包含 128 个条目。下载期间发布内容发生变化或校验失败时，构建停止并保留原下载目录。下载产物位于 `.build/tui`，不提交到仓库。

native/QEMU 构建入口下载到各自的临时目录，交给 Docker 安装，并在结束后清理。默认使用 GitHub；设置 `DROIDSPACES_TUI_SOURCE=cnb` 可改用 CNB。每次构建查询当前发布；同一 RootFS 仓库提交在不同时间构建时，可能包含不同的 TUI 版本。镜像在 `/usr/local/share/droidspaces-tui/` 保存本次发布清单 `Gold-bug-tui-manifest` 和文件清单 `Gold-bug-tui-files`。离线 `--check` 同时检查两份清单的 revision、库文件以及入口摘要。

校验已经下载的文件：

```bash
bash scripts/sync-tui.sh --output .build/tui --check
```

## 开发检查

在仓库根目录运行语法和静态检查：

```bash
bash -n scripts/sync-tui.sh
bash -n scripts/install-rootfs-tools.sh
bash -n scripts/install-usb-manager.sh
shellcheck scripts/sync-tui.sh
shellcheck scripts/install-rootfs-tools.sh
```

TUI 和 Anland 安装器在 package 仓库直接维护，并运行语法和静态检查。涉及软件包安装和锁定配置的改动，应分别在 APT、DNF 和 Pacman 容器中验证，并重复运行一次检查幂等性。
