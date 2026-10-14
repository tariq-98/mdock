// mdock media shim: stands in for ffmpeg/ffprobe inside a Linux container and runs the real tool on
// the Mac (VideoToolbox) through the mdock media-exec bridge. Protocol: see Sources/mdock/Accel.swift.
//
// Paths: container paths on virtiofs mounts (bind mounts of /Users/... etc.) are translated to Mac
// paths using /proc/self/mountinfo and MDOCK_SHARES ("tag=hostpath,..."); ffprobe's stdout is
// translated back so callers see their own paths.
//
// Build (static, any libc): gcc -O2 -static -o mdock-media-shim shim.c
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

enum { F_STDIN = 0, F_STDIN_EOF = 1, F_SIGNAL = 2, F_STDOUT = 3, F_STDERR = 4, F_EXIT = 5 };

typedef struct { char *from; char *to; } map_t;
static map_t maps[256];
static int nmaps;

static void die(const char *msg) {
    fprintf(stderr, "mdock-media-shim: %s: %s\n", msg, strerror(errno));
    exit(127);
}

static char *xstrdup(const char *s) { char *d = strdup(s); if (!d) die("oom"); return d; }

/* mountinfo escapes space, tab, newline and backslash as \ooo */
static void unescape(char *s) {
    char *o = s;
    for (char *p = s; *p; p++) {
        if (p[0] == '\\' && p[1] >= '0' && p[1] <= '7' && p[2] && p[3]) {
            *o++ = (char)((p[1] - '0') * 64 + (p[2] - '0') * 8 + (p[3] - '0'));
            p += 3;
        } else {
            *o++ = *p;
        }
    }
    *o = 0;
}

static const char *share_root(const char *tag) {
    static char buf[4096];
    const char *shares = getenv("MDOCK_SHARES");
    if (!shares) shares = "users=/Users,volumes=/Volumes,private=/private,folders=/private/var/folders";
    size_t tl = strlen(tag);
    for (const char *p = shares; *p;) {
        const char *end = strchr(p, ',');
        size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len > tl && strncmp(p, tag, tl) == 0 && p[tl] == '=') {
            snprintf(buf, sizeof buf, "%.*s", (int)(len - tl - 1), p + tl + 1);
            return buf;
        }
        p += len + (end ? 1 : 0);
    }
    return NULL;
}

static void load_mounts(void) {
    FILE *f = fopen("/proc/self/mountinfo", "r");
    if (!f) return;
    char line[8192];
    while (fgets(line, sizeof line, f) && nmaps < 256) {
        char *fields[16];
        int n = 0;
        for (char *tok = strtok(line, " \n"); tok && n < 16; tok = strtok(NULL, " \n")) fields[n++] = tok;
        int dash = -1;
        for (int i = 6; i < n; i++) if (strcmp(fields[i], "-") == 0) { dash = i; break; }
        if (dash < 0 || dash + 2 >= n || strcmp(fields[dash + 1], "virtiofs") != 0) continue;
        const char *root = share_root(fields[dash + 2]);
        if (!root) continue;
        unescape(fields[3]);
        unescape(fields[4]);
        char host[8192];
        snprintf(host, sizeof host, "%s%s", root, strcmp(fields[3], "/") == 0 ? "" : fields[3]);
        if (strcmp(fields[4], host) == 0) continue; /* already identical */
        maps[nmaps].from = xstrdup(fields[4]);
        maps[nmaps].to = xstrdup(host);
        nmaps++;
    }
    fclose(f);
    /* longest mount point first, so nested mounts win */
    for (int i = 0; i < nmaps; i++)
        for (int j = i + 1; j < nmaps; j++)
            if (strlen(maps[j].from) > strlen(maps[i].from)) { map_t t = maps[i]; maps[i] = maps[j]; maps[j] = t; }
}

/* Replaces path prefixes that start an argument or follow a quote, '=', ':' or ',' (filter options,
 * "file:" URLs, concat lists), and are followed by '/' or the end of the path. */
static char *translate(const char *s, int reverse) {
    size_t cap = strlen(s) * 2 + 4096, len = 0;
    char *out = malloc(cap);
    if (!out) die("oom");
    for (size_t i = 0; s[i];) {
        int done = 0;
        if (i == 0 || strchr("'\"=:,", s[i - 1])) {
            for (int m = 0; m < nmaps && !done; m++) {
                const char *from = reverse ? maps[m].to : maps[m].from;
                const char *to = reverse ? maps[m].from : maps[m].to;
                size_t fl = strlen(from);
                char next = s[i + fl];
                if (strncmp(s + i, from, fl) == 0 && (next == 0 || next == '/' || strchr("'\":,", next))) {
                    size_t tl = strlen(to);
                    if (len + tl + 1 >= cap) { cap = (cap + tl) * 2; out = realloc(out, cap); if (!out) die("oom"); }
                    memcpy(out + len, to, tl);
                    len += tl;
                    i += fl;
                    done = 1;
                }
            }
        }
        if (!done) {
            if (len + 2 >= cap) { cap *= 2; out = realloc(out, cap); if (!out) die("oom"); }
            out[len++] = s[i++];
        }
    }
    out[len] = 0;
    return out;
}

static void json_string(FILE *f, const char *s) {
    fputc('"', f);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '"' || *p == '\\') fprintf(f, "\\%c", *p);
        else if (*p < 0x20) fprintf(f, "\\u%04x", *p);
        else fputc(*p, f);
    }
    fputc('"', f);
}

static int write_all(int fd, const void *buf, size_t n) {
    const char *p = buf;
    while (n) {
        ssize_t w = write(fd, p, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return -1;
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t n) {
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

static int send_frame(int fd, uint8_t type, const void *data, uint32_t len) {
    uint8_t h[5] = {type, len >> 24, len >> 16, len >> 8, len};
    if (write_all(fd, h, 5)) return -1;
    return len ? write_all(fd, data, len) : 0;
}

static int sigpipe_fds[2];
static void on_signal(int sig) {
    uint8_t s = (uint8_t)sig;
    (void)!write(sigpipe_fds[1], &s, 1);
}

int main(int argc, char **argv) {
    const char *base = strrchr(argv[0], '/');
    base = base ? base + 1 : argv[0];
    const char *tool = strstr(base, "ffprobe") ? "ffprobe" : "ffmpeg";
    load_mounts();

    const char *path = getenv("MDOCK_MEDIA_SOCKET");
    if (!path) path = "/run/mdock/accel/media.sock";
    int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", path);
    if (s < 0 || connect(s, (struct sockaddr *)&addr, sizeof addr) < 0) die("cannot reach the mdock media bridge");

    /* request line */
    char *req = NULL;
    size_t reqlen = 0;
    FILE *f = open_memstream(&req, &reqlen);
    fprintf(f, "{\"tool\":\"%s\",\"args\":[", tool);
    for (int i = 1; i < argc; i++) {
        char *t = translate(argv[i], 0);
        if (i > 1) fputc(',', f);
        json_string(f, t);
        free(t);
    }
    fputc(']', f);
    char cwd[4096];
    if (getcwd(cwd, sizeof cwd)) {
        char *t = translate(cwd, 0);
        fputs(",\"cwd\":", f);
        json_string(f, t);
        free(t);
    }
    fputs("}\n", f);
    fclose(f);
    if (write_all(s, req, reqlen)) die("send");
    free(req);

    if (pipe(sigpipe_fds)) die("pipe");
    struct sigaction sa = {.sa_handler = on_signal};
    sigemptyset(&sa.sa_mask);
    for (int sig = 1; sig < 32; sig++)
        if (sig == SIGTERM || sig == SIGINT || sig == SIGHUP || sig == SIGQUIT || sig == SIGUSR1 || sig == SIGUSR2)
            sigaction(sig, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    int probe = strcmp(tool, "ffprobe") == 0;
    char *probe_out = NULL;
    size_t probe_len = 0;
    FILE *probe_f = probe ? open_memstream(&probe_out, &probe_len) : NULL;

    int stdin_open = 1;
    char buf[1 << 16];
    for (;;) {
        struct pollfd fds[3] = {{s, POLLIN, 0}, {sigpipe_fds[0], POLLIN, 0}, {0, stdin_open ? POLLIN : 0, 0}};
        if (poll(fds, stdin_open ? 3 : 2, -1) < 0) {
            if (errno == EINTR) continue;
            die("poll");
        }
        if (fds[1].revents & POLLIN) {
            uint8_t sig;
            if (read(sigpipe_fds[0], &sig, 1) == 1) send_frame(s, F_SIGNAL, &sig, 1);
        }
        if (stdin_open && (fds[2].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t n = read(0, buf, sizeof buf);
            if (n > 0) send_frame(s, F_STDIN, buf, (uint32_t)n);
            else if (n == 0 || errno != EINTR) { send_frame(s, F_STDIN_EOF, NULL, 0); stdin_open = 0; }
        }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            uint8_t h[5];
            if (read_all(s, h, 5)) { fprintf(stderr, "mdock-media-shim: bridge closed\n"); return 255; }
            uint32_t len = (uint32_t)h[1] << 24 | (uint32_t)h[2] << 16 | (uint32_t)h[3] << 8 | h[4];
            char *data = len ? malloc(len) : NULL;
            if (len && (!data || read_all(s, data, len))) return 255;
            if (h[0] == F_STDOUT) {
                if (probe_f) fwrite(data, 1, len, probe_f);
                else write_all(1, data, len);
            } else if (h[0] == F_STDERR) {
                write_all(2, data, len);
            } else if (h[0] == F_EXIT && len == 4) {
                int32_t code = (int32_t)((uint32_t)(uint8_t)data[0] << 24 | (uint32_t)(uint8_t)data[1] << 16 |
                                         (uint32_t)(uint8_t)data[2] << 8 | (uint8_t)data[3]);
                if (probe_f) {
                    fclose(probe_f);
                    char *t = translate(probe_out ? probe_out : "", 1);
                    write_all(1, t, strlen(t));
                }
                return code < 0 ? 128 - code : code;
            }
            free(data);
        }
    }
}
