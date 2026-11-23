#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>

unsigned int sleep(unsigned int seconds)
{
    unsigned int (*real_sleep)(unsigned int) = dlsym(RTLD_NEXT, "sleep");

    /* triminit 在 mount_storage 失败后等 6 秒。虚拟盘服务已先尝试组盘和激活 LVM，
     * 缩短这段间隔即可让缺失旧卷尽早放行 Web 启动，原有重试和恢复流程照常执行。 */
    if (seconds == 6 && strcmp(program_invocation_short_name, "triminit") == 0 &&
        access("/run/fnos-block-view/disk-map", F_OK) == 0)
        seconds = 1;

    return real_sleep(seconds);
}
