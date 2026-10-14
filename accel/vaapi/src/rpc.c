#include "rpc.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define VA_STATUS_ERROR_OPERATION_FAILED 0x00000001

static void tune(int fd, int tcp)
{
    int size = 8 << 20, one = 1;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    /* A host that stops answering fails the call instead of hanging the application. */
    struct timeval tv = { 30, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    if (tcp)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
}

int vt_connect(vt_rpc *rpc)
{
    const char *tcp = getenv("MDOCK_VT_TCP");
    const char *path = getenv("MDOCK_VT_SOCKET");
    if (!path || !*path)
        path = "/run/mdock/accel/vt.sock";

    pthread_mutex_init(&rpc->lock, NULL);
    rpc->fd = -1;
    rpc->next_tag = 0;
    rpc->pending = NULL;
    if (tcp && *tcp) {
        char host[64];
        const char *colon = strrchr(tcp, ':');
        if (!colon || (size_t)(colon - tcp) >= sizeof(host))
            return -1;
        memcpy(host, tcp, colon - tcp);
        host[colon - tcp] = 0;
        struct sockaddr_in sa = { .sin_family = AF_INET, .sin_port = htons((uint16_t)atoi(colon + 1)) };
        if (inet_pton(AF_INET, host, &sa.sin_addr) != 1)
            return -1;
        int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
        tune(fd, 1);
        if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
            close(fd);
            return -1;
        }
        rpc->fd = fd;
        snprintf(rpc->endpoint, sizeof(rpc->endpoint), "tcp:%s", tcp);
        return 0;
    }
    struct sockaddr_un sa = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(sa.sun_path))
        return -1;
    strcpy(sa.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    tune(fd, 0);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }
    rpc->fd = fd;
    snprintf(rpc->endpoint, sizeof(rpc->endpoint), "unix:%s", path);
    return 0;
}


static int write_all(int fd, struct iovec *iov, int n)
{
    while (n > 0) {
        ssize_t w = writev(fd, iov, n > 1024 ? 1024 : n);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        while (n > 0 && (size_t)w >= iov->iov_len) {
            w -= iov->iov_len;
            iov++;
            n--;
        }
        if (n > 0 && w > 0) {
            iov->iov_base = (char *)iov->iov_base + w;
            iov->iov_len -= w;
        }
    }
    return 0;
}

static int read_all(int fd, void *p, size_t n)
{
    char *c = p;
    while (n > 0) {
        ssize_t r = read(fd, c, n);
        if (r > 0) {
            c += r;
            n -= r;
        } else if (r < 0 && errno == EINTR) {
            continue;
        } else {
            return -1;
        }
    }
    return 0;
}

#define VT_MAX_OUTSTANDING 16

/* Marks every outstanding request failed and drops the connection (the stream is out of sync). */
static void fail_all(vt_rpc *rpc)
{
    if (rpc->fd >= 0)
        close(rpc->fd);
    rpc->fd = -1;
    for (vt_pending *p = rpc->pending; p; p = p->next) {
        p->done = 1;
        p->status = VA_STATUS_ERROR_OPERATION_FAILED;
    }
    rpc->pending = NULL;
}

/* Reads one reply and completes the request it belongs to. */
static int read_reply(vt_rpc *rpc)
{
    uint32_t rh[4];
    if (read_all(rpc->fd, rh, sizeof(rh)) < 0 || rh[0] != VT_MAGIC)
        return -1;
    uint16_t tag = (uint16_t)(rh[1] >> 16);
    vt_pending **link = &rpc->pending, *p = NULL;
    while (*link && (*link)->tag != tag)
        link = &(*link)->next;
    if (*link) {
        p = *link;
        *link = p->next;
    }
    size_t left = rh[3];
    for (int i = 0; p && i < p->nrep && left > 0; i++) {
        size_t n = p->rep[i].iov_len < left ? p->rep[i].iov_len : left;
        if (read_all(rpc->fd, p->rep[i].iov_base, n) < 0)
            return -1;
        left -= n;
    }
    char sink[4096];
    while (left > 0) {
        size_t n = left < sizeof(sink) ? left : sizeof(sink);
        if (read_all(rpc->fd, sink, n) < 0)
            return -1;
        left -= n;
    }
    if (p) {
        p->len = rh[3];
        p->status = rh[2];
        p->done = 1;
    }
    return 0;
}

static uint32_t send_locked(vt_rpc *rpc, uint16_t op, const struct iovec *req, int nreq, vt_pending *p)
{
    uint32_t hdr[4];
    size_t len = 0;
    for (int i = 0; i < nreq; i++)
        len += req[i].iov_len;
    if (++rpc->next_tag == 0)
        rpc->next_tag = 1;
    p->tag = rpc->next_tag;
    p->done = 0;
    p->status = VA_STATUS_ERROR_OPERATION_FAILED;
    p->len = 0;
    p->next = NULL;
    hdr[0] = VT_MAGIC;
    hdr[1] = op | ((uint32_t)p->tag << 16);
    hdr[2] = 0;
    hdr[3] = (uint32_t)len;
    if (rpc->fd < 0) {
        p->done = 1;
        return p->status;
    }
    vt_pending **link = &rpc->pending;
    while (*link)
        link = &(*link)->next;
    *link = p;

    struct iovec stack[16];
    struct iovec *iov = nreq + 1 <= 16 ? stack : malloc(sizeof(*iov) * (nreq + 1));
    iov[0].iov_base = hdr;
    iov[0].iov_len = sizeof(hdr);
    memcpy(iov + 1, req, sizeof(*iov) * nreq);
    int rc = write_all(rpc->fd, iov, nreq + 1);
    if (iov != stack)
        free(iov);
    if (rc < 0) {
        fail_all(rpc);
        return VA_STATUS_ERROR_OPERATION_FAILED;
    }
    /* Keep the reply stream flowing: read whatever has already arrived, and bound how many
     * requests may be outstanding. Replies left unread back up through the vsock relay. */
    int outstanding = 0;
    for (vt_pending *q = rpc->pending; q; q = q->next)
        outstanding++;
    while (rpc->fd >= 0 && rpc->pending && rpc->pending != p) {
        struct pollfd pfd = { rpc->fd, POLLIN, 0 };
        int wait = outstanding > VT_MAX_OUTSTANDING ? 200 : 0;
        if (poll(&pfd, 1, wait) <= 0)
            break;
        if (read_reply(rpc) < 0) {
            fail_all(rpc);
            break;
        }
        outstanding--;
    }
    return 0;
}

static int wait_locked(vt_rpc *rpc, vt_pending *p, int timeout_ms)
{
    while (!p->done) {
        if (timeout_ms >= 0) {
            struct pollfd pfd = { rpc->fd, POLLIN, 0 };
            int r = poll(&pfd, 1, timeout_ms);
            if (r == 0)
                return 1;
            if (r < 0 && errno == EINTR)
                continue;
        }
        if (read_reply(rpc) < 0) {
            fail_all(rpc);
            return -1;
        }
    }
    return 0;
}

uint32_t vt_send(vt_rpc *rpc, uint16_t op, const struct iovec *req, int nreq, vt_pending *p)
{
    pthread_mutex_lock(&rpc->lock);
    uint32_t st = send_locked(rpc, op, req, nreq, p);
    pthread_mutex_unlock(&rpc->lock);
    return st;
}

int vt_wait(vt_rpc *rpc, vt_pending *p, int timeout_ms)
{
    pthread_mutex_lock(&rpc->lock);
    int rc = wait_locked(rpc, p, timeout_ms);
    pthread_mutex_unlock(&rpc->lock);
    return rc;
}

uint32_t vt_call(vt_rpc *rpc, uint16_t op, const struct iovec *req, int nreq,
                 const struct iovec *rep, int nrep, size_t *rep_len)
{
    vt_pending p;
    memset(&p, 0, sizeof(p));
    p.nrep = nrep > 2 ? 2 : nrep;
    for (int i = 0; i < p.nrep; i++)
        p.rep[i] = rep[i];
    pthread_mutex_lock(&rpc->lock);
    if (send_locked(rpc, op, req, nreq, &p) == 0)
        wait_locked(rpc, &p, -1);
    pthread_mutex_unlock(&rpc->lock);
    if (rep_len)
        *rep_len = p.len;
    return p.status;
}

uint32_t vt_call_words(vt_rpc *rpc, uint16_t op, const uint32_t *words, int nwords,
                       void *rep, size_t rep_cap, size_t *rep_len)
{
    struct iovec req = { (void *)words, sizeof(uint32_t) * nwords };
    struct iovec r = { rep, rep_cap };
    return vt_call(rpc, op, &req, 1, &r, rep ? 1 : 0, rep_len);
}

void vt_close(vt_rpc *rpc)
{
    fail_all(rpc);
    pthread_mutex_destroy(&rpc->lock);
}
