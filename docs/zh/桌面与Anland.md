[文档目录](README.md) · [项目主页](../../README.md)

# 桌面启动与 Anland Wayland

## 桌面自动启动

启用 `desktop_autostart` 后，RootFS 会安装 `desktop-session.service`。它以 UID 1000 的普通用户运行，并读取 `/etc/droidspaces-desktop.conf` 选择会话。

| 桌面与后端 | 手动启动命令 |
| --- | --- |
| KDE + X11（Arch 不支持） | `DISPLAY=:5 startplasma-x11` |
| KDE + Anland Wayland | `startplasma-wayland` |
| KDE Mobile + Anland Wayland | `startplasmamobile` |
| GNOME + Anland Wayland | `gnome-session --session=gnome` |
| Anland Next | `/usr/bin/anland-session` |
| Niri | `/usr/bin/niri-anland` |
| Hyprland | `/usr/bin/hyprland-anland` |
| Mango | `/usr/bin/mango-anland` |
| Denial | `/usr/bin/denial-anland` |

服务在桌面异常退出后等待 2 秒重启；60 秒内连续失败超过 5 次会暂停重试。正常退出不会触发重启。

### X11

X11 桌面使用 `DISPLAY=:5`，需要在 Android 端安装并启动 Termux:X11。若关闭自动启动，可在容器内运行：

```bash
startplasma-x11
```

### Wayland 和 Anland 宿主端配置

Anland Wayland 支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch。Arch KDE 仅使用 Anland Wayland；KDE 使用 patched KWin/Xwayland，GNOME 使用 patched Mutter。GNOME 在这些发行版上安装完整桌面和基础应用。Niri、Hyprland、Mango、Denial 提供轻量会话、终端、XDG portal、音频和字体，用户可自行添加桌面应用。它们的 ARM64 包由 [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) 发布，RootFS 构建时从对应 Release 安装。

轻量 compositor 各自使用独立的 `desktops/<slug>.sh` profile；profile 会将会话与 Anland/Mesa 环境写入 `/etc/environment`。统一桌面启动入口直接运行包提供的 compositor 命令，不使用 `--session`。

在 Android 设备上完成以下准备：

1. 从 [Anland Releases](https://github.com/superturtlee/anland/releases) 下载并安装设备对应的 `virtual-drm-daemon.zip`，按该项目说明刷入并重启设备。
2. 从同一 Release 下载并安装 `app-debug.apk`。
3. 在 Droidspaces 容器设置中开启硬件访问。
4. 为容器启用特权模式，并开启 `nocaps`、`noseccomp`。
5. 按设备策略配置 SELinux；可启用宽容模式，或只允许 Anland 显示服务访问所需的 socket。
6. 在高级选项中添加绑定挂载：

   ```text
   /data/local/tmp/display_daemon.sock -> /run/display.sock
   ```

启动容器并以普通用户登录。KDE 可手动运行 `startplasma-wayland`；KDE Mobile 使用 `startplasmamobile`；GNOME 使用 `gnome-session --session=gnome`。

### 安装或更新 Anland 桌面组件

构建时会自动获取匹配包。若要在已运行的 ARM64 RootFS 中单独安装，可从仓库根目录执行：

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

GNOME 安装器可在 Debian 13、Ubuntu 26、Fedora 43/44 与 Arch Linux ARM 上使用：

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

GNOME 安装器已支持 Debian、Ubuntu、Fedora 和 Arch 的包格式，并从 `anland-gnome-packages` Release 清单读取匹配目标。

安装器选项、下载源和校验方式见[脚本说明](../../scripts/README.md#anland-kde-安装器)。
