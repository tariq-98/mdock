/* Rebuilds the bitstream VideoToolbox needs from VA-API decode parameters. */
#ifndef MDOCK_CODEC_H
#define MDOCK_CODEC_H

#include <stddef.h>
#include <stdint.h>
#include <va/va.h>
#include <va/va_dec_hevc.h>

/* Growable buffer of wire entries: each is a little-endian u32 length followed by the bytes. */
typedef struct {
    uint8_t *data;
    size_t len, cap;
    uint32_t count;
} bytebuf;

void bb_reset(bytebuf *b);
void bb_free(bytebuf *b);
uint8_t *bb_reserve(bytebuf *b, size_t n);
void bb_entry(bytebuf *b, const void *p, size_t n);

/* Returns a pointer to the NAL header, skipping a leading start code if the client sent one. */
const uint8_t *nal_skip_start_code(const uint8_t *p, size_t *n);

typedef struct {
    int profile_idc;             /* from the VA profile */
    int16_t l0_default[256];     /* PPS num_ref_idx defaults learned from slices, -1 unknown */
    int16_t l1_default[256];
    uint8_t *pps[256];           /* last PPS generated per id */
    size_t pps_len[256];
    uint8_t used[256];           /* ids referenced by the current picture */
} h264_state;

void h264_init(h264_state *s, VAProfile profile);
void h264_free(h264_state *s);
void h264_begin_picture(h264_state *s);
/* Parses the slice header far enough to learn its PPS id and default-ref-count usage, then
 * appends the NAL unit (unchanged) to slices. */
int h264_add_slice(h264_state *s, const VAPictureParameterBufferH264 *pic,
                   const VASliceParameterBufferH264 *sp, const uint8_t *nal, size_t len, bytebuf *slices);
/* Emits SPS and every known PPS for the current picture. */
int h264_build_params(h264_state *s, const VAPictureParameterBufferH264 *pic,
                      const VAIQMatrixBufferH264 *iq, bytebuf *params);

typedef struct {
    int profile_idc;
    uint8_t *pps[64];
    size_t pps_len[64];
    uint8_t used[64];
} hevc_state;

void hevc_init(hevc_state *s, VAProfile profile);
void hevc_free(hevc_state *s);
void hevc_begin_picture(hevc_state *s);
/* Rewrites the slice header so it carries its reference picture set explicitly (the SPS we
 * rebuild has no RPS list, because VA does not pass one), then appends it to slices. */
int hevc_add_slice(hevc_state *s, const VAPictureParameterBufferHEVC *pic,
                   const VASliceParameterBufferHEVC *sp, const uint8_t *nal, size_t len, bytebuf *slices);
int hevc_build_params(hevc_state *s, const VAPictureParameterBufferHEVC *pic,
                      const VAIQMatrixBufferHEVC *iq, bytebuf *params);

#endif
