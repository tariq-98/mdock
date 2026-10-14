/* Bit reader/writer and NAL emulation-prevention helpers for H.264/HEVC headers. */
#ifndef MDOCK_BITS_H
#define MDOCK_BITS_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint8_t *buf;
    size_t cap;   /* bytes */
    size_t pos;   /* bits written */
    int overflow;
} bitwriter;

void bw_init(bitwriter *w, uint8_t *buf, size_t cap);
void bw_u(bitwriter *w, uint32_t v, int n);
void bw_ue(bitwriter *w, uint32_t v);
void bw_se(bitwriter *w, int32_t v);
/* rbsp_trailing_bits() / byte_alignment(): a one bit, then zeros to the byte boundary. */
void bw_trailing(bitwriter *w);
size_t bw_bytes(const bitwriter *w);

typedef struct {
    const uint8_t *buf;
    size_t len;   /* bytes */
    size_t pos;   /* bits read */
    int overflow;
} bitreader;

void br_init(bitreader *r, const uint8_t *buf, size_t len);
uint32_t br_u(bitreader *r, int n);
uint32_t br_ue(bitreader *r);
int32_t br_se(bitreader *r);
void br_skip(bitreader *r, size_t n);
/* Copies bits [from, to) of r into w. */
void bits_copy(bitwriter *w, const bitreader *r, size_t from, size_t to);

/* Removes emulation-prevention bytes. epb[] (may be NULL) receives the RBSP offset of the byte
 * that followed each removed 0x03; *nepb their count (at most epb_cap are stored). */
size_t nal_unescape(const uint8_t *src, size_t n, uint8_t *dst, uint32_t *epb, size_t epb_cap, size_t *nepb);
/* Inserts emulation-prevention bytes; dst needs room for n + n/2 bytes. */
size_t nal_escape(const uint8_t *src, size_t n, uint8_t *dst);

/* Ceil(Log2(v)) as the specs use it for u(v) field widths. */
int ceil_log2(uint32_t v);

#endif
