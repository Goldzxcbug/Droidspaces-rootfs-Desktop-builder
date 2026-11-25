# Droidspaces fnOS RootFS Builder

本分支为 **fnOS（飞牛 NAS ARM64）** 独立构建分支，用于在 Android Droidspaces 容器环境中构建并运行 fnOS。

## 核心特性

- **官方 ARM64 镜像提取**：自动从飞牛官方 ARM ISO 提取 `trimfs.tgz`（基于 Debian 12 / bookworm）。
- **虚拟盘与 RAID/LVM 存储支持**：
  - 自动发现 `/mnt/fn-*.img`（兼容 `/mnt/sd.img`）并映射为 `/sys/block/sd*` 合成视图；
  - `mdadm` 包装器兼容 `--bitmap=internal` 及 `--create`/`--assemble` 合成视图隔离；
  - `fnos-md-alias.sh` 动态同步所有 `md*`（含 `md127` 等自动组装编号）及 LVM `dm-*` 视图。
- **主线 / Android 内核兼容层（`fnos/ld-hooks/`）**：
  - `fnacl_faccessat_hook.so`（通过 `/etc/ld.so.preload` 全局注入）：兼容飞牛私有 `faccessat`/`syscall` 伪 `dirfd`（含 `trim_get_perm` `-21579`、`is_mountpoint` `-21581`）与 `system.trim_*` xattr，覆盖系统服务及应用中心安装的所有官方/社区 App；
  - `qcom_vaapi.so`：移除飞牛原版 `ftg340` 全局库劫持，在高通设备上引导 `mediasrv` 走 VA-API 硬解/硬编（`msm_drm_drv_video.so`）+ Adreno Turnip Vulkan 零拷贝缩放（含 HDR 色调映射），并解除单路硬件转码并发锁；
  - `network_veth.so`、`triminit_wait.so`、`fnos-appcenter-perm` 等容器运行时适配。
- **网络与硬件识别**：与 Droidspaces 统一配置保持一致，支持 NAT/Gateway 自动 DHCP（`fnos-nat-dhcp.service` 兜底）及 `enable_hw_access=1` 按需启用 `udev`。

## 本地构建

```bash
# ARM64 原生环境
./build_rootfs-native.sh -i fnOS.Dockerfile -K none -m -b

# x86_64 主机（QEMU aarch64）
./build_rootfs-qemu-aarch64.sh -i fnOS.Dockerfile -K none -m -b
```

## GitHub Actions 构建

在 Actions 中运行 **「编译并发布 Droidspaces fnOS RootFS」**（或英文版 **Build and Release Droidspaces fnOS RootFS**），按需选择：
- `enable_zh_tz`：中文与上海时区
- `enable_mesa`：高通骁龙 GPU 与 VA-API 硬件编解码支持
- `enable_yj`：NAT 网络与硬件识别

## 目录结构

- `fnOS.Dockerfile`：fnOS rootfs 多阶段构建文件
- `fnos/`：fnOS 专属 LD_PRELOAD 拦截库、包装器、systemd 单元与运行时自愈脚本
- `scripts/`：Droidspaces 构建与工具同步脚本
- `build_rootfs-native.sh` / `build_rootfs-qemu-aarch64.sh`：本地构建入口
- `.github/workflows/`：fnOS 构建与发布工作流
