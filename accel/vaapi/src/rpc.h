/* Client side of the mdock-vt wire protocol (accel/vaapi/PROTOCOL.md). */
#ifndef MDOCK_RPC_H
#define MDOCK_RPC_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/uio.h>

#define VT_MAGIC 0x5456444Du
#define VT_VERSION 2
#define VT_REPLY_BIT 0x8000

enum vt_op {
    VT_HELLO = 1,
    VT_SURFACE_CREATE = 2,
    VT_SURFACE_DESTROY = 3,
    VT_SURFACE_PUT = 4,
    VT_SURFACE_GET = 5,
    VT_DECODER_CREATE = 6,
    VT_DECODE = 7,
    VT_CONTEXT_DESTROY = 8,
    VT_ENCODER_CREATE = 9,
    VT_ENCODE = 10,
    VT_ENCODER_CONFIGURE = 11,
    VT_BENCH = 12,
    VT_SURFACE_COPY = 13,
    VT_PROCESS = 14,
    VT_ENCODER_FLUSH = 15,
};

enum vt_caps {
    VT_CAP_H264_DEC = 1 << 0,
    VT_CAP_HEVC_DEC = 1 << 1,
    VT_CAP_HEVC10_DEC = 1 << 2,
    VT_CAP_H264_ENC = 1 << 3,
    VT_CAP_HEVC_ENC = 1 << 4,
    VT_CAP_HEVC10_ENC = 1 << 5,
};

enum vt_codec { VT_CODEC_H264 = 1, VT_CODEC_HEVC = 2 };

/* A request whose reply is read later. The reply payload is scattered over rep[] (excess
 * discarded); the targets must stay valid until the reply has been read. */
typedef struct vt_pending {
    uint16_t tag;
    int done;
    uint32_t status;
    size_t len;
    struct iovec rep[2];
    int nrep;
    struct vt_pending *next;
} vt_pending;

typedef struct {
    int fd;
    pthread_mutex_t lock;
    uint16_t next_tag;
    vt_pending *pending;    /* outstanding requests, oldest first */
    char endpoint[160];
} vt_rpc;

/* Connects to MDOCK_VT_TCP (ip:port), MDOCK_VT_SOCKET, or /run/mdock/accel/vt.sock. */
int vt_connect(vt_rpc *rpc);
void vt_close(vt_rpc *rpc);

/* Sends one request and waits for its reply (reading any earlier replies on the way).
 * Returns the reply status (a VAStatus) or VA_STATUS_ERROR_OPERATION_FAILED on I/O errors. */
uint32_t vt_call(vt_rpc *rpc, uint16_t op, const struct iovec *req, int nreq,
                 const struct iovec *rep, int nrep, size_t *rep_len);

/* Convenience for requests made of 32-bit words with an optional small reply. */
uint32_t vt_call_words(vt_rpc *rpc, uint16_t op, const uint32_t *words, int nwords,
                       void *rep, size_t rep_cap, size_t *rep_len);

/* Sends a request without waiting. p (caller-owned, with rep/nrep filled in) is completed when
 * its reply arrives during a later call or vt_wait(). */
uint32_t vt_send(vt_rpc *rpc, uint16_t op, const struct iovec *req, int nreq, vt_pending *p);

/* Reads replies until p is complete. timeout_ms < 0 waits forever. Returns 0, 1 on timeout, or
 * -1 on I/O errors (p is then completed with an error status). */
int vt_wait(vt_rpc *rpc, vt_pending *p, int timeout_ms);

#endif
