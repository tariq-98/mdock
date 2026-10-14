/* libmdock_drm_shim.so: lets libva open a VA display on a stand-in /dev/dri/renderD* node.
 *
 * libva-drm only accepts a file descriptor that libdrm recognises as a DRM node (it checks
 * /sys/dev/char/M:m/device/drm). When the VM has no DRM device, the CDI spec maps a harmless
 * character device (e.g. /dev/null) to /dev/dri/renderD128 and preloads this shim, which answers
 * libdrm's node-type and version queries for such descriptors. Real DRM nodes are passed through.
 *
 * It is linked without libc (-nostdlib) so it has no DT_NEEDED entries and no symbol versions:
 * preloading it is harmless in glibc and musl processes that never touch libdrm. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    int version_major, version_minor, version_patchlevel;
    int name_len;
    char *name;
    int date_len;
    char *date;
    int desc_len;
    char *desc;
} drm_version;

#define DRM_NODE_RENDER 2

static int is_standin(int fd)
{
    char path[64], target[128];
    snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    ssize_t n = readlink(path, target, sizeof(target) - 1);
    if (n <= 0)
        return 0;
    target[n] = 0;
    return strncmp(target, "/dev/dri/renderD", 16) == 0;
}

__attribute__((visibility("default"))) int drmGetNodeTypeFromFd(int fd)
{
    int (*real)(int) = (int (*)(int))dlsym(RTLD_NEXT, "drmGetNodeTypeFromFd");
    int type = real ? real(fd) : -1;
    if (type < 0 && is_standin(fd))
        return DRM_NODE_RENDER;
    return type;
}

static char *dup_str(const char *s, int *len)
{
    *len = (int)strlen(s);
    char *p = malloc(*len + 1);
    if (p)
        memcpy(p, s, *len + 1);
    return p;
}

__attribute__((visibility("default"))) drm_version *drmGetVersion(int fd)
{
    drm_version *(*real)(int) = (drm_version * (*)(int)) dlsym(RTLD_NEXT, "drmGetVersion");
    drm_version *v = real ? real(fd) : NULL;
    if (v || !is_standin(fd))
        return v;
    /* Freed by libdrm's drmFreeVersion(), which free()s each string and the struct. */
    v = calloc(1, sizeof(*v));
    if (!v)
        return NULL;
    v->version_major = 1;
    v->name = dup_str("mdock", &v->name_len);
    v->date = dup_str("20261014", &v->date_len);
    v->desc = dup_str("mdock VideoToolbox bridge", &v->desc_len);
    return v;
}
