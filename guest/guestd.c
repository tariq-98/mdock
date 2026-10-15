// mdock-guestd: the guest side of mdock's host bridges. Runs inside the Linux VM.
//
//   mdock-guestd relay   [vsock-port]             Mac -> guest TCP for published ports (2376): reads
//                                                 "<port>\n", connects 127.0.0.1:<port>, splices.
//   mdock-guestd hostfwd [tcp-port] [vsock-port]  host.docker.internal -> the Mac's own localhost:
//                                                 connections iptables REDIRECTs here (61080) go to the
//                                                 Mac over vsock (1031): "<original port>\n", the Mac
//                                                 answers 1 once connected, then the data.
//   mdock-guestd udp     [vsock-port]             Mac -> guest UDP for published ports (2378): reads
//                                                 "<port>\n", then datagrams framed [u16 length][data].
//   mdock-guestd notify  [vsock-port]             Mac file changes -> inotify (2377): for each path
//                                                 line, re-applies the file's mode, which raises
//                                                 IN_ATTRIB for watchers inside containers.
//   mdock-guestd tso                              Exit status 0 if this kernel can run a thread in x86's
//                                                 memory order (Apple silicon TSO through
//                                                 PR_SET_MEM_MODEL, mdock's kernel): it tries on itself.
//   mdock-guestd unix    vsock-port path          Mac -> a unix socket in the guest, e.g. the Docker
//                                                 API (2375 -> /var/run/docker.sock). A thread per
//                                                 connection: socat forks one, and under bursts of
//                                                 API calls its accept queue overflowed.
//
// Virtualization.framework never shows the Mac a half-close made in the guest: shutdown(SHUT_WR) on
// a vsock socket is dropped, so the Mac would wait for EOF forever. When the guest side of a stream
// ends, the vsock end is shut down both ways instead, which the Mac does see. Half-closes made on
// the Mac arrive here normally.
//
// Build (static, musl): gcc -O2 -static -o mdock-guestd guestd.c
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <linux/netfilter_ipv4.h>
#include <linux/vm_sockets.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#define BUF (256 * 1024)

static unsigned hostfwd_vsock_port = 1031;

static void die(const char *what) {
    fprintf(stderr, "mdock-guestd: %s: %s\n", what, strerror(errno));
    exit(1);
}

/* A vsock stream's receive buffer is the credit the guest gives the Mac: how much the Mac may send
 * before it waits to hear that the guest has read it. Linux's 256 KiB default costs an upload a round
 * trip every 256 KiB. Memory is only used for bytes actually waiting. MAX first, as SIZE is clamped to
 * it; accepted streams inherit both from their listener. */
static void vsock_buffer(int fd, unsigned long long size) {
    setsockopt(fd, AF_VSOCK, SO_VM_SOCKETS_BUFFER_MAX_SIZE, &size, sizeof size);
    setsockopt(fd, AF_VSOCK, SO_VM_SOCKETS_BUFFER_SIZE, &size, sizeof size);
}

static int listen_vsock(unsigned port, unsigned long long buffer) {
    int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_vm a = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_ANY, .svm_port = port};
    if (fd >= 0 && buffer) vsock_buffer(fd, buffer);
    if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 1024)) die("vsock listen");
    return fd;
}

static int listen_tcp(unsigned port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), one = 1;
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_ANY)};
    if (fd >= 0) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (fd < 0 || bind(fd, (struct sockaddr *)&a, sizeof a) || listen(fd, 128)) die("tcp listen");
    return fd;
}

static int connect_vsock_host(unsigned port) {
    int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_vm a = {.svm_family = AF_VSOCK, .svm_cid = VMADDR_CID_HOST, .svm_port = port};
    if (fd >= 0) vsock_buffer(fd, 1 << 20);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0) return fd;
    if (fd >= 0) close(fd);
    return -1;
}

static void nodelay(int fd) {
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
}

static int connect_local(unsigned port) {
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
        nodelay(fd);
        return fd;
    }
    if (fd >= 0) close(fd);
    return -1;
}

static int write_all(int fd, const char *p, size_t n) {
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

/* One line, a byte at a time so nothing after the newline is consumed. */
static long read_port(int fd) {
    char line[16];
    size_t n = 0;
    while (n < sizeof line - 1) {
        ssize_t r = read(fd, line + n, 1);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        if (line[n] == '\n') break;
        n++;
    }
    line[n] = 0;
    char *end;
    long port = strtol(line, &end, 10);
    return n && *end == 0 && port > 0 && port < 65536 ? port : -1;
}

struct pump {
    int from, to, how; /* how: shutdown(2) mode for `to` at EOF */
};

static void *pump(void *arg) {
    struct pump *p = arg;
    char *buf = malloc(BUF);
    for (;;) {
        ssize_t n = buf ? read(p->from, buf, BUF) : -1;
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        if (write_all(p->to, buf, (size_t)n)) { /* peer gone: tear the whole connection down */
            shutdown(p->from, SHUT_RDWR);
            break;
        }
    }
    free(buf);
    shutdown(p->to, p->how);
    return NULL;
}

/* Splices a TCP socket and a vsock socket until both directions finish, then closes both.
 * tcp_eof_closes_vsock: the TCP side ending means the exchange is over (it's the server). */
static void bridge(int tcp, int vsock, int tcp_eof_closes_vsock) {
    struct pump up = {tcp, vsock, tcp_eof_closes_vsock ? SHUT_RDWR : SHUT_WR};
    struct pump down = {vsock, tcp, SHUT_WR};
    pthread_t t;
    if (pthread_create(&t, NULL, pump, &up) == 0) {
        pump(&down);
        pthread_join(t, NULL);
    }
    close(tcp);
    close(vsock);
}

static const char *unix_target;

static void *unix_conn(void *arg) {
    int v = (int)(intptr_t)arg;
    int u = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", unix_target);
    if (u < 0 || connect(u, (struct sockaddr *)&a, sizeof a)) {
        if (u >= 0) close(u);
        close(v);
        return NULL;
    }
    bridge(u, v, 1); /* the guest side ending (dockerd closed the stream) ends the exchange */
    return NULL;
}

static void *relay_conn(void *arg) {
    int v = (int)(intptr_t)arg;
    long port = read_port(v);
    int t = port > 0 ? connect_local((unsigned)port) : -1;
    if (t < 0) {
        close(v);
        return NULL;
    }
    bridge(t, v, 1);
    return NULL;
}

static void *hostfwd_conn(void *arg) {
    int t = (int)(intptr_t)arg;
    struct sockaddr_in dst;
    socklen_t len = sizeof dst;
    int v = -1;
    if (getsockopt(t, SOL_IP, SO_ORIGINAL_DST, &dst, &len) == 0 && (v = connect_vsock_host(hostfwd_vsock_port)) >= 0) {
        char line[16];
        int n = snprintf(line, sizeof line, "%u\n", ntohs(dst.sin_port));
        char ok = 0;
        ssize_t r = -1;
        if (write_all(v, line, (size_t)n) == 0)
            do r = read(v, &ok, 1); while (r < 0 && errno == EINTR);
        if (r == 1 && ok == 1) {
            nodelay(t);
            bridge(t, v, 0);
            return NULL;
        }
        /* Nothing listens there on the Mac. The client's connect already succeeded (we accepted it),
         * so a reset is the closest thing to "connection refused". */
        struct linger lg = {1, 0};
        setsockopt(t, SOL_SOCKET, SO_LINGER, &lg, sizeof lg);
    }
    if (v >= 0) close(v);
    close(t);
    return NULL;
}

/* chmod to the current mode: no change, but the kernel reports IN_ATTRIB to inotify watchers.
 * (Times are left alone: the guest's cached copy may be stale, and writing it back would rewind
 * the Mac's mtime.) A path that no longer exists pokes its directory instead. */
static void poke(const char *path) {
    struct stat st;
    if (lstat(path, &st) == 0) {
        if (!S_ISLNK(st.st_mode)) chmod(path, st.st_mode & 07777);
        return;
    }
    char dir[PATH_MAX];
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash && slash != dir) {
        *slash = 0;
        if (stat(dir, &st) == 0) chmod(dir, st.st_mode & 07777);
    }
}

static void *notify_conn(void *arg) {
    int v = (int)(intptr_t)arg;
    FILE *f = fdopen(v, "r");
    if (!f) {
        close(v);
        return NULL;
    }
    char *line = NULL;
    size_t cap = 0;
    ssize_t n;
    while ((n = getline(&line, &cap, f)) > 0) {
        if (line[n - 1] == '\n') line[n - 1] = 0;
        if (line[0] == '/') poke(line);
    }
    free(line);
    fclose(f);
    return NULL;
}

static int read_full(int fd, void *buf, size_t n) {
    char *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

struct udpflow {
    int v, u;
    volatile int done;
};

/* Replies from the container -> framed onto the vsock stream. */
static void *udp_replies(void *arg) {
    struct udpflow *f = arg;
    unsigned char *buf = malloc(2 + 65535);
    while (buf) {
        ssize_t n = recv(f->u, buf + 2, 65535, 0);
        if (f->done) break;
        if (n < 0 && (errno == EINTR || errno == ECONNREFUSED)) continue; /* ICMP from a closed port */
        if (n < 0) break;
        buf[0] = (unsigned char)(n >> 8);
        buf[1] = (unsigned char)n;
        if (write_all(f->v, (char *)buf, (size_t)n + 2)) break;
    }
    free(buf);
    shutdown(f->v, SHUT_RDWR);
    return NULL;
}

/* One client flow: "<port>\n", then datagrams framed as [2-byte big-endian length][payload]. */
static void *udp_conn(void *arg) {
    int v = (int)(intptr_t)arg;
    long port = read_port(v);
    int u = port > 0 ? socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0) : -1;
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((unsigned)port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (u < 0 || connect(u, (struct sockaddr *)&a, sizeof a)) {
        if (u >= 0) close(u);
        close(v);
        return NULL;
    }
    struct udpflow f = {v, u, 0};
    pthread_t t;
    unsigned char *buf = malloc(65535);
    if (buf && pthread_create(&t, NULL, udp_replies, &f) == 0) {
        unsigned char h[2];
        while (read_full(v, h, 2) == 0) {
            size_t n = (size_t)h[0] << 8 | h[1];
            if (read_full(v, buf, n)) break;
            send(u, buf, n, 0);
        }
        f.done = 1;
        shutdown(u, SHUT_RDWR); /* wakes udp_replies */
        pthread_join(t, NULL);
    }
    free(buf);
    close(u);
    close(v);
    return NULL;
}

static void serve(int listener, void *(*handler)(void *)) {
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 256 * 1024);
    for (;;) {
        int fd = accept4(listener, NULL, NULL, SOCK_CLOEXEC);
        if (fd < 0) {
            if (errno == EINTR || errno == ECONNABORTED || errno == EMFILE || errno == ENFILE) {
                if (errno == EMFILE || errno == ENFILE) usleep(100000);
                continue;
            }
            die("accept");
        }
        pthread_t t;
        if (pthread_create(&t, &attr, handler, (void *)(intptr_t)fd)) close(fd);
    }
}

static unsigned arg_port(int argc, char **argv, int i, unsigned def) {
    return argc > i ? (unsigned)strtoul(argv[i], NULL, 10) : def;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    const char *mode = argc > 1 ? argv[1] : "";
    /* Uploads into the guest: published ports over vsock, and docker cp, image loads and build
     * contexts through the Docker API. */
    if (!strcmp(mode, "relay")) serve(listen_vsock(arg_port(argc, argv, 2, 2376), 1 << 20), relay_conn);
    if (!strcmp(mode, "hostfwd")) {
        hostfwd_vsock_port = arg_port(argc, argv, 3, 1031);
        serve(listen_tcp(arg_port(argc, argv, 2, 61080)), hostfwd_conn);
    }
    if (!strcmp(mode, "notify")) serve(listen_vsock(arg_port(argc, argv, 2, 2377), 0), notify_conn);
    if (!strcmp(mode, "udp")) serve(listen_vsock(arg_port(argc, argv, 2, 2378), 1 << 20), udp_conn);
    if (!strcmp(mode, "tso")) return prctl(0x4d4d444c /* PR_SET_MEM_MODEL */, 1 /* _TSO */, 0, 0, 0) ? 1 : 0;
    if (!strcmp(mode, "unix") && argc > 3) {
        unix_target = argv[3];
        serve(listen_vsock(arg_port(argc, argv, 2, 2375), 4 << 20), unix_conn);
    }
    fprintf(stderr, "usage: mdock-guestd relay|notify|udp [vsock-port] | hostfwd [tcp-port] [vsock-port]"
                    " | unix vsock-port path | tso\n");
    return 2;
}
