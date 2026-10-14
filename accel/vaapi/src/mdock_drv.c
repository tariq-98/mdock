/* mdock_drv_video.so: a libva backend that forwards decode and encode to VideoToolbox on the
 * Mac, through the mdock-vt host service (accel/vaapi/PROTOCOL.md).
 *
 * Surfaces live on the host as CVPixelBuffers. The guest keeps a lazily filled "mirror" of a
 * surface only when software touches its pixels (vaDeriveImage/vaGetImage/vaPutImage), so a
 * decode -> encode pipeline that stays in VA surfaces never moves pixels across the VM boundary. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_backend_vpp.h>
#include <va/va_dec_hevc.h>
#include <va/va_enc_h264.h>
#include <va/va_enc_hevc.h>

#include "codec.h"
#include "rpc.h"

#define VENDOR "mdock VideoToolbox bridge"
#define MAX_PROFILES 8
#define MAX_ENTRYPOINTS 3
#define MAX_ATTRIBUTES 16
#define MAX_IMAGE_FORMATS 4

enum { OBJ_CONFIG = 1, OBJ_CONTEXT, OBJ_SURFACE, OBJ_BUFFER, OBJ_IMAGE, OBJ_TYPES };

typedef struct {
    void **items;
    uint32_t cap;
    uint32_t next;
} obj_table;

typedef struct {
    VAProfile profile;
    VAEntrypoint entrypoint;
    uint32_t rt_format;
    uint32_t rc_mode;
} config_obj;

typedef struct {
    VASurfaceID id;
    int width, height;
    uint32_t fourcc;
    int bps;                /* bytes per sample */
    size_t size;            /* packed NV12/P010 size */
    uint8_t *mirror;        /* guest copy, packed layout */
    int mirror_valid;       /* mirror equals host content */
    int host_has_data;
    VAImageID derived;
    uint64_t map_hash;
    vt_pending decode;      /* last decode into this surface, answered asynchronously */
    int decoding;
} surface_obj;

typedef struct {
    VABufferType type;
    unsigned size, num_elements;
    uint8_t *data;
    int owns_data;
    surface_obj *derived;   /* image buffer aliasing a surface mirror */
    VACodedBufferSegment seg;
    /* coded buffers: the encode filling it, answered asynchronously */
    vt_pending encode;
    int encoding;
    uint32_t key;
    VAContextID enc_context;
    VASurfaceID enc_input;
} buffer_obj;

typedef struct {
    VAImage image;
    VASurfaceID derived_from;
} image_obj;

typedef struct {
    uint32_t codec, width, height, depth, profile, rc, bitrate, maxrate, fps_num, fps_den, gop, qp, buffer;
} enc_config;

typedef struct {
    VAContextID id;
    config_obj cfg;
    int width, height;
    int codec;              /* 0 for video processing */
    int encode;
    VASurfaceID target;
    int warned;
    VAProcPipelineParameterBuffer proc;
    VARectangle proc_src, proc_dst;
    int have_proc, have_src_rect, have_dst_rect;
    int failed;

    /* decode */
    int have_pic, have_iq;
    union {
        VAPictureParameterBufferH264 h264;
        VAPictureParameterBufferHEVC hevc;
    } pic;
    union {
        VAIQMatrixBufferH264 h264;
        VAIQMatrixBufferHEVC hevc;
    } iq;
    uint8_t *slice_params;
    size_t slice_param_size, slice_param_cap;
    unsigned nslice_params;
    h264_state h264;
    hevc_state hevc;
    bytebuf params, slices;

    /* encode */
    int have_seq;
    union {
        VAEncSequenceParameterBufferH264 h264;
        VAEncSequenceParameterBufferHEVC hevc;
    } seq;
    VABufferID coded_buf;
    int idr;
    int qp;
    uint32_t rc_bps, rc_pct, framerate, hrd_size;
    int enc_created;
    enc_config sent;
} context_obj;

typedef struct {
    pthread_mutex_t lock;
    obj_table tables[OBJ_TYPES];
    vt_rpc rpc;
    uint32_t caps;
    int debug;
    int frame_fd;           /* O_DIRECT frame file shared with the host, or -1 */
} driver;

static void dbg(driver *d, const char *fmt, ...)
{
    if (!d->debug)
        return;
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "mdock-va: ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

#define DRV(ctx) ((driver *)(ctx)->pDriverData)
#define LOCK(d) pthread_mutex_lock(&(d)->lock)
#define UNLOCK(d) pthread_mutex_unlock(&(d)->lock)

static uint32_t obj_add(driver *d, int type, void *p)
{
    obj_table *t = &d->tables[type];
    for (uint32_t tries = 0; tries < 0xffffff; tries++) {
        uint32_t idx = (t->next++ & 0xffffff);
        if (idx == 0)
            continue;
        if (idx >= t->cap) {
            uint32_t cap = t->cap ? t->cap * 2 : 256;
            while (cap <= idx)
                cap *= 2;
            void **items = realloc(t->items, sizeof(void *) * cap);
            if (!items)
                return VA_INVALID_ID;
            memset(items + t->cap, 0, sizeof(void *) * (cap - t->cap));
            t->items = items;
            t->cap = cap;
        }
        if (!t->items[idx]) {
            t->items[idx] = p;
            return ((uint32_t)type << 24) | idx;
        }
    }
    return VA_INVALID_ID;
}

static void *obj_get(driver *d, int type, uint32_t id)
{
    obj_table *t = &d->tables[type];
    uint32_t idx = id & 0xffffff;
    if ((id >> 24) != (uint32_t)type || idx >= t->cap)
        return NULL;
    return t->items[idx];
}

static void obj_del(driver *d, int type, uint32_t id)
{
    obj_table *t = &d->tables[type];
    uint32_t idx = id & 0xffffff;
    if ((id >> 24) == (uint32_t)type && idx < t->cap)
        t->items[idx] = NULL;
}

/* ---- capabilities ---- */

static int profile_ok(driver *d, VAProfile p, VAEntrypoint ep)
{
    int dec = ep == VAEntrypointVLD, enc = ep == VAEntrypointEncSlice;
    switch (p) {
    case VAProfileNone:
        return ep == VAEntrypointVideoProc;
    case VAProfileH264ConstrainedBaseline:
    case VAProfileH264Main:
    case VAProfileH264High:
        return (dec && (d->caps & VT_CAP_H264_DEC)) || (enc && (d->caps & VT_CAP_H264_ENC));
    case VAProfileHEVCMain:
        return (dec && (d->caps & VT_CAP_HEVC_DEC)) || (enc && (d->caps & VT_CAP_HEVC_ENC));
    case VAProfileHEVCMain10:
        return (dec && (d->caps & VT_CAP_HEVC10_DEC)) || (enc && (d->caps & VT_CAP_HEVC10_ENC));
    default:
        return 0;
    }
}

static const VAProfile all_profiles[] = {
    VAProfileNone, VAProfileH264ConstrainedBaseline, VAProfileH264Main, VAProfileH264High, VAProfileHEVCMain, VAProfileHEVCMain10,
};

static VAStatus mdock_QueryConfigProfiles(VADriverContextP ctx, VAProfile *list, int *num)
{
    driver *d = DRV(ctx);
    int n = 0;
    for (size_t i = 0; i < sizeof(all_profiles) / sizeof(all_profiles[0]); i++)
        if (profile_ok(d, all_profiles[i], VAEntrypointVLD) || profile_ok(d, all_profiles[i], VAEntrypointEncSlice) ||
            profile_ok(d, all_profiles[i], VAEntrypointVideoProc))
            list[n++] = all_profiles[i];
    *num = n;
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_QueryConfigEntrypoints(VADriverContextP ctx, VAProfile profile, VAEntrypoint *list, int *num)
{
    driver *d = DRV(ctx);
    int n = 0;
    if (profile_ok(d, profile, VAEntrypointVLD))
        list[n++] = VAEntrypointVLD;
    if (profile_ok(d, profile, VAEntrypointEncSlice))
        list[n++] = VAEntrypointEncSlice;
    if (profile_ok(d, profile, VAEntrypointVideoProc))
        list[n++] = VAEntrypointVideoProc;
    *num = n;
    return n ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
}

static int is_hevc(VAProfile p)
{
    return p == VAProfileHEVCMain || p == VAProfileHEVCMain10;
}

/* Largest picture: HEVC and video processing go to 8K, H.264 to 4K. */
static int max_dim(VAProfile p, int height)
{
    if (is_hevc(p) || p == VAProfileNone)
        return height ? 4352 : 8192;
    return 4096;
}

static uint32_t attrib_value(VAProfile profile, VAEntrypoint ep, VAConfigAttribType type)
{
    int enc = ep == VAEntrypointEncSlice;
    switch (type) {
    case VAConfigAttribRTFormat:
        return VA_RT_FORMAT_YUV420 | (profile == VAProfileHEVCMain10 || profile == VAProfileNone ? VA_RT_FORMAT_YUV420_10 : 0);
    case VAConfigAttribRateControl:
        return enc ? (VA_RC_CQP | VA_RC_CBR | VA_RC_VBR) : VA_ATTRIB_NOT_SUPPORTED;
    case VAConfigAttribEncPackedHeaders:
        return enc ? VA_ENC_PACKED_HEADER_NONE : VA_ATTRIB_NOT_SUPPORTED;
    case VAConfigAttribEncMaxRefFrames:
        return enc ? 1 : VA_ATTRIB_NOT_SUPPORTED;   /* one L0 reference, no L1: no B-frames */
    case VAConfigAttribEncMaxSlices:
        return enc ? 1 : VA_ATTRIB_NOT_SUPPORTED;
    case VAConfigAttribMaxPictureWidth:
        return max_dim(profile, 0);
    case VAConfigAttribMaxPictureHeight:
        return max_dim(profile, 1);
    case VAConfigAttribDecSliceMode:
        return ep == VAEntrypointVLD ? VA_DEC_SLICE_MODE_NORMAL : VA_ATTRIB_NOT_SUPPORTED;
    default:
        return VA_ATTRIB_NOT_SUPPORTED;
    }
}

static VAStatus mdock_GetConfigAttributes(VADriverContextP ctx, VAProfile profile, VAEntrypoint ep,
                                          VAConfigAttrib *list, int num)
{
    if (!profile_ok(DRV(ctx), profile, ep))
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    for (int i = 0; i < num; i++)
        list[i].value = attrib_value(profile, ep, list[i].type);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_CreateConfig(VADriverContextP ctx, VAProfile profile, VAEntrypoint ep,
                                   VAConfigAttrib *attribs, int num, VAConfigID *out)
{
    driver *d = DRV(ctx);
    if (!profile_ok(d, profile, ep)) {
        int any = 0;
        for (size_t i = 0; i < sizeof(all_profiles) / sizeof(all_profiles[0]); i++)
            any |= all_profiles[i] == profile;
        return any ? VA_STATUS_ERROR_UNSUPPORTED_ENTRYPOINT : VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    }
    config_obj *c = calloc(1, sizeof(*c));
    c->profile = profile;
    c->entrypoint = ep;
    c->rt_format = profile == VAProfileHEVCMain10 ? VA_RT_FORMAT_YUV420_10
                 : profile == VAProfileNone ? VA_RT_FORMAT_YUV420 | VA_RT_FORMAT_YUV420_10 : VA_RT_FORMAT_YUV420;
    c->rc_mode = VA_RC_CQP;
    for (int i = 0; i < num; i++) {
        uint32_t supported = attrib_value(profile, ep, attribs[i].type);
        if (attribs[i].type == VAConfigAttribRTFormat) {
            if (!(attribs[i].value & supported)) {
                free(c);
                return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
            }
            c->rt_format = attribs[i].value;
        } else if (attribs[i].type == VAConfigAttribRateControl && ep == VAEntrypointEncSlice) {
            if (!(attribs[i].value & supported)) {
                free(c);
                return VA_STATUS_ERROR_INVALID_VALUE;
            }
            c->rc_mode = attribs[i].value;
        }
    }
    LOCK(d);
    *out = obj_add(d, OBJ_CONFIG, c);
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_DestroyConfig(VADriverContextP ctx, VAConfigID id)
{
    driver *d = DRV(ctx);
    LOCK(d);
    config_obj *c = obj_get(d, OBJ_CONFIG, id);
    obj_del(d, OBJ_CONFIG, id);
    UNLOCK(d);
    if (!c)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    free(c);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_QueryConfigAttributes(VADriverContextP ctx, VAConfigID id, VAProfile *profile,
                                            VAEntrypoint *ep, VAConfigAttrib *list, int *num)
{
    driver *d = DRV(ctx);
    LOCK(d);
    config_obj *c = obj_get(d, OBJ_CONFIG, id);
    if (!c) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    *profile = c->profile;
    *ep = c->entrypoint;
    int n = 0;
    list[n].type = VAConfigAttribRTFormat;
    list[n++].value = c->rt_format;
    if (c->entrypoint == VAEntrypointEncSlice) {
        list[n].type = VAConfigAttribRateControl;
        list[n++].value = c->rc_mode;
    }
    *num = n;
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

/* ---- surfaces ---- */

static size_t packed_size(int w, int h, int bps)
{
    return (size_t)w * h * bps + (size_t)((w + 1) & ~1) * ((h + 1) / 2) * bps;
}

static VAStatus wait_decode(driver *d, surface_obj *s);

static void surface_free(driver *d, surface_obj *s)
{
    wait_decode(d, s);
    uint32_t w[1] = { s->id };
    vt_call_words(&d->rpc, VT_SURFACE_DESTROY, w, 1, NULL, 0, NULL);
    free(s->mirror);
    free(s);
}

static VAStatus mdock_CreateSurfaces2(VADriverContextP ctx, unsigned int format, unsigned int width,
                                      unsigned int height, VASurfaceID *surfaces, unsigned int num,
                                      VASurfaceAttrib *attribs, unsigned int nattribs)
{
    driver *d = DRV(ctx);
    uint32_t fourcc;
    if (format & VA_RT_FORMAT_YUV420)
        fourcc = VA_FOURCC_NV12;
    else if (format & (VA_RT_FORMAT_YUV420_10 | VA_RT_FORMAT_YUV420_10BPP))
        fourcc = VA_FOURCC_P010;
    else
        return VA_STATUS_ERROR_UNSUPPORTED_RT_FORMAT;
    for (unsigned i = 0; i < nattribs; i++) {
        if (attribs[i].type == VASurfaceAttribPixelFormat && (attribs[i].flags & VA_SURFACE_ATTRIB_SETTABLE)) {
            uint32_t f = attribs[i].value.value.i;
            if (f != VA_FOURCC_NV12 && f != VA_FOURCC_P010)
                return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
            fourcc = f;
        }
    }
    if (!width || !height || width > 8192 || height > 8192)
        return VA_STATUS_ERROR_RESOLUTION_NOT_SUPPORTED;

    LOCK(d);
    for (unsigned i = 0; i < num; i++) {
        surface_obj *s = calloc(1, sizeof(*s));
        s->width = width;
        s->height = height;
        s->fourcc = fourcc;
        s->bps = fourcc == VA_FOURCC_P010 ? 2 : 1;
        s->size = packed_size(width, height, s->bps);
        s->derived = VA_INVALID_ID;
        s->id = obj_add(d, OBJ_SURFACE, s);
        uint32_t w[4] = { s->id, width, height, fourcc };
        VAStatus st = vt_call_words(&d->rpc, VT_SURFACE_CREATE, w, 4, NULL, 0, NULL);
        if (st != VA_STATUS_SUCCESS) {
            obj_del(d, OBJ_SURFACE, s->id);
            free(s);
            for (unsigned j = 0; j < i; j++) {
                surface_obj *o = obj_get(d, OBJ_SURFACE, surfaces[j]);
                obj_del(d, OBJ_SURFACE, surfaces[j]);
                if (o)
                    surface_free(d, o);
            }
            UNLOCK(d);
            return st;
        }
        surfaces[i] = s->id;
    }
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_CreateSurfaces(VADriverContextP ctx, int width, int height, int format, int num,
                                     VASurfaceID *surfaces)
{
    return mdock_CreateSurfaces2(ctx, format, width, height, surfaces, num, NULL, 0);
}

static VAStatus mdock_DestroySurfaces(VADriverContextP ctx, VASurfaceID *list, int num)
{
    driver *d = DRV(ctx);
    LOCK(d);
    for (int i = 0; i < num; i++) {
        surface_obj *s = obj_get(d, OBJ_SURFACE, list[i]);
        if (!s)
            continue;
        obj_del(d, OBJ_SURFACE, list[i]);
        surface_free(d, s);
    }
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

#define FRAME_ALIGN 4096
#define VIA_FRAME_FILE 1u

static size_t round_up(size_t n)
{
    return (n + FRAME_ALIGN - 1) & ~(size_t)(FRAME_ALIGN - 1);
}

/* Page-aligned and padded, so it can be the target of O_DIRECT frame file I/O. */
static int surface_alloc_mirror(surface_obj *s)
{
    if (s->mirror)
        return 0;
    void *p = NULL;
    if (posix_memalign(&p, FRAME_ALIGN, round_up(s->size)))
        return -1;
    memset(p, 0, round_up(s->size));
    s->mirror = p;
    return 0;
}

/* Frame file I/O split over a few threads: virtiofs O_DIRECT throughput scales with requests
 * in flight (measured 2.3 GB/s with one, 3.5 GB/s with four). */
#define FRAME_IO_THREADS 4

typedef struct {
    int fd, write;
    uint8_t *buf;
    size_t len;
    off_t off;
    ssize_t done;
} frame_io_part;

static void *frame_io_run(void *arg)
{
    frame_io_part *p = arg;
    size_t got = 0;
    while (got < p->len) {
        ssize_t r = p->write ? pwrite(p->fd, p->buf + got, p->len - got, p->off + got)
                             : pread(p->fd, p->buf + got, p->len - got, p->off + got);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            break;
        got += r;
    }
    p->done = got;
    return NULL;
}

/* Reads or writes len bytes (a multiple of FRAME_ALIGN) at offset 0. Returns 0 on success. */
static int frame_io(int fd, uint8_t *buf, size_t len, int write)
{
    frame_io_part parts[FRAME_IO_THREADS];
    pthread_t threads[FRAME_IO_THREADS];
    int n = len >= (4u << 20) ? FRAME_IO_THREADS : 1;
    size_t chunk = round_up((len + n - 1) / n);
    int started[FRAME_IO_THREADS] = { 0 };
    for (int i = 0; i < n; i++) {
        size_t off = (size_t)i * chunk;
        parts[i] = (frame_io_part){ fd, write, buf + off, off < len ? (len - off < chunk ? len - off : chunk) : 0, (off_t)off, 0 };
        if (i > 0 && parts[i].len)
            started[i] = pthread_create(&threads[i], NULL, frame_io_run, &parts[i]) == 0;
    }
    frame_io_run(&parts[0]);
    int ok = 1;
    for (int i = 0; i < n; i++) {
        if (i > 0 && parts[i].len) {
            if (started[i])
                pthread_join(threads[i], NULL);
            else
                frame_io_run(&parts[i]);
        }
        ok &= parts[i].done == (ssize_t)parts[i].len;
    }
    return ok ? 0 : -1;
}

/* Brings the mirror up to date with the host. */
static VAStatus surface_fetch(driver *d, surface_obj *s)
{
    if (surface_alloc_mirror(s) < 0)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    if (s->mirror_valid || !s->host_has_data) {
        s->mirror_valid = 1;
        return VA_STATUS_SUCCESS;
    }
    uint32_t w[2] = { s->id, d->frame_fd >= 0 ? VIA_FRAME_FILE : 0 }, head[2] = { 0, 0 };
    struct iovec req = { w, sizeof(w) };
    struct iovec rep[2] = { { head, sizeof(head) }, { s->mirror, s->size } };
    size_t len = 0;
    VAStatus st = vt_call(&d->rpc, VT_SURFACE_GET, &req, 1, rep, 2, &len);
    if (st != VA_STATUS_SUCCESS)
        return st;
    if (head[0] && (head[1] & VIA_FRAME_FILE)) {
        if (frame_io(d->frame_fd, s->mirror, round_up(s->size), 0) < 0) {
            dbg(d, "frame file read failed (%s)", strerror(errno));
            return VA_STATUS_ERROR_OPERATION_FAILED;
        }
    }
    s->mirror_valid = 1;
    return st;
}

static VAStatus surface_push(driver *d, surface_obj *s)
{
    uint32_t w[2] = { s->id, 0 };
    struct iovec req[2] = { { w, sizeof(w) }, { s->mirror, s->size } };
    int nreq = 2;
    if (d->frame_fd >= 0 && frame_io(d->frame_fd, s->mirror, round_up(s->size), 1) == 0) {
        w[1] = VIA_FRAME_FILE;
        nreq = 1;
    }
    VAStatus st = vt_call(&d->rpc, VT_SURFACE_PUT, req, nreq, NULL, 0, NULL);
    if (st == VA_STATUS_SUCCESS) {
        s->host_has_data = 1;
        s->mirror_valid = 1;
    }
    return st;
}

/* Cheap content hash used to notice whether a mapped derived image was written. */
static uint64_t hash_bytes(const uint8_t *p, size_t n)
{
    uint64_t h0 = 0x9E3779B97F4A7C15ull, h1 = 0xC2B2AE3D27D4EB4Full, h2 = 0x165667B19E3779F9ull, h3 = 0x27D4EB2F165667C5ull;
    size_t i = 0;
    for (; i + 32 <= n; i += 32) {
        uint64_t a, b, c, e;
        memcpy(&a, p + i, 8);
        memcpy(&b, p + i + 8, 8);
        memcpy(&c, p + i + 16, 8);
        memcpy(&e, p + i + 24, 8);
        h0 = (h0 ^ a) * 0x100000001B3ull;
        h1 = (h1 ^ b) * 0x100000001B3ull;
        h2 = (h2 ^ c) * 0x100000001B3ull;
        h3 = (h3 ^ e) * 0x100000001B3ull;
    }
    for (; i < n; i++)
        h0 = (h0 ^ p[i]) * 0x100000001B3ull;
    return h0 ^ (h1 << 1) ^ (h2 << 2) ^ (h3 << 3) ^ n;
}

/* Collects the reply of the last decode into s. Host requests run in order, so this is only
 * needed for the status: later requests on the surface already see the decoded picture. */
static VAStatus wait_decode(driver *d, surface_obj *s)
{
    if (!s->decoding)
        return VA_STATUS_SUCCESS;
    vt_wait(&d->rpc, &s->decode, -1);
    s->decoding = 0;
    if (s->decode.status != VA_STATUS_SUCCESS)
        dbg(d, "decode into %#x failed: %#x", s->id, s->decode.status);
    return s->decode.status == VA_STATUS_SUCCESS ? VA_STATUS_SUCCESS : VA_STATUS_ERROR_DECODING_ERROR;
}

/* Waits for the encode filling coded buffer b. If the encoder holds the frame back, it is asked
 * to flush. */
static VAStatus wait_encode(driver *d, buffer_obj *b)
{
    if (!b->encoding)
        return VA_STATUS_SUCCESS;
    if (vt_wait(&d->rpc, &b->encode, 200) == 1) {
        uint32_t w[1] = { b->enc_context };
        vt_call_words(&d->rpc, VT_ENCODER_FLUSH, w, 1, NULL, 0, NULL);
        vt_wait(&d->rpc, &b->encode, -1);
    }
    b->encoding = 0;
    size_t bytes = b->encode.len >= 4 ? b->encode.len - 4 : 0;
    unsigned cap = b->size * (b->num_elements ? b->num_elements : 1);
    b->seg.buf = b->data;
    b->seg.size = bytes > cap ? cap : (uint32_t)bytes;
    b->seg.bit_offset = 0;
    b->seg.status = bytes > cap ? VA_CODED_BUF_STATUS_SLICE_OVERFLOW_MASK : 0;
    b->seg.next = NULL;
    return b->encode.status;
}

static VAStatus mdock_SyncSurface(VADriverContextP ctx, VASurfaceID id)
{
    driver *d = DRV(ctx);
    LOCK(d);
    surface_obj *s = obj_get(d, OBJ_SURFACE, id);
    if (!s) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    VAStatus st = wait_decode(d, s);
    obj_table *t = &d->tables[OBJ_BUFFER];
    for (uint32_t i = 0; i < t->cap; i++) {
        buffer_obj *b = t->items[i];
        if (b && b->encoding && b->enc_input == id) {
            VAStatus e = wait_encode(d, b);
            if (st == VA_STATUS_SUCCESS)
                st = e;
        }
    }
    UNLOCK(d);
    return st;
}

static VAStatus mdock_SyncSurface2(VADriverContextP ctx, VASurfaceID id, uint64_t timeout)
{
    (void)timeout;
    return mdock_SyncSurface(ctx, id);
}

static VAStatus mdock_SyncBuffer(VADriverContextP ctx, VABufferID id, uint64_t timeout)
{
    driver *d = DRV(ctx);
    LOCK(d);
    buffer_obj *b = obj_get(d, OBJ_BUFFER, id);
    VAStatus st = b ? wait_encode(d, b) : VA_STATUS_ERROR_INVALID_BUFFER;
    UNLOCK(d);
    return st;
}

static VAStatus mdock_QuerySurfaceStatus(VADriverContextP ctx, VASurfaceID id, VASurfaceStatus *status)
{
    driver *d = DRV(ctx);
    LOCK(d);
    surface_obj *s = obj_get(d, OBJ_SURFACE, id);
    UNLOCK(d);
    if (!s)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    *status = VASurfaceReady;
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_QuerySurfaceAttributes(VADriverContextP ctx, VAConfigID config, VASurfaceAttrib *list,
                                             unsigned int *num)
{
    driver *d = DRV(ctx);
    LOCK(d);
    config_obj *c = obj_get(d, OBJ_CONFIG, config);
    UNLOCK(d);
    if (!c)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    VASurfaceAttrib a[8];
    int n = 0;
    memset(a, 0, sizeof(a));
#define ATTR(t, f, v) do { a[n].type = t; a[n].flags = f; a[n].value.type = VAGenericValueTypeInteger; a[n].value.value.i = v; n++; } while (0)
    if (c->rt_format & VA_RT_FORMAT_YUV420)
        ATTR(VASurfaceAttribPixelFormat, VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE, VA_FOURCC_NV12);
    if (c->rt_format & (VA_RT_FORMAT_YUV420_10 | VA_RT_FORMAT_YUV420_10BPP))
        ATTR(VASurfaceAttribPixelFormat, VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE, VA_FOURCC_P010);
    ATTR(VASurfaceAttribMinWidth, VA_SURFACE_ATTRIB_GETTABLE, 16);
    ATTR(VASurfaceAttribMinHeight, VA_SURFACE_ATTRIB_GETTABLE, 16);
    ATTR(VASurfaceAttribMaxWidth, VA_SURFACE_ATTRIB_GETTABLE, max_dim(c->profile, 0));
    ATTR(VASurfaceAttribMaxHeight, VA_SURFACE_ATTRIB_GETTABLE, max_dim(c->profile, 1));
    ATTR(VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_GETTABLE | VA_SURFACE_ATTRIB_SETTABLE, VA_SURFACE_ATTRIB_MEM_TYPE_VA);
#undef ATTR
    if (!list) {
        *num = n;
        return VA_STATUS_SUCCESS;
    }
    if (*num < (unsigned)n) {
        *num = n;
        return VA_STATUS_ERROR_MAX_NUM_EXCEEDED;
    }
    memcpy(list, a, sizeof(VASurfaceAttrib) * n);
    *num = n;
    return VA_STATUS_SUCCESS;
}

/* ---- contexts ---- */

static VAStatus mdock_CreateContext(VADriverContextP ctx, VAConfigID config, int width, int height, int flag,
                                    VASurfaceID *targets, int ntargets, VAContextID *out)
{
    (void)flag;
    (void)targets;
    (void)ntargets;
    driver *d = DRV(ctx);
    LOCK(d);
    config_obj *c = obj_get(d, OBJ_CONFIG, config);
    if (!c) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_CONFIG;
    }
    context_obj *x = calloc(1, sizeof(*x));
    x->cfg = *c;
    x->width = width;
    x->height = height;
    x->codec = c->entrypoint == VAEntrypointVideoProc ? 0 : is_hevc(c->profile) ? VT_CODEC_HEVC : VT_CODEC_H264;
    x->encode = c->entrypoint == VAEntrypointEncSlice;
    x->coded_buf = VA_INVALID_ID;
    x->id = obj_add(d, OBJ_CONTEXT, x);
    if (x->codec == VT_CODEC_H264)
        h264_init(&x->h264, c->profile);
    else if (x->codec == VT_CODEC_HEVC)
        hevc_init(&x->hevc, c->profile);
    VAStatus st = VA_STATUS_SUCCESS;
    if (!x->encode && x->codec) {
        uint32_t w[5] = { x->id, x->codec, width, height, c->profile == VAProfileHEVCMain10 ? 10 : 8 };
        st = vt_call_words(&d->rpc, VT_DECODER_CREATE, w, 5, NULL, 0, NULL);
    }
    if (st != VA_STATUS_SUCCESS) {
        obj_del(d, OBJ_CONTEXT, x->id);
        free(x);
        UNLOCK(d);
        return st;
    }
    *out = x->id;
    dbg(d, "context %#x: %s %s %dx%d", x->id, !x->codec ? "video processing" : x->encode ? "encode" : "decode",
        !x->codec ? "" : x->codec == VT_CODEC_HEVC ? "hevc" : "h264", width, height);
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_DestroyContext(VADriverContextP ctx, VAContextID id)
{
    driver *d = DRV(ctx);
    LOCK(d);
    context_obj *x = obj_get(d, OBJ_CONTEXT, id);
    if (!x) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    obj_del(d, OBJ_CONTEXT, id);
    uint32_t w[1] = { id };
    vt_call_words(&d->rpc, VT_CONTEXT_DESTROY, w, 1, NULL, 0, NULL);
    if (x->codec == VT_CODEC_H264)
        h264_free(&x->h264);
    else if (x->codec == VT_CODEC_HEVC)
        hevc_free(&x->hevc);
    bb_free(&x->params);
    bb_free(&x->slices);
    free(x->slice_params);
    free(x);
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

/* ---- buffers ---- */

static VAStatus mdock_CreateBuffer(VADriverContextP ctx, VAContextID context, VABufferType type, unsigned int size,
                                   unsigned int num, void *data, VABufferID *out)
{
    (void)context;
    driver *d = DRV(ctx);
    buffer_obj *b = calloc(1, sizeof(*b));
    if (!b)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    b->type = type;
    b->size = size;
    b->num_elements = num;
    size_t total = (size_t)size * (num ? num : 1);
    b->data = malloc(total ? total : 1);
    b->owns_data = 1;
    if (!b->data) {
        free(b);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    if (data)
        memcpy(b->data, data, total);
    if (type == VAEncCodedBufferType) {
        b->seg.buf = b->data;
        b->seg.size = 0;
    }
    LOCK(d);
    *out = obj_add(d, OBJ_BUFFER, b);
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_BufferSetNumElements(VADriverContextP ctx, VABufferID id, unsigned int num)
{
    driver *d = DRV(ctx);
    LOCK(d);
    buffer_obj *b = obj_get(d, OBJ_BUFFER, id);
    UNLOCK(d);
    if (!b)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    if (num > b->num_elements)
        return VA_STATUS_ERROR_INVALID_PARAMETER;
    b->num_elements = num;
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_MapBuffer(VADriverContextP ctx, VABufferID id, void **out)
{
    driver *d = DRV(ctx);
    VAStatus st = VA_STATUS_SUCCESS;
    LOCK(d);
    buffer_obj *b = obj_get(d, OBJ_BUFFER, id);
    if (!b) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    if (b->type == VAEncCodedBufferType)
        st = wait_encode(d, b);
    if (b->derived) {
        st = surface_fetch(d, b->derived);
        b->data = b->derived->mirror;
        b->derived->map_hash = hash_bytes(b->derived->mirror, b->derived->size);
    }
    *out = b->type == VAEncCodedBufferType ? (void *)&b->seg : (void *)b->data;
    UNLOCK(d);
    return st;
}

static VAStatus mdock_UnmapBuffer(VADriverContextP ctx, VABufferID id)
{
    driver *d = DRV(ctx);
    VAStatus st = VA_STATUS_SUCCESS;
    LOCK(d);
    buffer_obj *b = obj_get(d, OBJ_BUFFER, id);
    if (!b) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_BUFFER;
    }
    surface_obj *s = b->derived;
    if (s && s->mirror && hash_bytes(s->mirror, s->size) != s->map_hash)
        st = surface_push(d, s);
    UNLOCK(d);
    return st;
}

static void buffer_free(buffer_obj *b)
{
    if (b->owns_data)
        free(b->data);
    free(b);
}

static VAStatus wait_encode(driver *d, buffer_obj *b);

static VAStatus mdock_DestroyBuffer(VADriverContextP ctx, VABufferID id)
{
    driver *d = DRV(ctx);
    LOCK(d);
    buffer_obj *b = obj_get(d, OBJ_BUFFER, id);
    if (b)
        wait_encode(d, b);   /* its reply would land in freed memory */
    obj_del(d, OBJ_BUFFER, id);
    UNLOCK(d);
    if (!b)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    buffer_free(b);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_BufferInfo(VADriverContextP ctx, VABufferID id, VABufferType *type, unsigned int *size,
                                 unsigned int *num)
{
    driver *d = DRV(ctx);
    LOCK(d);
    buffer_obj *b = obj_get(d, OBJ_BUFFER, id);
    UNLOCK(d);
    if (!b)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    *type = b->type;
    *size = b->size;
    *num = b->num_elements;
    return VA_STATUS_SUCCESS;
}

/* ---- decode ---- */

static VAStatus mdock_BeginPicture(VADriverContextP ctx, VAContextID context, VASurfaceID target)
{
    driver *d = DRV(ctx);
    LOCK(d);
    context_obj *x = obj_get(d, OBJ_CONTEXT, context);
    if (!x || !obj_get(d, OBJ_SURFACE, target)) {
        UNLOCK(d);
        return x ? VA_STATUS_ERROR_INVALID_SURFACE : VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    x->target = target;
    x->failed = 0;
    x->have_pic = 0;
    x->have_iq = 0;
    x->nslice_params = 0;
    x->idr = 0;
    bb_reset(&x->params);
    bb_reset(&x->slices);
    x->have_proc = 0;
    if (x->codec == VT_CODEC_H264)
        h264_begin_picture(&x->h264);
    else if (x->codec == VT_CODEC_HEVC)
        hevc_begin_picture(&x->hevc);
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static void decode_slices(driver *d, context_obj *x, buffer_obj *data)
{
    size_t psize = x->codec == VT_CODEC_H264 ? sizeof(VASliceParameterBufferH264) : sizeof(VASliceParameterBufferHEVC);
    if (!x->have_pic || x->slice_param_size < psize) {
        x->failed = 1;
        return;
    }
    size_t total = (size_t)data->size * (data->num_elements ? data->num_elements : 1);
    for (unsigned i = 0; i < x->nslice_params; i++) {
        const uint8_t *p = x->slice_params + (size_t)i * x->slice_param_size;
        uint32_t off, size;
        memcpy(&size, p, 4);                /* slice_data_size, slice_data_offset lead both structs */
        memcpy(&off, p + 4, 4);
        if ((size_t)off + size > total) {
            x->failed = 1;
            continue;
        }
        int rc;
        if (x->codec == VT_CODEC_H264)
            rc = h264_add_slice(&x->h264, &x->pic.h264, (const VASliceParameterBufferH264 *)p, data->data + off, size, &x->slices);
        else
            rc = hevc_add_slice(&x->hevc, &x->pic.hevc, (const VASliceParameterBufferHEVC *)p, data->data + off, size, &x->slices);
        if (rc < 0) {
            dbg(d, "slice %u: header parse failed", i);
            x->failed = 1;
        }
    }
    x->nslice_params = 0;
}

static void read_misc(context_obj *x, buffer_obj *b)
{
    VAEncMiscParameterBuffer *m = (VAEncMiscParameterBuffer *)b->data;
    switch (m->type) {
    case VAEncMiscParameterTypeRateControl: {
        VAEncMiscParameterRateControl *rc = (void *)m->data;
        x->rc_bps = rc->bits_per_second;
        x->rc_pct = rc->target_percentage;
        break;
    }
    case VAEncMiscParameterTypeFrameRate: {
        VAEncMiscParameterFrameRate *fr = (void *)m->data;
        x->framerate = fr->framerate;
        break;
    }
    case VAEncMiscParameterTypeHRD: {
        VAEncMiscParameterHRD *h = (void *)m->data;
        x->hrd_size = h->buffer_size;
        break;
    }
    default:
        break;
    }
}

static VAStatus mdock_RenderPicture(VADriverContextP ctx, VAContextID context, VABufferID *buffers, int num)
{
    driver *d = DRV(ctx);
    LOCK(d);
    context_obj *x = obj_get(d, OBJ_CONTEXT, context);
    if (!x) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_CONTEXT;
    }
    VAStatus st = VA_STATUS_SUCCESS;
    for (int i = 0; i < num; i++) {
        buffer_obj *b = obj_get(d, OBJ_BUFFER, buffers[i]);
        if (!b) {
            st = VA_STATUS_ERROR_INVALID_BUFFER;
            break;
        }
        size_t total = (size_t)b->size * (b->num_elements ? b->num_elements : 1);
        if (!x->codec) {
            if (b->type == VAProcPipelineParameterBufferType && total >= sizeof(VAProcPipelineParameterBuffer)) {
                /* Region pointers belong to the caller: copy what they point at now. */
                memcpy(&x->proc, b->data, sizeof(x->proc));
                x->have_src_rect = x->proc.surface_region != NULL;
                x->have_dst_rect = x->proc.output_region != NULL;
                if (x->have_src_rect)
                    x->proc_src = *x->proc.surface_region;
                if (x->have_dst_rect)
                    x->proc_dst = *x->proc.output_region;
                x->have_proc = 1;
            }
        } else if (!x->encode) {
            switch (b->type) {
            case VAPictureParameterBufferType:
                memset(&x->pic, 0, sizeof(x->pic));
                memcpy(&x->pic, b->data, total < sizeof(x->pic) ? total : sizeof(x->pic));
                x->have_pic = 1;
                break;
            case VAIQMatrixBufferType:
                memset(&x->iq, 0, sizeof(x->iq));
                memcpy(&x->iq, b->data, total < sizeof(x->iq) ? total : sizeof(x->iq));
                x->have_iq = 1;
                break;
            case VASliceParameterBufferType:
                if (total > x->slice_param_cap) {
                    free(x->slice_params);
                    x->slice_params = malloc(total);
                    x->slice_param_cap = total;
                }
                memcpy(x->slice_params, b->data, total);
                x->slice_param_size = b->size;
                x->nslice_params = b->num_elements;
                break;
            case VASliceDataBufferType:
                decode_slices(d, x, b);
                break;
            default:
                break;
            }
        } else {
            switch (b->type) {
            case VAEncSequenceParameterBufferType:
                memcpy(&x->seq, b->data, total < sizeof(x->seq) ? total : sizeof(x->seq));
                x->have_seq = 1;
                break;
            case VAEncPictureParameterBufferType:
                if (x->codec == VT_CODEC_H264) {
                    VAEncPictureParameterBufferH264 *p = (void *)b->data;
                    x->coded_buf = p->coded_buf;
                    x->idr = p->pic_fields.bits.idr_pic_flag;
                    x->qp = p->pic_init_qp;
                } else {
                    VAEncPictureParameterBufferHEVC *p = (void *)b->data;
                    x->coded_buf = p->coded_buf;
                    x->idr = p->pic_fields.bits.idr_pic_flag;
                    x->qp = p->pic_init_qp;
                }
                break;
            case VAEncSliceParameterBufferType:
                if (x->codec == VT_CODEC_H264)
                    x->qp += ((VAEncSliceParameterBufferH264 *)b->data)->slice_qp_delta;
                else
                    x->qp += ((VAEncSliceParameterBufferHEVC *)b->data)->slice_qp_delta;
                break;
            case VAEncMiscParameterBufferType:
                read_misc(x, b);
                break;
            default:
                break;   /* packed headers etc.: VideoToolbox writes its own */
            }
        }
    }
    UNLOCK(d);
    return st;
}

static VAStatus end_decode(driver *d, context_obj *x)
{
    surface_obj *s = obj_get(d, OBJ_SURFACE, x->target);
    if (!s)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    if (x->failed || !x->have_pic || x->slices.count == 0)
        return VA_STATUS_ERROR_DECODING_ERROR;
    if (x->codec == VT_CODEC_H264 && !x->pic.h264.seq_fields.bits.frame_mbs_only_flag) {
        /* The media engine has no interlaced H.264 (neither has VideoToolbox's hwaccel on macOS). */
        if (!x->warned++)
            fprintf(stderr, "mdock-va: interlaced H.264 is not supported by the Mac's media engine\n");
        return VA_STATUS_ERROR_UNSUPPORTED_PROFILE;
    }
    int rc;
    if (x->codec == VT_CODEC_H264)
        rc = h264_build_params(&x->h264, &x->pic.h264, x->have_iq ? &x->iq.h264 : NULL, &x->params);
    else
        rc = hevc_build_params(&x->hevc, &x->pic.hevc,
                               x->have_iq && x->pic.hevc.pic_fields.bits.scaling_list_enabled_flag ? &x->iq.hevc : NULL,
                               &x->params);
    if (rc < 0)
        return VA_STATUS_ERROR_DECODING_ERROR;
    uint32_t w[4] = { x->id, s->id, x->params.count, x->slices.count };
    struct iovec req[3] = { { w, sizeof(w) }, { x->params.data, x->params.len }, { x->slices.data, x->slices.len } };
    wait_decode(d, s);
    memset(&s->decode, 0, sizeof(s->decode));
    VAStatus st = vt_send(&d->rpc, VT_DECODE, req, 3, &s->decode);
    s->decoding = st == VA_STATUS_SUCCESS;
    s->host_has_data = 1;
    s->mirror_valid = 0;
    return st;
}

/* ---- video processing ---- */

static VAStatus end_process(driver *d, context_obj *x)
{
    surface_obj *dst = obj_get(d, OBJ_SURFACE, x->target);
    surface_obj *src = x->have_proc ? obj_get(d, OBJ_SURFACE, x->proc.surface) : NULL;
    if (!dst || !src)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    if (x->proc.num_filters > 0)
        dbg(d, "video processing: %u filters ignored", x->proc.num_filters);
    VARectangle s = x->have_src_rect ? x->proc_src : (VARectangle){ 0, 0, (uint16_t)src->width, (uint16_t)src->height };
    VARectangle o = x->have_dst_rect ? x->proc_dst : (VARectangle){ 0, 0, (uint16_t)dst->width, (uint16_t)dst->height };
    uint32_t w[10] = { src->id, dst->id, (uint32_t)s.x, (uint32_t)s.y, s.width, s.height,
                       (uint32_t)o.x, (uint32_t)o.y, o.width, o.height };
    VAStatus st = vt_call_words(&d->rpc, VT_PROCESS, w, 10, NULL, 0, NULL);
    if (st == VA_STATUS_SUCCESS) {
        dst->host_has_data = 1;
        dst->mirror_valid = 0;
    }
    return st;
}

static VAStatus mdock_QueryVideoProcFilters(VADriverContextP ctx, VAContextID context, VAProcFilterType *filters,
                                            unsigned int *num)
{
    *num = 0;   /* scaling and format conversion only */
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_QueryVideoProcFilterCaps(VADriverContextP ctx, VAContextID context, VAProcFilterType type,
                                               void *caps, unsigned int *num)
{
    *num = 0;
    return VA_STATUS_ERROR_UNSUPPORTED_FILTER;
}

static VAProcColorStandardType color_standards[] = { VAProcColorStandardBT601, VAProcColorStandardBT709,
                                                     VAProcColorStandardBT2020 };
static uint32_t proc_formats[] = { VA_FOURCC_NV12, VA_FOURCC_P010 };

static VAStatus mdock_QueryVideoProcPipelineCaps(VADriverContextP ctx, VAContextID context, VABufferID *filters,
                                                 unsigned int num_filters, VAProcPipelineCaps *caps)
{
    caps->pipeline_flags = 0;
    caps->filter_flags = 0;
    caps->num_forward_references = 0;
    caps->num_backward_references = 0;
    caps->input_color_standards = color_standards;
    caps->num_input_color_standards = 3;
    caps->output_color_standards = color_standards;
    caps->num_output_color_standards = 3;
    caps->rotation_flags = 1 << VA_ROTATION_NONE;
    caps->blend_flags = 0;
    caps->mirror_flags = 0;
    caps->num_additional_outputs = 0;
    caps->num_input_pixel_formats = 2;
    caps->input_pixel_format = proc_formats;
    caps->num_output_pixel_formats = 2;
    caps->output_pixel_format = proc_formats;
    caps->max_input_width = caps->max_output_width = 8192;
    caps->max_input_height = caps->max_output_height = 4352;
    caps->min_input_width = caps->min_output_width = 16;
    caps->min_input_height = caps->min_output_height = 16;
    return VA_STATUS_SUCCESS;
}

/* ---- encode ---- */

static VAStatus end_encode(driver *d, context_obj *x)
{
    surface_obj *s = obj_get(d, OBJ_SURFACE, x->target);
    buffer_obj *coded = obj_get(d, OBJ_BUFFER, x->coded_buf);
    if (!s)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    if (!coded || !x->have_seq)
        return VA_STATUS_ERROR_INVALID_PARAMETER;

    enc_config c = { 0 };
    c.codec = x->codec;
    c.depth = x->cfg.profile == VAProfileHEVCMain10 ? 10 : 8;
    uint32_t gop;
    if (x->codec == VT_CODEC_H264) {
        VAEncSequenceParameterBufferH264 *q = &x->seq.h264;
        int crop = q->frame_cropping_flag;
        c.width = q->picture_width_in_mbs * 16 - (crop ? 2 * (q->frame_crop_left_offset + q->frame_crop_right_offset) : 0);
        c.height = q->picture_height_in_mbs * 16 - (crop ? 2 * (q->frame_crop_top_offset + q->frame_crop_bottom_offset) : 0);
        c.profile = x->cfg.profile == VAProfileH264ConstrainedBaseline ? 0 : x->cfg.profile == VAProfileH264Main ? 1 : 2;
        gop = q->intra_idr_period ? q->intra_idr_period : q->intra_period;
        if (!x->rc_bps)
            x->rc_bps = q->bits_per_second;
    } else {
        VAEncSequenceParameterBufferHEVC *q = &x->seq.hevc;
        /* VA carries no HEVC conformance window: the input surface bounds the real size. */
        c.width = q->pic_width_in_luma_samples < (unsigned)s->width ? q->pic_width_in_luma_samples : (unsigned)s->width;
        c.height = q->pic_height_in_luma_samples < (unsigned)s->height ? q->pic_height_in_luma_samples : (unsigned)s->height;
        c.profile = 1;
        if (q->seq_fields.bits.bit_depth_luma_minus8)
            c.depth = 10;
        gop = q->intra_idr_period ? q->intra_idr_period : q->intra_period;
        if (!x->rc_bps)
            x->rc_bps = q->bits_per_second;
    }
    c.rc = (x->cfg.rc_mode & VA_RC_CQP) ? 1 : (x->cfg.rc_mode & VA_RC_CBR) ? 2 : 3;
    c.maxrate = x->rc_bps;
    c.bitrate = c.rc == 3 && x->rc_pct ? (uint32_t)((uint64_t)x->rc_bps * x->rc_pct / 100) : x->rc_bps;
    c.fps_num = x->framerate & 0xffff;
    c.fps_den = x->framerate >> 16;
    if (!c.fps_den)
        c.fps_den = 1;
    c.gop = gop;
    c.qp = x->qp;
    c.buffer = x->hrd_size;

    VAStatus st;
    if (!x->enc_created || memcmp(&c, &x->sent, sizeof(c)) != 0) {
        uint32_t w[14] = { x->id, c.codec, c.width, c.height, c.depth, c.profile, c.rc, c.bitrate, c.maxrate,
                           c.fps_num, c.fps_den, c.gop, c.qp, c.buffer };
        st = vt_call_words(&d->rpc, x->enc_created ? VT_ENCODER_CONFIGURE : VT_ENCODER_CREATE, w, 14, NULL, 0, NULL);
        if (st != VA_STATUS_SUCCESS)
            return st;
        x->enc_created = 1;
        x->sent = c;
    }

    /* Answered when VideoToolbox finishes the frame; vaSyncBuffer/vaMapBuffer collect it. */
    wait_encode(d, coded);
    uint32_t w[3] = { x->id, s->id, x->idr ? 1u : 0u };
    struct iovec req = { w, sizeof(w) };
    memset(&coded->encode, 0, sizeof(coded->encode));
    coded->encode.rep[0] = (struct iovec){ &coded->key, 4 };
    coded->encode.rep[1] = (struct iovec){ coded->data, coded->size * (coded->num_elements ? coded->num_elements : 1) };
    coded->encode.nrep = 2;
    coded->enc_context = x->id;
    coded->enc_input = s->id;
    coded->seg.size = 0;
    st = vt_send(&d->rpc, VT_ENCODE, &req, 1, &coded->encode);
    coded->encoding = st == VA_STATUS_SUCCESS;
    return st;
}

static VAStatus mdock_EndPicture(VADriverContextP ctx, VAContextID context)
{
    driver *d = DRV(ctx);
    LOCK(d);
    context_obj *x = obj_get(d, OBJ_CONTEXT, context);
    VAStatus st = !x ? VA_STATUS_ERROR_INVALID_CONTEXT : !x->codec ? end_process(d, x)
                : x->encode ? end_encode(d, x) : end_decode(d, x);
    UNLOCK(d);
    return st;
}

/* ---- images ---- */

static const VAImageFormat image_formats[] = {
    { VA_FOURCC_NV12, VA_LSB_FIRST, 12, 0, 0, 0, 0, 0, { 0 } },
    { VA_FOURCC_P010, VA_LSB_FIRST, 24, 0, 0, 0, 0, 0, { 0 } },
    { VA_FOURCC_I420, VA_LSB_FIRST, 12, 0, 0, 0, 0, 0, { 0 } },
    { VA_FOURCC_YV12, VA_LSB_FIRST, 12, 0, 0, 0, 0, 0, { 0 } },
};

static VAStatus mdock_QueryImageFormats(VADriverContextP ctx, VAImageFormat *list, int *num)
{
    (void)ctx;
    memcpy(list, image_formats, sizeof(image_formats));
    *num = sizeof(image_formats) / sizeof(image_formats[0]);
    return VA_STATUS_SUCCESS;
}

/* Fills image layout for w×h; returns data size. */
static unsigned image_layout(VAImage *img, uint32_t fourcc, int w, int h)
{
    int cw = (w + 1) / 2, ch = (h + 1) / 2;
    img->width = w;
    img->height = h;
    switch (fourcc) {
    case VA_FOURCC_NV12:
    case VA_FOURCC_P010: {
        int bps = fourcc == VA_FOURCC_P010 ? 2 : 1;
        img->num_planes = 2;
        img->pitches[0] = w * bps;
        img->pitches[1] = cw * 2 * bps;
        img->offsets[0] = 0;
        img->offsets[1] = img->pitches[0] * h;
        return img->offsets[1] + img->pitches[1] * ch;
    }
    case VA_FOURCC_I420:
    case VA_FOURCC_YV12:
        img->num_planes = 3;
        img->pitches[0] = w;
        img->pitches[1] = img->pitches[2] = cw;
        img->offsets[0] = 0;
        img->offsets[1] = w * h;
        img->offsets[2] = img->offsets[1] + cw * ch;
        return img->offsets[2] + cw * ch;
    default:
        return 0;
    }
}

static VAStatus mdock_CreateImage(VADriverContextP ctx, VAImageFormat *format, int width, int height, VAImage *out)
{
    driver *d = DRV(ctx);
    image_obj *im = calloc(1, sizeof(*im));
    VAImage *img = &im->image;
    img->format = *format;
    unsigned size = image_layout(img, format->fourcc, width, height);
    if (!size) {
        free(im);
        return VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
    }
    img->data_size = size;
    im->derived_from = VA_INVALID_ID;
    VABufferID buf;
    VAStatus st = mdock_CreateBuffer(ctx, 0, VAImageBufferType, size, 1, NULL, &buf);
    if (st != VA_STATUS_SUCCESS) {
        free(im);
        return st;
    }
    img->buf = buf;
    LOCK(d);
    img->image_id = obj_add(d, OBJ_IMAGE, im);
    UNLOCK(d);
    *out = *img;
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_DeriveImage(VADriverContextP ctx, VASurfaceID surface, VAImage *out)
{
    driver *d = DRV(ctx);
    LOCK(d);
    surface_obj *s = obj_get(d, OBJ_SURFACE, surface);
    if (!s) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_SURFACE;
    }
    if (surface_alloc_mirror(s) < 0) {
        UNLOCK(d);
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    }
    image_obj *im = calloc(1, sizeof(*im));
    buffer_obj *b = calloc(1, sizeof(*b));
    VAImage *img = &im->image;
    for (size_t i = 0; i < sizeof(image_formats) / sizeof(image_formats[0]); i++)
        if (image_formats[i].fourcc == s->fourcc)
            img->format = image_formats[i];
    img->data_size = image_layout(img, s->fourcc, s->width, s->height);
    b->type = VAImageBufferType;
    b->size = img->data_size;
    b->num_elements = 1;
    b->data = s->mirror;
    b->derived = s;
    img->buf = obj_add(d, OBJ_BUFFER, b);
    im->derived_from = surface;
    img->image_id = obj_add(d, OBJ_IMAGE, im);
    s->derived = img->image_id;
    *out = *img;
    UNLOCK(d);
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_DestroyImage(VADriverContextP ctx, VAImageID id)
{
    driver *d = DRV(ctx);
    LOCK(d);
    image_obj *im = obj_get(d, OBJ_IMAGE, id);
    if (!im) {
        UNLOCK(d);
        return VA_STATUS_ERROR_INVALID_IMAGE;
    }
    obj_del(d, OBJ_IMAGE, id);
    buffer_obj *b = obj_get(d, OBJ_BUFFER, im->image.buf);
    obj_del(d, OBJ_BUFFER, im->image.buf);
    surface_obj *s = obj_get(d, OBJ_SURFACE, im->derived_from);
    if (s && s->derived == id)
        s->derived = VA_INVALID_ID;
    UNLOCK(d);
    if (b)
        buffer_free(b);
    free(im);
    return VA_STATUS_SUCCESS;
}

/* Copies a rectangle between a packed NV12/P010 surface mirror and an image. to_image selects the
 * direction. Planar 8-bit images are (de)interleaved on the fly. */
static void copy_rect(surface_obj *s, VAImage *img, uint8_t *idata, int sx, int sy, int ix, int iy, int w, int h,
                      int to_image)
{
    int bps = s->bps;
    size_t ypitch = (size_t)s->width * bps, uvpitch = (size_t)((s->width + 1) & ~1) * bps;
    uint8_t *ybase = s->mirror, *uvbase = s->mirror + ypitch * s->height;
    for (int r = 0; r < h; r++) {
        uint8_t *sp = ybase + (size_t)(sy + r) * ypitch + (size_t)sx * bps;
        uint8_t *ip = idata + img->offsets[0] + (size_t)(iy + r) * img->pitches[0] + (size_t)ix * bps;
        if (to_image)
            memcpy(ip, sp, (size_t)w * bps);
        else
            memcpy(sp, ip, (size_t)w * bps);
    }
    int csx = sx / 2, csy = sy / 2, cix = ix / 2, ciy = iy / 2, cw = (w + 1) / 2, ch = (h + 1) / 2;
    for (int r = 0; r < ch; r++) {
        uint8_t *sp = uvbase + (size_t)(csy + r) * uvpitch + (size_t)csx * 2 * bps;
        if (img->format.fourcc == VA_FOURCC_NV12 || img->format.fourcc == VA_FOURCC_P010) {
            uint8_t *ip = idata + img->offsets[1] + (size_t)(ciy + r) * img->pitches[1] + (size_t)cix * 2 * bps;
            if (to_image)
                memcpy(ip, sp, (size_t)cw * 2 * bps);
            else
                memcpy(sp, ip, (size_t)cw * 2 * bps);
        } else {
            int ui = img->format.fourcc == VA_FOURCC_I420 ? 1 : 2, vi = 3 - ui;
            uint8_t *up = idata + img->offsets[ui] + (size_t)(ciy + r) * img->pitches[ui] + cix;
            uint8_t *vp = idata + img->offsets[vi] + (size_t)(ciy + r) * img->pitches[vi] + cix;
            for (int c = 0; c < cw; c++) {
                if (to_image) {
                    up[c] = sp[2 * c];
                    vp[c] = sp[2 * c + 1];
                } else {
                    sp[2 * c] = up[c];
                    sp[2 * c + 1] = vp[c];
                }
            }
        }
    }
}

static int image_compatible(surface_obj *s, VAImage *img)
{
    uint32_t f = img->format.fourcc;
    if (s->fourcc == VA_FOURCC_P010)
        return f == VA_FOURCC_P010;
    return f == VA_FOURCC_NV12 || f == VA_FOURCC_I420 || f == VA_FOURCC_YV12;
}

static VAStatus mdock_GetImage(VADriverContextP ctx, VASurfaceID surface, int x, int y, unsigned int width,
                               unsigned int height, VAImageID image)
{
    driver *d = DRV(ctx);
    LOCK(d);
    surface_obj *s = obj_get(d, OBJ_SURFACE, surface);
    image_obj *im = obj_get(d, OBJ_IMAGE, image);
    buffer_obj *b = im ? obj_get(d, OBJ_BUFFER, im->image.buf) : NULL;
    VAStatus st = VA_STATUS_SUCCESS;
    if (!s || !im || !b) {
        st = !s ? VA_STATUS_ERROR_INVALID_SURFACE : VA_STATUS_ERROR_INVALID_IMAGE;
    } else if (!image_compatible(s, &im->image)) {
        st = VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
    } else if (x < 0 || y < 0 || x + width > (unsigned)s->width || y + height > (unsigned)s->height ||
               width > im->image.width || height > im->image.height) {
        st = VA_STATUS_ERROR_INVALID_PARAMETER;
    } else if ((st = surface_fetch(d, s)) == VA_STATUS_SUCCESS) {
        copy_rect(s, &im->image, b->data, x, y, 0, 0, width, height, 1);
    }
    UNLOCK(d);
    return st;
}

static VAStatus mdock_PutImage(VADriverContextP ctx, VASurfaceID surface, VAImageID image, int sx, int sy,
                               unsigned int sw, unsigned int sh, int dx, int dy, unsigned int dw, unsigned int dh)
{
    driver *d = DRV(ctx);
    if (sw != dw || sh != dh)
        return VA_STATUS_ERROR_UNIMPLEMENTED;   /* no scaling */
    LOCK(d);
    surface_obj *s = obj_get(d, OBJ_SURFACE, surface);
    image_obj *im = obj_get(d, OBJ_IMAGE, image);
    buffer_obj *b = im ? obj_get(d, OBJ_BUFFER, im->image.buf) : NULL;
    VAStatus st = VA_STATUS_SUCCESS;
    if (!s || !im || !b) {
        st = !s ? VA_STATUS_ERROR_INVALID_SURFACE : VA_STATUS_ERROR_INVALID_IMAGE;
    } else if (!image_compatible(s, &im->image)) {
        st = VA_STATUS_ERROR_INVALID_IMAGE_FORMAT;
    } else if (sx < 0 || sy < 0 || dx < 0 || dy < 0 || dx + dw > (unsigned)s->width || dy + dh > (unsigned)s->height ||
               sx + sw > im->image.width || sy + sh > im->image.height) {
        st = VA_STATUS_ERROR_INVALID_PARAMETER;
    } else {
        int full = dx == 0 && dy == 0 && dw == (unsigned)s->width && dh == (unsigned)s->height;
        if (full)
            surface_alloc_mirror(s);
        if (!full || !s->mirror)
            st = surface_fetch(d, s);
        if (st == VA_STATUS_SUCCESS && s->mirror) {
            copy_rect(s, &im->image, b->data, dx, dy, sx, sy, dw, dh, 0);
            st = surface_push(d, s);
        }
    }
    UNLOCK(d);
    return st;
}

/* ---- unsupported features ---- */

static VAStatus mdock_Unimplemented(void)
{
    return VA_STATUS_ERROR_UNIMPLEMENTED;
}

static VAStatus mdock_QuerySubpictureFormats(VADriverContextP ctx, VAImageFormat *list, unsigned int *flags,
                                             unsigned int *num)
{
    (void)ctx;
    (void)list;
    (void)flags;
    *num = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_QueryDisplayAttributes(VADriverContextP ctx, VADisplayAttribute *list, int *num)
{
    (void)ctx;
    (void)list;
    *num = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus mdock_Terminate(VADriverContextP ctx)
{
    driver *d = DRV(ctx);
    /* First: outstanding requests point into the objects freed below. The host frees its side
     * when the socket closes. */
    if (d->frame_fd >= 0)
        close(d->frame_fd);
    vt_close(&d->rpc);
    for (int t = 1; t < OBJ_TYPES; t++) {
        for (uint32_t i = 0; i < d->tables[t].cap; i++) {
            void *p = d->tables[t].items[i];
            if (!p)
                continue;
            if (t == OBJ_BUFFER)
                buffer_free(p);
            else if (t == OBJ_SURFACE)
                free(((surface_obj *)p)->mirror), free(p);
            else if (t == OBJ_CONTEXT) {
                context_obj *x = p;
                if (x->codec == VT_CODEC_H264)
                    h264_free(&x->h264);
                else if (x->codec == VT_CODEC_HEVC)
                    hevc_free(&x->hevc);
                bb_free(&x->params);
                bb_free(&x->slices);
                free(x->slice_params);
                free(x);
            } else {
                free(p);
            }
        }
        free(d->tables[t].items);
    }
    pthread_mutex_destroy(&d->lock);
    free(d);
    ctx->pDriverData = NULL;
    return VA_STATUS_SUCCESS;
}

#define DRIVER_INIT_NAME(maj, min) __vaDriverInit_##maj##_##min
#define DRIVER_INIT(maj, min) DRIVER_INIT_NAME(maj, min)

VAStatus DRIVER_INIT(VA_MAJOR_VERSION, VA_MINOR_VERSION)(VADriverContextP ctx);
__attribute__((visibility("default")))
VAStatus DRIVER_INIT(VA_MAJOR_VERSION, VA_MINOR_VERSION)(VADriverContextP ctx)
{
    driver *d = calloc(1, sizeof(*d));
    if (!d)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    d->debug = getenv("MDOCK_VA_DEBUG") != NULL;
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&d->lock, &attr);
    pthread_mutexattr_destroy(&attr);

    if (vt_connect(&d->rpc) < 0) {
        fprintf(stderr, "mdock-va: cannot reach the mdock-vt host service (%s); "
                        "run the container with --device mdock.dev/media=vaapi\n",
                getenv("MDOCK_VT_TCP") ? getenv("MDOCK_VT_TCP") : getenv("MDOCK_VT_SOCKET") ? getenv("MDOCK_VT_SOCKET") : "/run/mdock/accel/vt.sock");
        free(d);
        return VA_STATUS_ERROR_OPERATION_FAILED;
    }
    /* Frame files: a host directory mounted into the container (MDOCK_VT_FRAMES), read and
     * written with O_DIRECT, which is coherent on virtiofs and much faster than the relay. */
    const char *frames = getenv("MDOCK_VT_FRAMES");
    struct stat sb;
    if (!frames && stat("/run/mdock/vt-frames", &sb) == 0)
        frames = "/run/mdock/vt-frames";
    if (frames && !*frames)
        frames = NULL;
    d->frame_fd = -1;
    uint32_t hello[2] = { VT_VERSION, frames ? 1u : 0u };
    struct {
        uint32_t version, caps, max_w, max_h, name_len;
        char name[256];
    } reply;
    memset(&reply, 0, sizeof(reply));
    size_t len = 0;
    if (vt_call_words(&d->rpc, VT_HELLO, hello, 2, &reply, sizeof(reply) - 1, &len) != VA_STATUS_SUCCESS || len < 8) {
        fprintf(stderr, "mdock-va: host service handshake failed\n");
        vt_close(&d->rpc);
        free(d);
        return VA_STATUS_ERROR_OPERATION_FAILED;
    }
    d->caps = reply.caps;
    if (frames && len >= 20 && reply.name_len > 0 && reply.name_len < sizeof(reply.name) && !strchr(reply.name, '/')) {
        char path[512];
        reply.name[reply.name_len] = 0;
        snprintf(path, sizeof(path), "%s/%s", frames, reply.name);
        d->frame_fd = open(path, O_RDWR | O_DIRECT | O_CLOEXEC);
        if (d->frame_fd < 0)
            dbg(d, "frame file %s: %s; pixels go over the socket", path, strerror(errno));
    }
    dbg(d, "connected to %s, host protocol %u, caps %#x, frame file %s", d->rpc.endpoint, reply.version, d->caps,
        d->frame_fd >= 0 ? "yes" : "no");

    ctx->pDriverData = d;
    ctx->version_major = VA_MAJOR_VERSION;
    ctx->version_minor = VA_MINOR_VERSION;
    ctx->max_profiles = MAX_PROFILES;
    ctx->max_entrypoints = MAX_ENTRYPOINTS;
    ctx->max_attributes = MAX_ATTRIBUTES;
    ctx->max_image_formats = MAX_IMAGE_FORMATS;
    ctx->max_subpic_formats = 1;
    ctx->max_display_attributes = 1;
    ctx->str_vendor = VENDOR;

    struct VADriverVTable *v = ctx->vtable;
    v->vaTerminate = mdock_Terminate;
    v->vaQueryConfigProfiles = mdock_QueryConfigProfiles;
    v->vaQueryConfigEntrypoints = mdock_QueryConfigEntrypoints;
    v->vaGetConfigAttributes = mdock_GetConfigAttributes;
    v->vaCreateConfig = mdock_CreateConfig;
    v->vaDestroyConfig = mdock_DestroyConfig;
    v->vaQueryConfigAttributes = mdock_QueryConfigAttributes;
    v->vaCreateSurfaces = mdock_CreateSurfaces;
    v->vaCreateSurfaces2 = mdock_CreateSurfaces2;
    v->vaDestroySurfaces = mdock_DestroySurfaces;
    v->vaCreateContext = mdock_CreateContext;
    v->vaDestroyContext = mdock_DestroyContext;
    v->vaCreateBuffer = mdock_CreateBuffer;
    v->vaBufferSetNumElements = mdock_BufferSetNumElements;
    v->vaMapBuffer = mdock_MapBuffer;
    v->vaUnmapBuffer = mdock_UnmapBuffer;
    v->vaDestroyBuffer = mdock_DestroyBuffer;
    v->vaBufferInfo = mdock_BufferInfo;
    v->vaBeginPicture = mdock_BeginPicture;
    v->vaRenderPicture = mdock_RenderPicture;
    v->vaEndPicture = mdock_EndPicture;
    v->vaSyncSurface = mdock_SyncSurface;
    v->vaSyncSurface2 = mdock_SyncSurface2;
    v->vaSyncBuffer = mdock_SyncBuffer;
    v->vaQuerySurfaceStatus = mdock_QuerySurfaceStatus;
    v->vaQuerySurfaceAttributes = mdock_QuerySurfaceAttributes;
    v->vaQueryImageFormats = mdock_QueryImageFormats;
    v->vaCreateImage = mdock_CreateImage;
    v->vaDeriveImage = mdock_DeriveImage;
    v->vaDestroyImage = mdock_DestroyImage;
    v->vaGetImage = mdock_GetImage;
    v->vaPutImage = mdock_PutImage;
    v->vaQuerySubpictureFormats = mdock_QuerySubpictureFormats;
    v->vaQueryDisplayAttributes = mdock_QueryDisplayAttributes;
    v->vaQuerySurfaceError = (void *)mdock_Unimplemented;
    v->vaPutSurface = (void *)mdock_Unimplemented;
    v->vaSetImagePalette = (void *)mdock_Unimplemented;
    v->vaCreateSubpicture = (void *)mdock_Unimplemented;
    v->vaDestroySubpicture = (void *)mdock_Unimplemented;
    v->vaSetSubpictureImage = (void *)mdock_Unimplemented;
    v->vaSetSubpictureChromakey = (void *)mdock_Unimplemented;
    v->vaSetSubpictureGlobalAlpha = (void *)mdock_Unimplemented;
    v->vaAssociateSubpicture = (void *)mdock_Unimplemented;
    v->vaDeassociateSubpicture = (void *)mdock_Unimplemented;
    v->vaGetDisplayAttributes = (void *)mdock_Unimplemented;
    v->vaSetDisplayAttributes = (void *)mdock_Unimplemented;
    v->vaLockSurface = (void *)mdock_Unimplemented;
    v->vaUnlockSurface = (void *)mdock_Unimplemented;
    v->vaAcquireBufferHandle = (void *)mdock_Unimplemented;
    v->vaReleaseBufferHandle = (void *)mdock_Unimplemented;
    v->vaExportSurfaceHandle = (void *)mdock_Unimplemented;

    struct VADriverVTableVPP *vpp = ctx->vtable_vpp;
    if (vpp) {
        vpp->version = VA_DRIVER_VTABLE_VPP_VERSION;
        vpp->vaQueryVideoProcFilters = mdock_QueryVideoProcFilters;
        vpp->vaQueryVideoProcFilterCaps = mdock_QueryVideoProcFilterCaps;
        vpp->vaQueryVideoProcPipelineCaps = mdock_QueryVideoProcPipelineCaps;
    }
    return VA_STATUS_SUCCESS;
}
