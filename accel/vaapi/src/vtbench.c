/* vtbench: measures mdock-vt transport throughput (download via VT_BENCH replies, upload via
 * VT_BENCH request payloads) over the same connection path the driver uses. */
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "rpc.h"

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
    size_t size = argc > 1 ? strtoul(argv[1], NULL, 0) : 12441600;   /* 4K NV12 */
    int iters = argc > 2 ? atoi(argv[2]) : 50;
    vt_rpc rpc;
    if (vt_connect(&rpc) < 0) {
        fprintf(stderr, "connect failed\n");
        return 1;
    }
    char *buf = calloc(1, size + 4);
    uint32_t n = 0;
    struct iovec req = { &n, 4 }, rep = { buf, size };
    double t = now();
    for (int i = 0; i < iters; i++)
        if (vt_call(&rpc, VT_BENCH, &req, 1, &rep, 1, NULL)) return 1;
    double rtt = (now() - t) / iters;

    n = (uint32_t)size;
    t = now();
    for (int i = 0; i < iters; i++)
        if (vt_call(&rpc, VT_BENCH, &req, 1, &rep, 1, NULL)) return 1;
    double down = (now() - t) / iters;

    n = 0;
    struct iovec up[2] = { { &n, 4 }, { buf, size } };
    t = now();
    for (int i = 0; i < iters; i++)
        if (vt_call(&rpc, VT_BENCH, up, 2, NULL, 0, NULL)) return 1;
    double upt = (now() - t) / iters;
    printf("%s: rtt %.3f ms, %zu B down %.1f MB/s (%.2f ms), up %.1f MB/s (%.2f ms)\n", rpc.endpoint, rtt * 1e3, size,
           size / down / 1e6, down * 1e3, size / upt / 1e6, upt * 1e3);
    return 0;
}
