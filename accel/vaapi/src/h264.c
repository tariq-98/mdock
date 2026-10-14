/* H.264: SPS/PPS reconstruction from VAPictureParameterBufferH264 + VAIQMatrixBufferH264.
 *
 * VA passes slices as complete NAL units (header and slice_header() included), so slices go to
 * VideoToolbox unchanged. Only the parameter sets are rebuilt. Two fields VA does not carry are
 * recovered from the slices: the PPS id (parsed from the slice header) and the PPS
 * num_ref_idx_lX_default_active_minus1 values (learned from slices that do not override them). */
#include <stdlib.h>
#include <string.h>

#include "bits.h"
#include "codec.h"

static const uint8_t zigzag4x4[16] = { 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
static const uint8_t zigzag8x8[64] = {
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
    41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
    30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

void bb_reset(bytebuf *b)
{
    b->len = 0;
    b->count = 0;
}

void bb_free(bytebuf *b)
{
    free(b->data);
    memset(b, 0, sizeof(*b));
}

uint8_t *bb_reserve(bytebuf *b, size_t n)
{
    if (b->len + n > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        while (cap < b->len + n)
            cap *= 2;
        uint8_t *d = realloc(b->data, cap);
        if (!d)
            return NULL;
        b->data = d;
        b->cap = cap;
    }
    return b->data + b->len;
}

void bb_entry(bytebuf *b, const void *p, size_t n)
{
    uint8_t *d = bb_reserve(b, n + 4);
    if (!d)
        return;
    uint32_t le = (uint32_t)n;
    memcpy(d, &le, 4);
    memcpy(d + 4, p, n);
    b->len += n + 4;
    b->count++;
}

const uint8_t *nal_skip_start_code(const uint8_t *p, size_t *n)
{
    if (*n >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) {
        *n -= 4;
        return p + 4;
    }
    if (*n >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1) {
        *n -= 3;
        return p + 3;
    }
    return p;
}

void h264_init(h264_state *s, VAProfile profile)
{
    memset(s, 0, sizeof(*s));
    switch (profile) {
    case VAProfileH264ConstrainedBaseline: s->profile_idc = 66; break;
    case VAProfileH264Main: s->profile_idc = 77; break;
    default: s->profile_idc = 100; break;
    }
    for (int i = 0; i < 256; i++)
        s->l0_default[i] = s->l1_default[i] = -1;
}

void h264_free(h264_state *s)
{
    for (int i = 0; i < 256; i++)
        free(s->pps[i]);
    memset(s, 0, sizeof(*s));
}

void h264_begin_picture(h264_state *s)
{
    memset(s->used, 0, sizeof(s->used));
}

int h264_add_slice(h264_state *s, const VAPictureParameterBufferH264 *pic,
                   const VASliceParameterBufferH264 *sp, const uint8_t *nal, size_t len, bytebuf *slices)
{
    nal = nal_skip_start_code(nal, &len);
    if (len < 2)
        return -1;
    uint8_t rbsp[96];
    size_t n = nal_unescape(nal, len < 80 ? len : 80, rbsp, NULL, 0, NULL);
    bitreader r;
    br_init(&r, rbsp, n);
    br_u(&r, 1);
    br_u(&r, 2);                    /* nal_ref_idc */
    int nal_type = br_u(&r, 5);
    br_ue(&r);                      /* first_mb_in_slice */
    int slice_type = br_ue(&r) % 5;
    uint32_t pps_id = br_ue(&r);
    if (r.overflow || pps_id > 255)
        return -1;
    s->used[pps_id] = 1;

    const __typeof__(pic->seq_fields.bits) *sf = &pic->seq_fields.bits;
    const __typeof__(pic->pic_fields.bits) *pf = &pic->pic_fields.bits;
    if (sf->residual_colour_transform_flag)
        br_u(&r, 2);                /* colour_plane_id */
    br_u(&r, sf->log2_max_frame_num_minus4 + 4);
    int field_pic = 0;
    if (!sf->frame_mbs_only_flag) {
        field_pic = br_u(&r, 1);
        if (field_pic)
            br_u(&r, 1);            /* bottom_field_flag */
    }
    if (nal_type == 5)
        br_ue(&r);                  /* idr_pic_id */
    if (sf->pic_order_cnt_type == 0) {
        br_u(&r, sf->log2_max_pic_order_cnt_lsb_minus4 + 4);
        if (pf->pic_order_present_flag && !field_pic)
            br_se(&r);
    } else if (sf->pic_order_cnt_type == 1 && !sf->delta_pic_order_always_zero_flag) {
        br_se(&r);
        if (pf->pic_order_present_flag && !field_pic)
            br_se(&r);
    }
    if (pf->redundant_pic_cnt_present_flag)
        br_ue(&r);
    if (slice_type == 1)
        br_u(&r, 1);                /* direct_spatial_mv_pred_flag */
    if (slice_type == 0 || slice_type == 1 || slice_type == 3) {
        int override = br_u(&r, 1);
        if (!override && !r.overflow) {
            s->l0_default[pps_id] = sp->num_ref_idx_l0_active_minus1;
            if (slice_type == 1)
                s->l1_default[pps_id] = sp->num_ref_idx_l1_active_minus1;
        }
    }
    bb_entry(slices, nal, len);
    return 0;
}

static int iq_is_flat(const VAIQMatrixBufferH264 *iq, int lists8)
{
    for (int i = 0; i < 6; i++)
        for (int j = 0; j < 16; j++)
            if (iq->ScalingList4x4[i][j] != 16)
                return 0;
    for (int i = 0; i < lists8; i++)
        for (int j = 0; j < 64; j++)
            if (iq->ScalingList8x8[i][j] != 16)
                return 0;
    return 1;
}

static void write_scaling_list(bitwriter *w, const uint8_t *list, const uint8_t *scan, int n)
{
    int last = 8;
    bw_u(w, 1, 1);                  /* scaling_list_present_flag */
    for (int i = 0; i < n; i++) {
        int v = list[scan[i]];
        int delta = ((v - last + 128) & 255) - 128;
        bw_se(w, delta);
        last = v;
    }
}

static size_t finish_nal(bitwriter *w, uint8_t *out)
{
    bw_trailing(w);
    return nal_escape(w->buf, bw_bytes(w), out);
}

static int level_for(int mbs)
{
    if (mbs <= 8192)
        return 41;
    if (mbs <= 36864)
        return 51;
    return 60;
}

int h264_build_params(h264_state *s, const VAPictureParameterBufferH264 *pic,
                      const VAIQMatrixBufferH264 *iq, bytebuf *params)
{
    uint8_t raw[1024], out[1600];
    bitwriter w;
    const __typeof__(pic->seq_fields.bits) *sf = &pic->seq_fields.bits;
    const __typeof__(pic->pic_fields.bits) *pf = &pic->pic_fields.bits;
    int width_mbs = pic->picture_width_in_mbs_minus1 + 1;
    int height_mbs = pic->picture_height_in_mbs_minus1 + 1;   /* frame height (ffmpeg, gstreamer) */
    int profile = s->profile_idc;
    if (profile == 100 && (pic->bit_depth_luma_minus8 || pic->bit_depth_chroma_minus8))
        profile = 110;
    if (profile == 100 && sf->chroma_format_idc == 2)
        profile = 122;

    /* seq_parameter_set_rbsp() */
    bw_init(&w, raw, sizeof(raw));
    bw_u(&w, 0x67, 8);
    bw_u(&w, profile, 8);
    bw_u(&w, profile == 66 ? 0xC0 : 0, 8);   /* constraint_set0/1 for constrained baseline */
    bw_u(&w, level_for(width_mbs * height_mbs), 8);
    bw_ue(&w, 0);                            /* seq_parameter_set_id */
    if (profile >= 100) {
        bw_ue(&w, sf->chroma_format_idc);
        if (sf->chroma_format_idc == 3)
            bw_u(&w, sf->residual_colour_transform_flag, 1);
        bw_ue(&w, pic->bit_depth_luma_minus8);
        bw_ue(&w, pic->bit_depth_chroma_minus8);
        bw_u(&w, 0, 1);                      /* qpprime_y_zero_transform_bypass_flag */
        bw_u(&w, 0, 1);                      /* seq_scaling_matrix_present_flag: lists go in the PPS */
    }
    bw_ue(&w, sf->log2_max_frame_num_minus4);
    bw_ue(&w, sf->pic_order_cnt_type);
    if (sf->pic_order_cnt_type == 0) {
        bw_ue(&w, sf->log2_max_pic_order_cnt_lsb_minus4);
    } else if (sf->pic_order_cnt_type == 1) {
        /* The POC cycle offsets are not in VA; zero keeps slice parsing correct. */
        bw_u(&w, sf->delta_pic_order_always_zero_flag, 1);
        bw_se(&w, 0);
        bw_se(&w, 0);
        bw_ue(&w, 0);
    }
    bw_ue(&w, pic->num_ref_frames);
    bw_u(&w, sf->gaps_in_frame_num_value_allowed_flag, 1);
    bw_ue(&w, width_mbs - 1);
    bw_ue(&w, (sf->frame_mbs_only_flag ? height_mbs : (height_mbs + 1) / 2) - 1);
    bw_u(&w, sf->frame_mbs_only_flag, 1);
    if (!sf->frame_mbs_only_flag)
        bw_u(&w, sf->mb_adaptive_frame_field_flag, 1);
    bw_u(&w, sf->direct_8x8_inference_flag, 1);
    bw_u(&w, 0, 1);                          /* frame_cropping_flag */
    bw_u(&w, 0, 1);                          /* vui_parameters_present_flag */
    if (w.overflow)
        return -1;
    bb_entry(params, out, finish_nal(&w, out));

    /* pic_parameter_set_rbsp() for every id this picture uses */
    int lists8 = pf->transform_8x8_mode_flag ? 2 : 0;
    int scaling = iq && profile >= 100 && !iq_is_flat(iq, lists8);
    for (int id = 0; id < 256; id++) {
        if (!s->used[id])
            continue;
        bw_init(&w, raw, sizeof(raw));
        bw_u(&w, 0x68, 8);
        bw_ue(&w, id);
        bw_ue(&w, 0);
        bw_u(&w, pf->entropy_coding_mode_flag, 1);
        bw_u(&w, pf->pic_order_present_flag, 1);
        bw_ue(&w, 0);                        /* num_slice_groups_minus1 */
        bw_ue(&w, s->l0_default[id] < 0 ? 0 : s->l0_default[id]);
        bw_ue(&w, s->l1_default[id] < 0 ? 0 : s->l1_default[id]);
        bw_u(&w, pf->weighted_pred_flag, 1);
        bw_u(&w, pf->weighted_bipred_idc, 2);
        bw_se(&w, pic->pic_init_qp_minus26);
        bw_se(&w, pic->pic_init_qs_minus26);
        bw_se(&w, pic->chroma_qp_index_offset);
        bw_u(&w, pf->deblocking_filter_control_present_flag, 1);
        bw_u(&w, pf->constrained_intra_pred_flag, 1);
        bw_u(&w, pf->redundant_pic_cnt_present_flag, 1);
        if (pf->transform_8x8_mode_flag || scaling || pic->second_chroma_qp_index_offset != pic->chroma_qp_index_offset) {
            bw_u(&w, pf->transform_8x8_mode_flag, 1);
            bw_u(&w, scaling, 1);
            if (scaling) {
                for (int i = 0; i < 6; i++)
                    write_scaling_list(&w, iq->ScalingList4x4[i], zigzag4x4, 16);
                for (int i = 0; i < lists8; i++)
                    write_scaling_list(&w, iq->ScalingList8x8[i], zigzag8x8, 64);
            }
            bw_se(&w, pic->second_chroma_qp_index_offset);
        }
        if (w.overflow)
            return -1;
        size_t n = finish_nal(&w, out);
        uint8_t *copy = realloc(s->pps[id], n);
        if (copy) {
            memcpy(copy, out, n);
            s->pps[id] = copy;
            s->pps_len[id] = n;
        }
    }
    for (int id = 0; id < 256; id++)
        if (s->pps[id])
            bb_entry(params, s->pps[id], s->pps_len[id]);
    return 0;
}
