#include "bits.h"

#include <string.h>

void bw_init(bitwriter *w, uint8_t *buf, size_t cap)
{
    w->buf = buf;
    w->cap = cap;
    w->pos = 0;
    w->overflow = 0;
    memset(buf, 0, cap);
}

static inline void bw_bit(bitwriter *w, uint32_t b)
{
    size_t byte = w->pos >> 3;
    if (byte >= w->cap) {
        w->overflow = 1;
        return;
    }
    if (b)
        w->buf[byte] |= (uint8_t)(0x80 >> (w->pos & 7));
    w->pos++;
}

void bw_u(bitwriter *w, uint32_t v, int n)
{
    for (int i = n - 1; i >= 0; i--)
        bw_bit(w, (v >> i) & 1);
}

void bw_ue(bitwriter *w, uint32_t v)
{
    uint64_t x = (uint64_t)v + 1;
    int len = 0;
    while ((x >> len) > 1)
        len++;
    bw_u(w, 0, len);
    for (int i = len; i >= 0; i--)
        bw_bit(w, (uint32_t)(x >> i) & 1);
}

void bw_se(bitwriter *w, int32_t v)
{
    bw_ue(w, v > 0 ? (uint32_t)(2 * v - 1) : (uint32_t)(-2 * (int64_t)v));
}

void bw_trailing(bitwriter *w)
{
    bw_bit(w, 1);
    while (w->pos & 7)
        bw_bit(w, 0);
}

size_t bw_bytes(const bitwriter *w)
{
    return (w->pos + 7) >> 3;
}

void br_init(bitreader *r, const uint8_t *buf, size_t len)
{
    r->buf = buf;
    r->len = len;
    r->pos = 0;
    r->overflow = 0;
}

static inline uint32_t br_bit(bitreader *r)
{
    size_t byte = r->pos >> 3;
    if (byte >= r->len) {
        r->overflow = 1;
        return 0;
    }
    uint32_t b = (r->buf[byte] >> (7 - (r->pos & 7))) & 1;
    r->pos++;
    return b;
}

uint32_t br_u(bitreader *r, int n)
{
    uint32_t v = 0;
    for (int i = 0; i < n; i++)
        v = (v << 1) | br_bit(r);
    return v;
}

uint32_t br_ue(bitreader *r)
{
    int zeros = 0;
    while (!br_bit(r)) {
        if (r->overflow || ++zeros > 31) {
            r->overflow = 1;
            return 0;
        }
    }
    return ((1u << zeros) - 1) + br_u(r, zeros);
}

int32_t br_se(bitreader *r)
{
    uint32_t k = br_ue(r);
    return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2);
}

void br_skip(bitreader *r, size_t n)
{
    r->pos += n;
    if ((r->pos + 7) / 8 > r->len)
        r->overflow = 1;
}

void bits_copy(bitwriter *w, const bitreader *r, size_t from, size_t to)
{
    for (size_t p = from; p < to; p++) {
        size_t byte = p >> 3;
        uint32_t b = byte < r->len ? (r->buf[byte] >> (7 - (p & 7))) & 1 : 0;
        bw_bit(w, b);
    }
}

size_t nal_unescape(const uint8_t *src, size_t n, uint8_t *dst, uint32_t *epb, size_t epb_cap, size_t *nepb)
{
    size_t o = 0, zeros = 0, count = 0;
    for (size_t i = 0; i < n; i++) {
        if (zeros >= 2 && src[i] == 3) {
            if (epb && count < epb_cap)
                epb[count] = (uint32_t)o;
            count++;
            zeros = 0;
            continue;
        }
        zeros = src[i] == 0 ? zeros + 1 : 0;
        dst[o++] = src[i];
    }
    if (nepb)
        *nepb = count;
    return o;
}

size_t nal_escape(const uint8_t *src, size_t n, uint8_t *dst)
{
    size_t o = 0, zeros = 0;
    for (size_t i = 0; i < n; i++) {
        if (zeros >= 2 && src[i] <= 3) {
            dst[o++] = 3;
            zeros = 0;
        }
        zeros = src[i] == 0 ? zeros + 1 : 0;
        dst[o++] = src[i];
    }
    return o;
}

int ceil_log2(uint32_t v)
{
    int n = 0;
    while ((1u << n) < v)
        n++;
    return n;
}
