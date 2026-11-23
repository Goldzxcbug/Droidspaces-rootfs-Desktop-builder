// nodri.c —— 让本进程"看不到 /dev/dri"，把针对 /dev/dri 的存在性检查伪造成 ENOENT。
// 效果等价于 mediasrv 运行在一台没有 DRM 的机器上（如能正常跑的 mt6771），
// 从而跳过它 "有 GPU -> 用 libpci 枚举 PCI" 的分支，直接回退 CPU 转码。
// 仅作用于被 LD_PRELOAD 的这个进程，不改动全局 /dev。
#define _GNU_SOURCE
#include <stdarg.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#define HIDDEN "/dev/dri"

static int is_hidden(const char *p) {
    return p && strcmp(p, HIDDEN) == 0;
}

/* 把 pathname 解析成绝对路径用于比较（mediasrv 传的是绝对 "/dev/dri"） */
static int hidden_at(int dirfd, const char *path) {
    if (!path) return 0;
    if (path[0] == '/') return is_hidden(path);
    /* 相对路径且 dirfd 指向 /dev 的情形极少，这里保守再判一次 */
    return is_hidden(path);
}

int faccessat(int dirfd, const char *path, int mode, int flags) {
    static int (*real)(int, const char *, int, int);
    if (!real) real = dlsym(RTLD_NEXT, "faccessat");
    if (hidden_at(dirfd, path)) { errno = ENOENT; return -1; }
    return real(dirfd, path, mode, flags);
}

int faccessat2(int dirfd, const char *path, int mode, int flags) {
    static int (*real)(int, const char *, int, int);
    if (!real) real = dlsym(RTLD_NEXT, "faccessat2");
    if (hidden_at(dirfd, path)) { errno = ENOENT; return -1; }
    return real ? real(dirfd, path, mode, flags) : faccessat(dirfd, path, mode, flags);
}

int access(const char *path, int mode) {
    static int (*real)(const char *, int);
    if (!real) real = dlsym(RTLD_NEXT, "access");
    if (hidden_at(AT_FDCWD, path)) { errno = ENOENT; return -1; }
    return real(path, mode);
}

int stat(const char *path, struct stat *buf) {
    static int (*real)(const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "stat");
    if (is_hidden(path)) { errno = ENOENT; return -1; }
    return real(path, buf);
}

int lstat(const char *path, struct stat *buf) {
    static int (*real)(const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "lstat");
    if (is_hidden(path)) { errno = ENOENT; return -1; }
    return real(path, buf);
}

int __xstat(int ver, const char *path, struct stat *buf) {
    static int (*real)(int, const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "__xstat");
    if (is_hidden(path)) { errno = ENOENT; return -1; }
    return real ? real(ver, path, buf) : stat(path, buf);
}

int __lxstat(int ver, const char *path, struct stat *buf) {
    static int (*real)(int, const char *, struct stat *);
    if (!real) real = dlsym(RTLD_NEXT, "__lxstat");
    if (is_hidden(path)) { errno = ENOENT; return -1; }
    return real ? real(ver, path, buf) : lstat(path, buf);
}

int fstatat(int dirfd, const char *path, struct stat *buf, int flags) {
    static int (*real)(int, const char *, struct stat *, int);
    if (!real) real = dlsym(RTLD_NEXT, "fstatat");
    if (hidden_at(dirfd, path)) { errno = ENOENT; return -1; }
    return real(dirfd, path, buf, flags);
}

int open(const char *path, int flags, ...) {
    static int (*real)(const char *, int, ...);
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    if (!real) real = dlsym(RTLD_NEXT, "open");
    if (is_hidden(path)) { errno = ENOENT; return -1; }
    return real(path, flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...) {
    static int (*real)(int, const char *, int, ...);
    mode_t mode = 0;
    if (flags & (O_CREAT | O_TMPFILE)) {
        va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap);
    }
    if (!real) real = dlsym(RTLD_NEXT, "openat");
    if (is_hidden(path)) { errno = ENOENT; return -1; }
    return real(dirfd, path, flags, mode);
}
