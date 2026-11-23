// fakecompat.c
#define _GNU_SOURCE
#include <stdarg.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>

#define TARGET "/proc/device-tree/compatible"
/* 真实 DTB 里 compatible 是 "vendor,board\0soc\0" 这种 NUL 分隔序列 */
static const char FAKE[] = "mediatek,MT6833\0";

/* 把一个内存 buffer 落成一个只读临时文件，返回路径 */
static const char *fake_path(void) {
    static char path[64];
    static int inited = 0;
    if (inited) return path;
    snprintf(path, sizeof(path), "/tmp/.fake_compat_%d", getpid());
    int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0400);
    if (fd >= 0) {
        write(fd, FAKE, sizeof(FAKE));  /* 含结尾 NUL */
        close(fd);
    }
    inited = 1;
    return path;
}

static int is_target(const char *p) {
    return p && strcmp(p, TARGET) == 0;
}

int open(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    if (!real) real = dlsym(RTLD_NEXT, "open");
    if (is_target(path)) path = fake_path();
    return real(path, flags, mode);
}

int open64(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    if (!real) real = dlsym(RTLD_NEXT, "open64");
    if (is_target(path)) path = fake_path();
    return real(path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
    static int (*real)(int, const char *, int, ...);
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    if (!real) real = dlsym(RTLD_NEXT, "openat");
    if (is_target(path)) path = fake_path();
    return real(dirfd, path, flags, mode);
}

FILE *fopen(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen");
    if (is_target(path)) path = fake_path();
    return real(path, mode);
}

FILE *fopen64(const char *path, const char *mode) {
    static FILE *(*real)(const char *, const char *);
    if (!real) real = dlsym(RTLD_NEXT, "fopen64");
    if (is_target(path)) path = fake_path();
    return real(path, mode);
}

/* stat 也要伪造，否则程序先 stat 判断存在性会直接失败 */
#include <sys/stat.h>
int stat(const char *path, struct stat *buf) {
    static int (*real)(const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "stat");
    if (is_target(path)) path = fake_path();
    return real(path, buf);
}