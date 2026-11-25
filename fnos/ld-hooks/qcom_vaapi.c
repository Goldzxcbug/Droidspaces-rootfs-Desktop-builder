#define _GNU_SOURCE
/*
 * qcom_vaapi.c — 让飞牛 mediasrv 在高通 Droidspaces 容器中走 VA-API 硬解/硬编
 *                + Adreno Turnip Vulkan 零拷贝缩放（含 HDR 色调映射）
 *
 * 原理：
 * 1. 拦截 v4l2_open() 返回 ENOENT，阻止 mediasrv 抢占不支持 V4L2_MEMORY_MMAP 的
 *    Generic V4L2 (/dev/video32, /dev/video33)；msm_drm_drv_video.so 走原生 open()，
 *    完全不受影响。
 * 2. 拦截对 /sys/class/drm/renderDN/device/uevent 的读取，返回 DRIVER=ftd330，
 *    引导 mediasrv 启用内置的 VA-API + Vulkan 管线（配合 ftd330_drv_video.so ->
 *    msm_drm_drv_video.so 与 d3000m_icd.json -> freedreno_icd.aarch64.json）。
 * 3. 拦截 avfilter_graph_parse_ptr()：
 *    - 保留 VA-API -> Vulkan 零拷贝 hwmap 与 scale_vulkan（含 GPU tonemap）；
 *    - 若 setparams=... 位于 hwmap=derive_device=vulkan 之前，将其挪到 hwmap 之后，
 *      防止 hwmap 丢失 BT.2020/PQ 色域元数据；
 *    - 仅将末尾尚不支持外部 dmabuf 导入的反向 hwmap=derive_device=vaapi...,format=vaapi
 *      替换为 hwdownload,format=nv12,hwupload_vaapi。
 * 4. 拦截对 /.phytium-transcode.lock 的打开，为每个会话返回独立 memfd，
 *    解除飞腾单路硬件转码并发锁，允许高通多路硬件转码并行。
 */
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int is_render_uevent(const char *path)
{
	return path && strstr(path, "/sys/class/drm/renderD") != NULL &&
	       strstr(path, "/device/uevent") != NULL;
}

static int is_phytium_lock(const char *path)
{
	return path && strstr(path, "/.phytium-transcode.lock") != NULL;
}

static int open_independent_lock_fd(void)
{
	int fd = memfd_create("qcom-transcode-lock", MFD_CLOEXEC);
	if (fd >= 0)
		return fd;
	return -1;
}

static const char *fake_uevent_path(void)
{
	static const char *p = "/tmp/.fnos_qcom_render_uevent";
	int fd = open(p, O_CREAT | O_WRONLY | O_TRUNC, 0644);
	if (fd >= 0) {
		const char *s = "DRIVER=ftd330\n";
		(void)write(fd, s, strlen(s));
		close(fd);
	}
	return p;
}

int v4l2_open(const char *file, int oflag, ...)
{
	(void)file;
	(void)oflag;
	errno = ENOENT;
	return -1;
}

int open(const char *pathname, int flags, ...)
{
	static int (*real_open)(const char *, int, ...) = NULL;
	if (!real_open)
		real_open = dlsym(RTLD_NEXT, "open");
	mode_t mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	if (is_render_uevent(pathname))
		return real_open(fake_uevent_path(), O_RDONLY);
	if (is_phytium_lock(pathname)) {
		int fd = open_independent_lock_fd();
		if (fd >= 0)
			return fd;
	}
	return (flags & O_CREAT) ? real_open(pathname, flags, mode)
				 : real_open(pathname, flags);
}

int open64(const char *pathname, int flags, ...)
{
	static int (*real_open64)(const char *, int, ...) = NULL;
	if (!real_open64)
		real_open64 = dlsym(RTLD_NEXT, "open64");
	mode_t mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	if (is_render_uevent(pathname))
		return real_open64(fake_uevent_path(), O_RDONLY);
	if (is_phytium_lock(pathname)) {
		int fd = open_independent_lock_fd();
		if (fd >= 0)
			return fd;
	}
	return (flags & O_CREAT) ? real_open64(pathname, flags, mode)
				 : real_open64(pathname, flags);
}

int openat(int dirfd, const char *pathname, int flags, ...)
{
	static int (*real_openat)(int, const char *, int, ...) = NULL;
	if (!real_openat)
		real_openat = dlsym(RTLD_NEXT, "openat");
	mode_t mode = 0;
	if (flags & O_CREAT) {
		va_list ap;
		va_start(ap, flags);
		mode = (mode_t)va_arg(ap, int);
		va_end(ap);
	}
	if (is_render_uevent(pathname))
		return real_openat(AT_FDCWD, fake_uevent_path(), O_RDONLY);
	if (is_phytium_lock(pathname)) {
		int fd = open_independent_lock_fd();
		if (fd >= 0)
			return fd;
	}
	return (flags & O_CREAT) ? real_openat(dirfd, pathname, flags, mode)
				 : real_openat(dirfd, pathname, flags);
}

FILE *fopen(const char *pathname, const char *mode)
{
	static FILE *(*real_fopen)(const char *, const char *) = NULL;
	if (!real_fopen)
		real_fopen = dlsym(RTLD_NEXT, "fopen");
	if (is_render_uevent(pathname))
		return real_fopen(fake_uevent_path(), "r");
	return real_fopen(pathname, mode);
}

FILE *fopen64(const char *pathname, const char *mode)
{
	static FILE *(*real_fopen64)(const char *, const char *) = NULL;
	if (!real_fopen64)
		real_fopen64 = dlsym(RTLD_NEXT, "fopen64");
	if (is_render_uevent(pathname))
		return real_fopen64(fake_uevent_path(), "r");
	return real_fopen64(pathname, mode);
}

static int rewrite_vulkan_vfilter(const char *filters, char *out, size_t out_sz)
{
	const char *hwmap_va = strstr(filters, "hwmap=derive_device=vaapi");
	if (!hwmap_va)
		return 0;

	const char *va_end = strstr(hwmap_va, "format=vaapi");
	if (va_end) {
		va_end += strlen("format=vaapi");
	} else {
		va_end = strchr(hwmap_va, ',');
		if (!va_end)
			va_end = hwmap_va + strlen(hwmap_va);
	}

	char tmp[2048];
	size_t head_len = (size_t)(hwmap_va - filters);
	int n = snprintf(tmp, sizeof(tmp),
			 "%.*shwdownload,format=nv12,hwupload_vaapi%s",
			 (int)head_len, filters, va_end);
	if (n <= 0 || (size_t)n >= sizeof(tmp))
		return 0;

	const char *hwmap_vk = strstr(tmp, ",hwmap=derive_device=vulkan");
	if (strncmp(tmp, "setparams=", 10) == 0 && hwmap_vk) {
		const char *vk_end = strchr(hwmap_vk + 1, ',');
		if (vk_end) {
			size_t setp_len = (size_t)(hwmap_vk - tmp);
			size_t vk_len = (size_t)(vk_end - (hwmap_vk + 1));
			n = snprintf(out, out_sz, "%.*s,%.*s%s",
				     (int)vk_len, hwmap_vk + 1,
				     (int)setp_len, tmp,
				     vk_end);
			return (n > 0 && (size_t)n < out_sz);
		}
	}

	if (strlen(tmp) >= out_sz)
		return 0;
	strcpy(out, tmp);
	return 1;
}

int avfilter_graph_parse_ptr(void *graph, const char *filters,
			     void *inputs, void *outputs, void *log_ctx)
{
	static int (*real_fn)(void *, const char *, void *, void *, void *) = NULL;
	if (!real_fn)
		real_fn = dlsym(RTLD_NEXT, "avfilter_graph_parse_ptr");
	if (filters) {
		char buf[2048];
		if (rewrite_vulkan_vfilter(filters, buf, sizeof(buf)))
			return real_fn(graph, buf, inputs, outputs, log_ctx);
	}
	return real_fn(graph, filters, inputs, outputs, log_ctx);
}
