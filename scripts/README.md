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
| `tui/droidspaces-tui.sh` | ARM64 Linux 容器 | 提供统一终端菜单，调度 Mesa、Hangover Wine、Wine 字体和 Anland 安装器。 |
| `tui/install-mesa.sh` | ARM64 Linux 容器 | 安装最新版 Android 容器专用 Mesa 和 MediaCodec VA-API 驱动，并锁定 Mesa 包。 |
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
| `install-usb-storage-access.sh` | RootFS 构建环境 | 配置 USB 大容量存储访问：补齐 `/dev` 节点、重新校验介质、exFAT 权限组与 polkit 放行。 |
| `droidspaces-usb-storage-fixup` | Linux 容器的 udev | 为 USB 块设备补建设备节点，并在介质后挂载时重新校验，使 udisks2/Dolphin 能看到文件系统。 |
| `droidspaces-usb-storage-cleanup` | Linux 容器的 udev | 设备拔出时释放容器侧挂载，避免内核块设备一直被占用。 |
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

主菜单包含 Mesa 与 MediaCodec VA-API、Hangover Wine、Wine 字体及当前 RootFS 对应的桌面/会话更新项，只显示黄色“检测到更新”、绿色“当前已是最新版本”或红色“未安装”。桌面/会话项严格解析 `/etc/droidspaces-desktop.conf`：KDE/KDE mobile 只显示 Anland KDE，GNOME 只显示 Anland GNOME，Niri/Hyprland/Mango/Denial 显示匹配的 compositor，Anland Next 只显示其 session；`none` 或未知桌面进入组件选择页。旧 RootFS 缺少配置文件时才按已安装的 Anland 组件兜底，无法判断时同样进入选择页。选择组件后进入版本详情，可更新、安装或卸载。版本查询在后台并发运行，动态 Braille 符号表示正在查询，单项 10 秒内未取得有效版本时显示“超时”，且查询不会阻塞菜单输入。版本检测在启动 TUI 时运行，进入菜单、返回或输入无效内容不会重新检测；安装或卸载实际开始执行后，返回主菜单时会自动刷新一次。输入内容可见并支持退格，Loading 使用原地重绘，避免反复清屏闪烁。卸载 Mesa、KWin、Mutter 或 compositor 补丁会恢复发行版官方包，Hangover Wine 和 Wine 字体则移除自身内容。中文环境默认使用 CNB，其他语言环境默认使用 GitHub；下载源也可以统一改为自动测速、GitHub、`gh-proxy.com` 或 CNB。明确选择 CNB 时，TUI 不查询 GitHub API，安装器从同一 CNB Release 的同步清单取得附件名、SHA-256 和大小；旧发布未提供摘要时会明确提示并保留归档结构与包元数据校验。

主菜单的 `C` 进入缓存管理。可以只清理 Hangover Release 清单缓存，解决滚动 Release 更新后旧清单无法续传的问题；也可以清空 `/var/cache/hangover-wine` 下的全部下载缓存。两项操作都需要确认，清空全部缓存会导致下次安装重新下载软件包。

主菜单的 `U` 进入更新管理，可检查更新、只更新 TUI、只更新受管安装脚本，或更新全部。TUI 会临时获取固定标签 `Gold-bug-tui` 中的一次性安装脚本；GitHub/代理模式使用 GitHub Release API 与发布清单交叉校验，CNB 模式只读取 CNB 的同步清单进行 SHA-256 和大小校验，在替换前备份旧文件，并在操作结束后删除临时脚本。

也可以在启动时指定初始来源：

```bash
droidspaces-tui --source cnb
droidspaces-tui --source github
```

## Mesa 安装器

`install-mesa.sh` 在 GitHub/代理模式从分发 Release 选择当前发行版对应的 ARM64 Mesa 资产；CNB 模式则只读取同一 CNB Release 的 `mesa-distribution-manifest`。随后安装其中同步的 `msm_drm_drv_video.so`。支持 Debian 13、Ubuntu 24.04/25.10/26.04、Fedora 43/44 和 Arch Linux。媒体解码驱动按发行版安装到 libva 的默认驱动目录：Debian/Ubuntu 为 `/usr/lib/aarch64-linux-gnu/dri`，Fedora 为 `/usr/lib64/dri`，Arch Linux 为 `/usr/lib/dri`。

安装器会严格检查 Release tag、资产名和下载内容。GitHub/代理模式保留 GitHub Release API 的 SHA-256 交叉校验；CNB 模式只使用 CNB 分发清单中的 SHA-256 与大小，并继续校验随 Release 同步的媒体驱动 `SHA256SUMS`。下载支持断点续传，临时文件在退出时自动清理。

从仓库根目录交互运行：

```bash
sudo ./scripts/tui/install-mesa.sh
```

未指定参数时，脚本会测试三个下载源并提示选择。也可以直接指定来源，适合无人值守构建：

```bash
sudo ./scripts/tui/install-mesa.sh --1  # GitHub
sudo ./scripts/tui/install-mesa.sh --2  # gh-proxy.com
sudo ./scripts/tui/install-mesa.sh --3  # ghproxy.net
```

三个来源选项互斥，并同时作用于 Mesa 与媒体解码驱动下载。`-1`、`-2`、`-3` 是对应的短参数，`--help` 可查看内置帮助。第三方源仍需访问 `api.github.com` 取得可信元数据，并需要 `jq` 和 `sha256sum`；下载由 `curl` 或 `wget` 完成。

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

Niri、Hyprland、Mango 和 Denial 安装器从各自固定滚动 Release 安装 compositor 与 patched `xorg-xwayland`，支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch ARM64。轻量 RootFS profile 提供终端、XDG portal、音频和字体等基础服务；Niri 在 Arch 上还包含常用桌面工具。各 compositor 共用 patched Xwayland；安装器会阻止互相覆盖，并在卸载时保留其他组件使用的包。

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

## USB 大容量存储访问配置器

`install-usb-storage-access.sh` 在构建阶段自动执行，让桌面用户能真正访问 USB 大容量存储（U 盘、相机机身存储等）。

```bash
sudo ./scripts/install-usb-storage-access.sh --user "$USER"
```

它写入并安装：

- `droidspaces-usb-storage-fixup`、`droidspaces-usb-storage-cleanup` 两个运行时脚本；
- `/etc/udev/rules.d/85-droidspaces-usb-storage.rules`：块设备 `add` 时启动 helper，`remove` 时释放容器侧挂载；
- `/etc/systemd/system/droidspaces-usb-storage-fixup.service`；
- `/etc/polkit-1/rules.d/49-droidspaces-udisks2.rules`：放行本地管理员组挂载可移动介质；
- `external_storage` 组（gid 1077，对齐 Android 的 `AID_EXTERNAL_STORAGE`）并把 `--user` 指定的用户加入。

必须同时解决三件事 Dolphin 才能用：

1. 容器 `/dev` 只包含启动时已存在的节点。启动后出现的块设备使用动态 dev_t（USB 磁盘、`loop16..46` 等），devtmpfs 与 systemd-udevd 都不为它建节点，于是 `/dev/sdX` 根本不存在，任何程序都无法 open、探测或挂载；
2. 相机这类设备先以"无介质"枚举，用户在机身上确认后才把真实存储挂到 gadget 上；而内核只有在该设备被 open 时才重新校验容量（`sd_check_events() → revalidate_disk()`）。节点不存在就永远没人 open，容量一直是 0，udev 探测不到文件系统；
3. Android GKI 的 exFAT 驱动忽略 `uid=`/`gid=`/`umask=`，硬编码 `gid=1077`（`AID_EXTERNAL_STORAGE`）与 `fmask/dmask=0007`，普通用户必须属于该 gid 才能读 exFAT 介质（与 NTFS 侧用 `ntfsusb` gid 1023 是同一类做法）。

`droidspaces-usb-storage-fixup` 只做 `mknod` 建节点和 open 设备读容量，**不写任何文件系统**，轮询带退避、上限 10 分钟；udev 规则只让 `add` 启动 helper（helper 自身会用 `change` 重新触发 udev，否则会无限循环），并在 `remove` 时释放容器侧挂载。

目前只有 `Fedora-44.Dockerfile` 接入（3 行 `COPY` + 1 行 `RUN` + 构建末尾清理项）；其它发行版需要时按同样方式接入即可。

> 安装后需注销重新登录（或重启容器），新组才会进入桌面进程的凭据集合。
>
> **⚠️ 不要点 Android 的"格式化"提示**：宿主 Android 的 `vold` 先 `fsck` 再挂载，而 fsck 要求独占块设备——只要容器侧存在内核对 exFAT 的挂载，vold 的 fsck 就会失败，该卷被标记为 `unmountable`，Android 会弹出指向"格式化"的通知。规则因此保证 **vold 先挂载、容器后挂载**，并在拔出时释放块设备；若该通知仍然出现，请忽略或划掉。

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
