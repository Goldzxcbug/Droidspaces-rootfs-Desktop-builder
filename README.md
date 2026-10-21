中文 | [English](README_english.md)

# Droidspaces RootFS 自动构建

通过 GitHub Actions 为 Android 上的 Droidspaces 构建 Debian、Ubuntu、Fedora 或 Arch Linux ARM64 RootFS。可选择 KDE、KDE Mobile、GNOME、Anland Next、Niri、Hyprland、Mango、Denial 或纯命令行环境，再下载 `.tar.xz` 导入 Droidspaces。

![Debian 13 KDE 桌面运行于 Anland Wayland](docs/images/debian-kde-wayland.jpg)

**快速开始：** Fork 仓库 → 打开 `Actions` → 运行“编译并发布 Droidspaces RootFS” → 从 `Releases` 下载 RootFS。

固定全桌面订阅源：在 Droidspaces 的 RootFS 仓库管理中添加 [中文 RootFS（GitHub）](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder/releases/download/droidspaces-rootfs-all-wayland/rootfs_zh.json)、[中文 RootFS（CNB）](https://cnb.cool/goldzxcbug/droidspaces-package/-/releases/download/droidspaces-rootfs-all-wayland/rootfs_zh.json) 或 [English RootFS（GitHub）](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder/releases/download/droidspaces-rootfs-all-wayland/rootfs_en.json)。

## 项目内容

- 七种发行版构建目标，支持 X11 与 Anland Wayland（依桌面和发行版而定）。
- 可选中文环境、Fcitx5、Snapdragon GPU 支持、音频转发、开发工具和 Docker。
- RootFS 自动发布到 GitHub Releases；容器内提供桌面会话、USB 管理与维护工具。

## 文档

- [文档目录与桌面截图](docs/zh/README.md)
- [从 Actions 构建并导入 Droidspaces](docs/zh/快速开始.md)
- [发行版兼容性与构建选项](docs/zh/构建选项.md)
- [桌面启动与 Anland Wayland 配置](docs/zh/桌面与Anland.md)
- [TUI、USB、固件与本地构建](docs/zh/进阶使用.md)
- [脚本维护说明](scripts/README.md)

## 支持范围

构建目标：`Debian-13`、`Ubuntu-24`、`Ubuntu-25`、`Ubuntu-26`、`Fedora-43`、`Fedora-44`、`Arch`。GNOME、Niri、Hyprland、Mango 和 Denial 支持 Debian 13、Ubuntu 26、Fedora 43/44 与 Arch Linux ARM。桌面及显示后端的完整兼容矩阵见[构建选项](docs/zh/构建选项.md)。

## 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/)：提供项目运行环境基础。
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)：提供 Snapdragon GPU 驱动支持。
- [droidspaces-media-decode](https://github.com/Re-s/droidspaces-media-decode)：提供 Android MediaCodec 容器硬件解码支持。
- [Anland](https://github.com/superturtlee/anland)：提供 Wayland 显示后端及相关工作。
- [Droidspaces USB Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager)：提供 USB 存储和 ADB 设备管理工具。
- [ObsidianArc](https://github.com/OnyxAxisOwO/ObsidianArc)：自托管多模型聊天网关，感谢他们提供公益 AI 服务。

---

[所有桌面截图](docs/zh/README.md#桌面截图) · [English README](README_english.md)
