#include "utun.h"

#include <string.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

// The iOS SDK does not ship <sys/kern_control.h>; these mirror the kernel ABI.
#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#endif
#define YGG_CTLIOCGINFO 0xc0644e03UL /* _IOWR('N', 3, struct ctl_info) */

struct ygg_ctl_info {
    uint32_t ctl_id;
    char ctl_name[96];
};

struct ygg_sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};

int ygg_find_utun_fd(void) {
    struct ygg_ctl_info info;
    memset(&info, 0, sizeof info);
    strncpy(info.ctl_name, "com.apple.net.utun_control", sizeof(info.ctl_name) - 1);

    for (int fd = 0; fd <= 1024; fd++) {
        struct ygg_sockaddr_ctl addr;
        socklen_t len = sizeof addr;
        memset(&addr, 0, sizeof addr);
        if (getpeername(fd, (struct sockaddr *)&addr, &len) != 0 || addr.sc_family != AF_SYSTEM) {
            continue;
        }
        if (info.ctl_id == 0 && ioctl(fd, YGG_CTLIOCGINFO, &info) != 0) {
            continue;
        }
        if (addr.sc_id == info.ctl_id) {
            return fd;
        }
    }
    return -1;
}
