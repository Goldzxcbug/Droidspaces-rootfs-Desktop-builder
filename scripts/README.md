中文 | [English](README_english.md) | [返回项目主页](../README.md)

# scripts 目录说明

本目录存放 RootFS 构建期间使用的安装器、写入 RootFS 的维护工具以及 systemd 服务模板。多数文件由 Dockerfile 或 GitHub Actions 调用；运行前请先确认脚本应在 Linux 容器还是构建环境中执行。

## 文件一览

| 文件 | 运行位置 | 作用 |
| --- | --- | --- |
| `install-desktop.sh`、`desktops/*.sh` | RootFS 构建环境 | 按稳定 slug 分发桌面 profile，并维护软件包集合和桌面专属环境变量。 |
| `configure-desktop.sh` | RootFS 构建环境 | 写入桌面/显示后端配置，调用 profile 环境配置并按需安装统一自启动服务。 |
| `configure-chrome.sh` | RootFS 构建环境 | 在所有支持 Chrome 的镜像中安装 Chrome；Anland Wayland 镜像额外配置硬件加速启动参数和桌面入口。 |
| `start-desktop-session.sh` | Linux 容器 | 根据 `/etc/droidspaces-desktop.conf` 启动实际桌面会话。 |
| `tui/droidspaces-tui.sh` | ARM64 Linux 容器 | 提供 TUI 1.7 终端菜单，调度 Mesa、视频编解码、Anland、Hangover Wine 和 Wine 字体维护。 |
| `tui/droidspaces-video.sh` | Linux 容器 | 以 Bash、awk、jq 只读监控视频驱动会话，不依赖 Python 或常驻服务。 |
| `tui/install-mesa.sh` | ARM64 Linux 容器 | 安装最新版 Android 容器专用 Mesa 和 视频编解码 VA-API 驱动，并锁定 Mesa 包。 |
| `tui/install-hangover-wine.sh` | ARM64 Linux 容器 | 安装当前发行版对应的 Hangover Wine Release 包。 |
| `tui/install-winefonts.sh` | Linux 容器 | 安装 Wine 字体包并刷新 fontconfig 字体缓存。 |
| `tui/install-anland-kde.sh` | ARM64 Linux 容器 | 安装 Anland patched KWin/Xwayland Release 包，并锁定相关包。 |
| `tui/install-anland-gnome.sh` | ARM64 Debian/Ubuntu/Fedora/Arch 容器 | 安装 Anland patched Mutter Release 包，并锁定相关包。 |
| `tui/install-anland-next.sh` | ARM64 Debian/Ubuntu/Fedora/Arch 容器 | 安装 Anland Next session 包（mini-wm + patched Xwayland + patched bubblewrap）。 |
| `tui/install-anland-niri.sh` | ARM64 Debian 13、Ubuntu 26、Fedora 43/44、Arch 容器 | 安装 Anland Niri 与共享的 patched Xwayland 包。 |
| `tui/install-anland-hyprland.sh`、`install-anland-mango.sh`、`install-anland-denial.sh` | ARM64 Debian 13、Ubuntu 26、Fedora 43/44、Arch 容器 | 安装对应 compositor 与 patched Xwayland 包。 |
| `install-anland-desktop.sh` | RootFS 构建环境 | 根据桌面 slug 分发到 KDE、GNOME、Niri、Hyprland、Mango、Denial 或 Anland Next 安装器。 |
| `lib/anland-build.sh` | RootFS 构建宿主 | 为 native/QEMU 构建统一解析 Anland 包族、Release tag 和 revision。 |
| `install-usb-manager.sh` | Linux 容器 | 安装 Droidspaces USB Manager、发行版依赖、菜单入口和用户权限。 |
| `systemd257.sh` | RootFS 构建环境 | 在需要时安装由包管理器管控的 systemd 257 完整包族，供旧 Android 内核使用。 |
| `download-firmware` | Debian/Ubuntu 容器 | 安装并解压 `linux-firmware` 中的 `.zst` 固件。 |
| `nosnap.sh` | Ubuntu RootFS 构建环境 | 移除 Snap、阻止其重新安装，并配置传统 deb 软件源。 |
| `bashrc.sh` | Linux 用户 shell | 提供 Docker 快捷命令、温度查看和 SSH 文件传输等辅助函数。 |
| `start/desktop-session.service` | Linux 容器的 systemd | 通过统一入口自动启动所选桌面会话。 |
| `binfmt/*` | Linux 容器的 systemd/内核 | 检查并挂载 `binfmt_misc`，为 QEMU 跨架构执行做准备。 |

## Droidspaces TUI

构建出的 RootFS 内置 `droidspaces-tui` 命令，并提供较短的 `dstui`、`ds-tui` 别名。它以纯 Bash 提供统一终端菜单，不依赖 `dialog`，可在普通终端或 `adb shell -t` 中运行：

```bash
droidspaces-tui
# 以下两个命令等价
dstui
ds-tui
```

从仓库检出目录运行时使用：

```bash
./scripts/tui/droidspaces-tui.sh
```

TUI 1.7 的主菜单按图形与桌面、Windows 应用和工具分组，依次为 `[1] Mesa + VA-API`、`[2] Anland`、`[3] Hangover Wine` 和 `[4] Wine 字体`。按终端显示宽度对齐中文，适配 60×24、80×24 和 120×30 终端，使用数字/字母快捷键并按 Enter 确认。组件状态用黄色“检测到更新”、绿色“已是最新”或红色“未安装”表示，查询中和失败时另行提示。

桌面/会话项严格解析 `/etc/droidspaces-desktop.conf`：KDE/KDE mobile 只显示 Anland KDE，GNOME 只显示 Anland GNOME，Niri/Hyprland/Mango/Denial 显示匹配的 compositor，Anland Next 只显示其 session；`none` 或未知桌面进入组件选择页。旧 RootFS 缺少配置文件时才按已安装的 Anland 组件兜底，无法判断时同样进入选择页。选择组件后进入版本详情，可更新、安装或卸载。版本查询在后台并发运行，动态 Braille 符号表示正在查询，单项 10 秒内未取得有效版本时显示“超时”，且查询不会阻塞菜单输入。版本检测在启动 TUI 时运行，进入菜单、返回或输入无效内容不会重新检测；安装或卸载实际开始执行后，返回主菜单时会自动刷新一次。输入内容可见并支持退格，Loading 使用原地重绘，避免反复清屏闪烁。卸载 Mesa、KWin、Mutter 或 compositor 补丁会恢复发行版官方包，Hangover Wine 和 Wine 字体则移除自身内容。中文环境默认使用 CNB，其他语言环境默认使用 GitHub；下载源也可以统一改为自动测速、GitHub、`gh-proxy.com` 或 CNB。明确选择 CNB 时，TUI 不查询 GitHub API，安装器从同一 CNB Release 的同步清单取得附件名、SHA-256 和大小；旧发布未提供摘要时会明确提示并保留归档结构与包元数据校验。

Mesa 页的 `[5] 视频编解码` 统一提供视频驱动更新/安装、卸载和实时监控。独立更新和卸载使用 `--media-only`，保留 Mesa 软件包；`[4] 选择 Mesa 版本` 使用 `--mesa-only`，保留视频驱动。视频版本和已安装文件的 SHA-256 独立记录在 `/var/lib/droidspaces-tui/components/video.version`，外部替换驱动后会提示版本未知。更新或卸载驱动后需重启相关应用。

实时监控由 `/usr/local/bin/droidspaces-video.sh` 提供，使用 Bash、awk、jq 和 GNU coreutils/findutils；七个发行版的基础工具集合已经包含这些依赖。监控继承当前用户身份，不自动提权、不启动常驻服务，只读扫描可访问的 `dmd-video-v1` 驱动会话。界面显示方向、视频格式、处理尺寸、输出 FPS 和硬件状态，按应用及 UID 分组；绿色表示驱动已报告硬件工作完成，黄色表示待确认或未知，红色表示错误。可读的 mpv、VLC、OBS 进程即使没有驱动会话也会列出，但不会据此推测软件编解码。

输出 FPS 根据相邻采集的输出帧增量与内核采样时钟计算；首次采集显示 `--`，暂停后显示 0，不等于屏幕播放 FPS。处理尺寸可能包含硬件对齐，例如 1920×1088；监控不会将它改报为源显示尺寸。旧驱动、其他接口或进程权限可能使会话不可见，此时状态为未知。按 `q`、`Esc` 或 `Ctrl+C` 返回视频子菜单；`--no-color` 同时传入监控。独立运行支持 `bash /usr/local/bin/droidspaces-video.sh --once`、`--json` 和 `--interval 秒数`。

构建时直接复制本仓库中的 TUI 和监控脚本；package 仓库的新提交不会自动替换这份副本。已部署 RootFS 可通过 `U` 更新，但更新源必须先发布新的 `Gold-bug-tui` Release。

主菜单的 `C` 进入缓存管理。可以只清理 Hangover Release 清单缓存，解决滚动 Release 更新后旧清单无法续传的问题；也可以清空 `/var/cache/hangover-wine` 下的全部下载缓存。两项操作都需要确认，清空全部缓存会导致下次安装重新下载软件包。

主菜单的 `U` 进入更新管理，可检查更新、只更新 TUI、只更新受管安装脚本，或更新全部。TUI 会临时获取固定标签 `Gold-bug-tui` 中的一次性安装脚本；GitHub/代理模式使用 GitHub Release API 与发布清单交叉校验，CNB 模式只读取 CNB 的同步清单进行 SHA-256 和大小校验，在替换前备份旧文件，并在操作结束后删除临时脚本。

也可以在启动时指定初始来源：

```bash
droidspaces-tui --source cnb
droidspaces-tui --source github
```

## Mesa 安装器

`install-mesa.sh` 在 GitHub/代理模式从分发 Release 选择当前发行版对应的 ARM64 Mesa 资产；CNB 模式则只读取同一 CNB Release 的 `mesa-distribution-manifest`。随后安装其中同步的 `msm_drm_drv_video.so`。支持 Debian 13、Ubuntu 24.04/25.10/26.04、Fedora 43/44 和 Arch Linux。视频编解码驱动按发行版安装到 libva 的默认驱动目录：Debian/Ubuntu 为 `/usr/lib/aarch64-linux-gnu/dri`，Fedora 为 `/usr/lib64/dri`，Arch Linux 为 `/usr/lib/dri`。

安装器会严格检查 Release tag、资产名和下载内容。GitHub/代理模式保留 GitHub Release API 的 SHA-256 交叉校验；CNB 模式只使用 CNB 分发清单中的 SHA-256 与大小，并继续校验随 Release 同步的媒体驱动 `SHA256SUMS`。下载支持断点续传，临时文件在退出时自动清理。

从仓库根目录交互运行：

```bash
sudo ./scripts/tui/install-mesa.sh
```

未指定参数时，脚本会测试三个下载源并提示选择。也可以直接指定来源，适合无人值守构建：

```bash
sudo ./scripts/tui/install-mesa.sh --1  # GitHub
sudo ./scripts/tui/install-mesa.sh --2  # gh-proxy.com
sudo ./scripts/tui/install-mesa.sh --3  # CNB
```

三个来源选项互斥，并同时作用于 Mesa 与视频编解码驱动下载。`-1`、`-2`、`-3` 是对应的短参数，`--help` 可查看内置帮助。GitHub/代理模式通过 GitHub Release API 交叉校验；CNB 模式只读取 CNB 分发清单。下载与摘要校验由安装器完成。

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

桌面翻译文件由各 Dockerfile 在安装软件包前全局放开：Fedora 写入 `%_install_langs all`，Debian/Ubuntu 取消 dpkg 的 locale `path-exclude`，Arch 移除 `NoExtract`。profile 不再需要重复处理语言文件。

七个 Dockerfile 和核心工作流已经使用通用 profile 接口，普通 X11 桌面无需复制 Dockerfile。依赖 patched Wayland 包的 profile 还需在 `lib/anland-build.sh` 的 `anland_package_family` 中登记包族。

## Anland KDE 安装器

`install-anland-kde.sh` 默认从 `Goldzxcbug/droidspaces-package` 的固定滚动 Release `anland-kde-packages` 读取 `anland-kde-manifest`，为 Debian 13、Ubuntu 26.04、Fedora 43/44 或 Arch Linux ARM64 安装匹配版本的 patched KWin/Xwayland 包。

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

它同样支持 `--1`、`--2`、`--3` 选择 GitHub、`gh-proxy.com` 或 `ghproxy.net`；省略时测速后交互选择。镜像下载的清单与归档均使用 GitHub API digest 校验。脚本按系统 locale 输出中文或英文，并通过 APT hold、DNF exclude 或 Pacman `IgnorePkg` 防止系统更新覆盖安装结果。

安装公开 Fork 发布的包时只需覆盖仓库；Fork 必须提供固定标签 `anland-kde-packages`：

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  ./scripts/tui/install-anland-kde.sh --1
```

Anland 宿主模块、App、SELinux、绑定挂载和 Droidspaces 权限仍需按[Wayland 与 Anland 配置教程](../docs/zh/桌面与Anland.md#wayland-和-anland-宿主端配置)完成。

## Anland GNOME 安装器

`install-anland-gnome.sh` 默认从固定滚动 Release `anland-gnome-packages` 读取 `anland-gnome-manifest`，为 Debian 13、Ubuntu 26.04 或 Arch Linux ARM64 安装 patched Mutter 运行时包。Arch 只安装 `mutter` 运行包，并通过 pacman `IgnorePkg` 防止升级覆盖；Debian/Ubuntu 使用 APT hold。GNOME 的各发行版软件包均由 `droidspaces-package` 发布，RootFS 构建与后续更新都通过 Release 清单获取对应归档。下载源选择、镜像 digest 校验和命令行参数与 KDE 安装器一致。

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

使用公开 Fork 的包时同时覆盖 GNOME 仓库变量：

```bash
sudo ANLAND_RELEASE_REPOSITORY=owner/repository \
  ./scripts/tui/install-anland-gnome.sh --1
```

## Anland Next 安装器

`install-anland-next.sh` 默认从固定滚动 Release `anland-session-packages` 读取 `anland-session-manifest`，为 Debian 13、Ubuntu 26.04、Fedora 43/44 或 Arch Linux ARM64 安装 `anland-session` 包。下载源选择、镜像 digest 校验和命令行参数与 KDE 安装器一致。

```bash
sudo ./scripts/tui/install-anland-next.sh
```

包内是三个预编译产物：`anland-miniwm`，以及打过 kgsl/turnip glamor 补丁的 Xwayland 与打过 mountinfo 索引补丁的 bubblewrap。后两者装在 `/usr/lib/anland/`，由会话把它前置到 PATH，发行版的同名二进制不会被覆盖，因此**不需要**像 KDE/GNOME 那样做软件包锁定 —— 这个包不替换任何发行版文件。

会话本体是包内的 `/usr/bin/anland-session`（会话 D-Bus + wayland 链接 + rootless Xwayland + mini-wm），配合 `/usr/lib/systemd/user/anland-session.service` 使用，不往用户家目录写任何东西。

Anland Next profile 默认让 Qt 6 应用使用原生 Wayland，并显式安装对应平台插件；直接通过终端启动时，用户 shell 会读取运行中的 `~/.anlandx-env`。

使用公开 Fork 的包时覆盖仓库变量：

```bash
sudo ANLAND_NEXT_RELEASE_REPOSITORY=owner/repository \
  ./scripts/tui/install-anland-next.sh --1
```

## Anland Niri 安装器

Niri、Hyprland、Mango 和 Denial 安装器从各自固定滚动 Release 安装 compositor 与 patched `xorg-xwayland`，支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch ARM64。四个桌面在 `scripts/desktops/<slug>.sh` 各有独立 profile；profile 提供终端、XDG portal、音频和字体等基础服务，Niri 在 Arch 上还包含常用桌面工具。各 compositor 共用 patched Xwayland；安装器会阻止互相覆盖，并在卸载时保留其他组件使用的包。

```bash
sudo ./scripts/tui/install-anland-niri.sh
```

## USB Manager 安装器

`install-usb-manager.sh` 支持 Debian/Ubuntu、Fedora 和 Arch，自动安装 PyQt5、ADB、udev、NTFS、exFAT 等依赖，并安装 `usb-manager`、`usb-passthrough` 和 `usb-storage-passthrough` 命令。

```bash
sudo ./scripts/install-usb-manager.sh --user "$USER"
```

`--user USER` 指定获得 USB 管理权限和桌面入口的用户。省略时依次尝试 `SUDO_USER`、当前登录用户和第一个普通用户。开发或离线测试可以通过 `--source DIR` 使用本地 Droidspaces-USB-Manager 源码目录；运行 `--help` 查看完整参数。

在普通 Arch 系统上，安装器会照常安装 `systemd` 和其他依赖。若检测到 `/etc/droidspaces-systemd257`，重复运行时会保留 Pacman 的 `IgnorePkg` 锁定，不再把 `systemd` 作为显式安装目标；PyQt5、ADB、NTFS、exFAT 等 USB Manager 依赖仍会正常补齐。

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

## 开发检查

修改 shell 脚本后，至少运行语法检查；安装了 ShellCheck 时也应执行静态检查：

```bash
bash -n scripts/tui/install-mesa.sh
bash -n scripts/tui/droidspaces-tui.sh
bash -n scripts/tui/install-anland-kde.sh
bash -n scripts/tui/install-anland-gnome.sh
bash -n scripts/tui/install-anland-next.sh
bash -n scripts/install-usb-manager.sh
shellcheck scripts/tui/install-mesa.sh
shellcheck scripts/tui/droidspaces-tui.sh
```

涉及软件包安装和锁定配置的改动，还应分别在 APT、DNF 和 Pacman 容器中验证，并重复运行一次检查幂等性。
