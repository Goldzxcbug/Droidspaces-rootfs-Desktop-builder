#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* libnm 的公开 ABI。构建机无需安装 arm64 版 libnm 开发包。 */
typedef struct _NMDevice NMDevice;
enum {
    NM_DEVICE_TYPE_UNKNOWN = 0,
    NM_DEVICE_TYPE_ETHERNET = 1,
    NM_DEVICE_TYPE_VETH = 20,
};

static pthread_once_t init_once = PTHREAD_ONCE_INIT;
static unsigned int (*real_get_type)(NMDevice *);
static const char *(*real_get_iface)(NMDevice *);
static int (*real_is_software)(NMDevice *);
static bool nat_mode;

static void init_libnm(void)
{
    real_get_type = dlsym(RTLD_NEXT, "nm_device_get_device_type");
    real_get_iface = dlsym(RTLD_NEXT, "nm_device_get_iface");
    real_is_software = dlsym(RTLD_NEXT, "nm_device_is_software");

    /* 子进程也会继承 LD_PRELOAD，只有飞牛网络服务需要转换。 */
    if (strcmp(program_invocation_short_name, "network_service") != 0)
        return;

    FILE *config = fopen("/run/droidspaces/container.config", "r");
    if (!config)
        return;

    char *line = NULL;
    size_t capacity = 0;
    while (getline(&line, &capacity, config) >= 0) {
        line[strcspn(line, "\r\n")] = '\0';
        if (strncmp(line, "net_mode=", sizeof("net_mode=") - 1) == 0) {
            nat_mode = strcmp(line, "net_mode=nat") == 0;
            break;
        }
    }
    free(line);
    fclose(config);
}

static bool is_nat_eth0(NMDevice *device, unsigned int type)
{
    if (!nat_mode || type != NM_DEVICE_TYPE_VETH || !real_get_iface)
        return false;

    const char *name = real_get_iface(device);
    return name && strcmp(name, "eth0") == 0;
}

unsigned int nm_device_get_device_type(NMDevice *device)
{
    pthread_once(&init_once, init_libnm);
    if (!real_get_type)
        return NM_DEVICE_TYPE_UNKNOWN;

    unsigned int type = real_get_type(device);
    return is_nat_eth0(device, type) ? NM_DEVICE_TYPE_ETHERNET : type;
}

int nm_device_is_software(NMDevice *device)
{
    pthread_once(&init_once, init_libnm);
    if (!real_is_software)
        return 0;

    /* 飞牛会再次过滤软件以太网设备，NAT 的 eth0 也需要通过这一步。 */
    if (nat_mode && real_get_type && is_nat_eth0(device, real_get_type(device)))
        return 0;

    return real_is_software(device);
}
