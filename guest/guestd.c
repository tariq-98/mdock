// mdock-guestd: the guest side of mdock's host bridges. Runs inside the Linux VM.
//
//   mdock-guestd dialback [vsock-port]            Mac -> guest streams over the VM's network (2379), so
//                                                 the bytes skip vsock (published ports, the Docker API):
//                                                 the Mac sends "<ip> <port> <secret>\n", where it accepts
//                                                 on that network, then "<id> <target>\n" per connection, the
//                                                 target a port (127.0.0.1) or unix:<path>. Each connects
//                                                 to its target, dials <ip>:<port>, sends "<id>\n" and
//                                                 splices; failures go back on the stream as "<id>
//                                                 refused" (nothing listening) or "<id> unreachable".
//   mdock-guestd relay   [vsock-port]             Mac -> guest TCP for published ports (2376): reads
//                                                 "<port>\n", connects 127.0.0.1:<port>, splices.
//   mdock-guestd hostfwd [tcp-port] [vsock-port]  host.docker.internal -> the Mac's own localhost:
//                                                 connections iptables REDIRECTs here (61080) go to the
//                                                 Mac over the VM's network once dial-back has given us
//                                                 its address and secret (/run/mdock/mac): "<secret>
//                                                 <original port>\n"; else over vsock (1031): "<original
//                                                 port>\n". The Mac answers 1 once connected, then the data.
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
#include <fcntl.h>
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

static int connect_unix(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un a = {.sun_family = AF_UNIX};
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    if (fd >= 0 && connect(fd, (struct sockaddr *)&a, sizeof a) == 0) return fd;
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
    int u = connect_unix(unix_target);
    if (u < 0) {
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

/* Where host.docker.internal connections reach the Mac over the VM's network: "<ip> <port> <secret>",
 * readable by root only (containers never see the guest's /run). */
#define MAC_FILE "/run/mdock/mac"

static void publish_mac(const char *ip, unsigned port, const char *secret) {
    mkdir("/run/mdock", 0755);
    int fd = open(MAC_FILE ".new", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (fd < 0) return;
    char line[128];
    int n = snprintf(line, sizeof line, "%s %u %s\n", ip, port, secret);
    int ok = write_all(fd, line, (size_t)n) == 0;
    close(fd);
    if (ok) rename(MAC_FILE ".new", MAC_FILE);
}

/* host.docker.internal over the VM's network: a connection to the Mac that has sent the secret and the
 * port, or -1 (no dial-back yet, or the Mac's listener is gone: use vsock). */
static int connect_mac(unsigned port) {
    char ip[INET_ADDRSTRLEN], secret[65], line[128];
    unsigned macport;
    FILE *f = fopen(MAC_FILE, "re");
    if (!f) return -1;
    int got = fgets(line, sizeof line, f) && sscanf(line, "%15s %u %64s", ip, &macport, secret) == 3;
    fclose(f);
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)macport)};
    if (!got || inet_pton(AF_INET, ip, &a.sin_addr) != 1) return -1;
    int m = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (m < 0 || connect(m, (struct sockaddr *)&a, sizeof a)) {
        if (m >= 0) close(m);
        return -1;
    }
    nodelay(m);
    int n = snprintf(line, sizeof line, "%s %u\n", secret, port);
    if (write_all(m, line, (size_t)n)) {
        close(m);
        return -1;
    }
    return m;
}

struct dialback {
    int ctl; /* the Mac's control stream; replies are written whole under `lock` */
    int refs;
    pthread_mutex_t lock;
    struct sockaddr_in mac;
};

struct dial {
    struct dialback *db;
    char id[33];
    char target[108]; /* a port, or unix:<path> */
};

static void dialback_release(struct dialback *db) {
    pthread_mutex_lock(&db->lock);
    int last = --db->refs == 0;
    pthread_mutex_unlock(&db->lock);
    if (last) {
        close(db->ctl);
        pthread_mutex_destroy(&db->lock);
        free(db);
    }
}

static void dialback_reply(struct dialback *db, const char *id, const char *what) {
    char line[64];
    int n = snprintf(line, sizeof line, "%s %s\n", id, what);
    pthread_mutex_lock(&db->lock);
    write_all(db->ctl, line, (size_t)n);
    pthread_mutex_unlock(&db->lock);
}

static void *dial_conn(void *arg) {
    struct dial *d = arg;
    int t = -1;
    if (!strncmp(d->target, "unix:", 5)) {
        t = connect_unix(d->target + 5);
    } else {
        char *end;
        long port = strtol(d->target, &end, 10);
        if (*end == 0 && port > 0 && port < 65536) t = connect_local((unsigned)port);
    }
    int m = t < 0 ? -1 : socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (t < 0) {
        dialback_reply(d->db, d->id, "refused");
    } else if (m < 0 || connect(m, (struct sockaddr *)&d->db->mac, sizeof d->db->mac)) {
        dialback_reply(d->db, d->id, "unreachable");
    } else {
        char line[40];
        int n = snprintf(line, sizeof line, "%s\n", d->id);
        nodelay(m);
        if (write_all(m, line, (size_t)n) == 0) {
            bridge(t, m, 0); /* TCP both sides: half-closes pass through as they are */
            t = m = -1;
        }
    }
    if (t >= 0) close(t);
    if (m >= 0) close(m);
    dialback_release(d->db);
    free(d);
    return NULL;
}

/* Lines from a stream read in chunks: the control stream brings one per connection. */
struct lines {
    int fd;
    size_t len;
    char buf[1024];
};

static int next_line(struct lines *l, char *out, size_t size) {
    for (;;) {
        char *nl = memchr(l->buf, '\n', l->len);
        if (nl) {
            size_t n = (size_t)(nl - l->buf);
            if (n >= size) return -1;
            memcpy(out, l->buf, n);
            out[n] = 0;
            l->len -= n + 1;
            memmove(l->buf, nl + 1, l->len);
            return 0;
        }
        if (l->len == sizeof l->buf) return -1;
        ssize_t r = read(l->fd, l->buf + l->len, sizeof l->buf - l->len);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        l->len += (size_t)r;
    }
}

static void *dialback_conn(void *arg) {
    struct dialback *db = calloc(1, sizeof *db);
    if (!db) {
        close((int)(intptr_t)arg);
        return NULL;
    }
    db->ctl = (int)(intptr_t)arg;
    db->refs = 1;
    pthread_mutex_init(&db->lock, NULL);
    char line[160], ip[INET_ADDRSTRLEN], id[33], target[108], secret[65] = "";
    unsigned port;
    struct lines *in = malloc(sizeof *in);
    if (!in) {
        dialback_release(db);
        return NULL;
    }
    in->fd = db->ctl;
    in->len = 0;
    db->mac.sin_family = AF_INET;
    if (next_line(in, line, sizeof line) || sscanf(line, "%15s %u %64s", ip, &port, secret) < 2 || !port || port > 65535 ||
        inet_pton(AF_INET, ip, &db->mac.sin_addr) != 1) {
        free(in);
        dialback_release(db);
        return NULL;
    }
    db->mac.sin_port = htons((uint16_t)port);
    if (secret[0]) publish_mac(ip, port, secret);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attr, 256 * 1024);
    while (next_line(in, line, sizeof line) == 0) {
        struct dial *d;
        if (sscanf(line, "%32s %107s", id, target) != 2 || !(d = malloc(sizeof *d))) continue;
        d->db = db;
        snprintf(d->id, sizeof d->id, "%s", id);
        snprintf(d->target, sizeof d->target, "%s", target);
        pthread_mutex_lock(&db->lock);
        db->refs++;
        pthread_mutex_unlock(&db->lock);
        pthread_t t;
        if (pthread_create(&t, &attr, dial_conn, d)) {
            dialback_release(db);
            free(d);
        }
    }
    pthread_attr_destroy(&attr);
    free(in);
    if (secret[0]) unlink(MAC_FILE); /* the Mac's end is gone */
    dialback_release(db);
    return NULL;
}

static void *hostfwd_conn(void *arg) {
    int t = (int)(intptr_t)arg;
    struct sockaddr_in dst;
    socklen_t len = sizeof dst;
    int v = -1;
    if (getsockopt(t, SOL_IP, SO_ORIGINAL_DST, &dst, &len) == 0) {
        /* Over the VM's network when dial-back is up (TCP's flow control and half-closes end to end),
         * else over vsock. */
        unsigned port = ntohs(dst.sin_port);
        int tcp = 1;
        if ((v = connect_mac(port)) < 0) {
            tcp = 0;
            v = connect_vsock_host(hostfwd_vsock_port);
        }
        char line[16];
        int n = snprintf(line, sizeof line, "%u\n", port);
        char ok = 0;
        ssize_t r = -1;
        if (v >= 0 && (tcp || write_all(v, line, (size_t)n) == 0))
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
    if (!strcmp(mode, "dialback")) serve(listen_vsock(arg_port(argc, argv, 2, 2379), 0), dialback_conn);
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
    fprintf(stderr, "usage: mdock-guestd dialback|relay|notify|udp [vsock-port] | hostfwd [tcp-port] [vsock-port]"
                    " | unix vsock-port path | tso\n");
    return 2;
}
