#!/bin/bash
# 编译飞牛软解媒体服务的 LD_PRELOAD 拦截库
#
# 三个 hook：
#   nodri.so       —— 屏蔽 /dev/dri（我们没有 DRI/GPU 渲染节点）
#   nodmaheap.so   —— 屏蔽 /dev/dma_heap（MT6771 无 dma-buf heap）
#   fakecompat.so  —— 伪造 /proc/device-tree/compatible（可选，软解方案一般不用）
#   fnacl_faccessat_hook.so —— 兼容飞牛私有 syscall：伪 dirfd(-21586) + struct 指针的 faccessat
#
# 关于 fakecompat：
#   原项目用它把 SoC 伪装成 rk3588 让 MPP 硬件编解码初始化。
#   但在 MT6771 上伪装成 RK 设备会让 MPP 真的去调用不存在的 VPU，
#   导致不稳定。我们的方案是换成软解版 mediasrv（见 build-rootfs-fnnas.sh），
#   根本不走 MPP，所以 fakecompat 默认不注入，只作为可选保留。
#
# 用法：
#   bash build-hooks.sh [aarch64-linux-gnu-gcc]
set -e

CC="${1:-aarch64-linux-gnu-gcc}"
cd "$(dirname "$0")"

echo "=== 编译器: $CC ==="
$CC --version | head -1

for src in nodri nodmaheap fakecompat fnacl_faccessat_hook; do
    echo "=== 编译 $src.so ==="
    $CC -shared -fPIC -O2 -o "${src}.so" "${src}.c" -ldl
done

echo "=== 结果 ==="
ls -lh *.so

echo "=== 架构确认（必须 AArch64）==="
for so in *.so; do
    printf "  %-18s " "$so"
    readelf -h "$so" 2>/dev/null | grep Machine || echo "(读不到)"
done
