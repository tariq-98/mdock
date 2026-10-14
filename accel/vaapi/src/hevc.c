/* HEVC: VPS/SPS/PPS reconstruction from VAPictureParameterBufferHEVC, plus slice header rewriting.
 *
 * VA does not pass the SPS short-term RPS list (or the SPS long-term POC list), and slices often
 * refer to entries of it by index. The rebuilt SPS therefore has no RPS list, and every slice that
 * used one gets its header rewritten with an explicit st_ref_pic_set() derived from
 * ReferenceFrames[] (which lists every picture of the current RPS with its POC and whether the
 * current picture uses it). The rest of the header is bit-copied; slice data is untouched. */
#include <stdlib.h>
#include <string.h>

#include "bits.h"
#include "codec.h"

void hevc_init(hevc_state *s, VAProfile profile)
{
    memset(s, 0, sizeof(*s));
    s->profile_idc = profile == VAProfileHEVCMain10 ? 2 : 1;
}

void hevc_free(hevc_state *s)
{
    for (int i = 0; i < 64; i++)
        free(s->pps[i]);
    memset(s, 0, sizeof(*s));
}

void hevc_begin_picture(hevc_state *s)
{
    memset(s->used, 0, sizeof(s->used));
}

typedef struct {
    int poc;
    int used;
} rps_entry;

static int cmp_desc(const void *a, const void *b)
{
    return ((const rps_entry *)b)->poc - ((const rps_entry *)a)->poc;
}

static int cmp_asc(const void *a, const void *b)
{
    return ((const rps_entry *)a)->poc - ((const rps_entry *)b)->poc;
}

#define RPS_CURR (VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE | VA_PICTURE_HEVC_RPS_ST_CURR_AFTER | VA_PICTURE_HEVC_RPS_LT_CURR)

static int valid_ref(const VAPictureHEVC *p)
{
    return p->picture_id != VA_INVALID_SURFACE && !(p->flags & VA_PICTURE_HEVC_INVALID);
}

static void skip_pred_weight_table(bitreader *r, int chroma, int b_slice, int n0, int n1)
{
    br_ue(r);                               /* luma_log2_weight_denom */
    if (chroma)
        br_se(r);
    for (int l = 0; l < (b_slice ? 2 : 1); l++) {
        int n = (l ? n1 : n0) + 1;
        uint8_t lw[16] = { 0 }, cw[16] = { 0 };
        for (int i = 0; i < n && i < 16; i++)
            lw[i] = br_u(r, 1);
        if (chroma)
            for (int i = 0; i < n && i < 16; i++)
                cw[i] = br_u(r, 1);
        for (int i = 0; i < n && i < 16; i++) {
            if (lw[i]) {
                br_se(r);
                br_se(r);
            }
            if (cw[i])
                for (int j = 0; j < 4; j++)
                    br_se(r);
        }
    }
}

int hevc_add_slice(hevc_state *s, const VAPictureParameterBufferHEVC *pic,
                   const VASliceParameterBufferHEVC *sp, const uint8_t *nal, size_t len, bytebuf *slices)
{
    (void)sp;
    nal = nal_skip_start_code(nal, &len);
    if (len < 3)
        return -1;
    const __typeof__(pic->pic_fields.bits) *pf = &pic->pic_fields.bits;
    const __typeof__(pic->slice_parsing_fields.bits) *sf = &pic->slice_parsing_fields.bits;

    size_t hlen = len < 4096 ? len : 4096;
    uint8_t *rbsp = malloc(hlen);
    uint32_t epb[512];
    size_t nepb = 0;
    size_t n = nal_unescape(nal, hlen, rbsp, epb, 512, &nepb);
    bitreader r;
    br_init(&r, rbsp, n);
    int nal_type = (rbsp[0] >> 1) & 0x3f;
    br_skip(&r, 16);
    int first = br_u(&r, 1);
    if (nal_type >= 16 && nal_type <= 23)
        br_u(&r, 1);                        /* no_output_of_prior_pics_flag */
    uint32_t pps_id = br_ue(&r);
    if (r.overflow || pps_id > 63)
        goto fail;
    s->used[pps_id] = 1;

    int min_cb = pic->log2_min_luma_coding_block_size_minus3 + 3;
    int ctb = min_cb + pic->log2_diff_max_min_luma_coding_block_size;
    uint32_t ctbs = ((pic->pic_width_in_luma_samples + (1 << ctb) - 1) >> ctb)
                  * ((pic->pic_height_in_luma_samples + (1 << ctb) - 1) >> ctb);
    int dependent = 0;
    if (!first) {
        if (sf->dependent_slice_segments_enabled_flag)
            dependent = br_u(&r, 1);
        br_u(&r, ceil_log2(ctbs));
    }
    int idr = nal_type == 19 || nal_type == 20;
    if (dependent || idr || (pic->num_short_term_ref_pic_sets == 0 && pic->num_long_term_ref_pic_sps == 0)) {
        /* Nothing refers to SPS lists: pass through. */
        free(rbsp);
        bb_entry(slices, nal, len);
        return 0;
    }

    int chroma = pf->separate_colour_plane_flag ? 0 : pf->chroma_format_idc;
    int poc_bits = pic->log2_max_pic_order_cnt_lsb_minus4 + 4;
    br_skip(&r, pic->num_extra_slice_header_bits);
    int slice_type = br_ue(&r);             /* 0 B, 1 P, 2 I */
    if (sf->output_flag_present_flag)
        br_u(&r, 1);
    if (pf->separate_colour_plane_flag)
        br_u(&r, 2);
    br_u(&r, poc_bits);                     /* slice_pic_order_cnt_lsb */

    size_t pos_rps = r.pos;
    if (!br_u(&r, 1))                       /* short_term_ref_pic_set_sps_flag */
        br_skip(&r, pic->st_rps_bits);
    else if (pic->num_short_term_ref_pic_sets > 1)
        br_u(&r, ceil_log2(pic->num_short_term_ref_pic_sets));

    /* Long-term entries, made explicit (the rebuilt SPS has no lt_ref_pic_poc_lsb_sps list). */
    int nlt = 0, lt_sps = 0;
    int lt_lsb[32], lt_used[32], lt_msb[32], lt_cycle[32], lt_from_sps[32];
    if (sf->long_term_ref_pics_present_flag) {
        if (pic->num_long_term_ref_pic_sps > 0)
            lt_sps = br_ue(&r);
        nlt = lt_sps + br_ue(&r);
        if (nlt > 32)
            goto fail;
        int acc = 0;
        for (int i = 0; i < nlt; i++) {
            lt_from_sps[i] = i < lt_sps;
            lt_lsb[i] = lt_used[i] = 0;
            if (i < lt_sps) {
                if (pic->num_long_term_ref_pic_sps > 1)
                    br_u(&r, ceil_log2(pic->num_long_term_ref_pic_sps));
            } else {
                lt_lsb[i] = br_u(&r, poc_bits);
                lt_used[i] = br_u(&r, 1);
            }
            lt_msb[i] = br_u(&r, 1);
            int cycle = lt_msb[i] ? (int)br_ue(&r) : 0;
            acc = (i == 0 || i == lt_sps) ? cycle : acc + cycle;
            lt_cycle[i] = acc;              /* DeltaPocMsbCycleLt, absolute */
        }
    }
    size_t pos_after_lt = r.pos;

    /* Parse the rest only to find where the header ends. */
    int tmvp = 0, sao_l = 0, sao_c = 0;
    if (sf->sps_temporal_mvp_enabled_flag)
        tmvp = br_u(&r, 1);
    if (sf->sample_adaptive_offset_enabled_flag) {
        sao_l = br_u(&r, 1);
        if (chroma)
            sao_c = br_u(&r, 1);
    }
    int curr = 0;
    for (int i = 0; i < 15; i++)
        if (valid_ref(&pic->ReferenceFrames[i]) && (pic->ReferenceFrames[i].flags & RPS_CURR))
            curr++;
    if (slice_type == 0 || slice_type == 1) {
        int n0 = pic->num_ref_idx_l0_default_active_minus1, n1 = pic->num_ref_idx_l1_default_active_minus1;
        if (br_u(&r, 1)) {                  /* num_ref_idx_active_override_flag */
            n0 = br_ue(&r);
            if (slice_type == 0)
                n1 = br_ue(&r);
        }
        if (sf->lists_modification_present_flag && curr > 1) {
            int bits = ceil_log2(curr);
            if (br_u(&r, 1))
                br_skip(&r, (size_t)(n0 + 1) * bits);
            if (slice_type == 0 && br_u(&r, 1))
                br_skip(&r, (size_t)(n1 + 1) * bits);
        }
        if (slice_type == 0)
            br_u(&r, 1);                    /* mvd_l1_zero_flag */
        if (sf->cabac_init_present_flag)
            br_u(&r, 1);
        if (tmvp) {
            int from_l0 = slice_type == 0 ? br_u(&r, 1) : 1;
            if ((from_l0 && n0 > 0) || (!from_l0 && n1 > 0))
                br_ue(&r);
        }
        if ((pf->weighted_pred_flag && slice_type == 1) || (pf->weighted_bipred_flag && slice_type == 0))
            skip_pred_weight_table(&r, chroma, slice_type == 0, n0, n1);
        br_ue(&r);                          /* five_minus_max_num_merge_cand */
    }
    br_se(&r);                              /* slice_qp_delta */
    if (sf->pps_slice_chroma_qp_offsets_present_flag) {
        br_se(&r);
        br_se(&r);
    }
    int override = sf->deblocking_filter_override_enabled_flag ? br_u(&r, 1) : 0;
    int disabled = sf->pps_disable_deblocking_filter_flag;
    if (override) {
        disabled = br_u(&r, 1);
        if (!disabled) {
            br_se(&r);
            br_se(&r);
        }
    }
    if (pf->pps_loop_filter_across_slices_enabled_flag && (sao_l || sao_c || !disabled))
        br_u(&r, 1);
    if (pf->tiles_enabled_flag || pf->entropy_coding_sync_enabled_flag) {
        uint32_t entries = br_ue(&r);
        if (entries > 0) {
            uint32_t bits = br_ue(&r) + 1;
            br_skip(&r, (size_t)entries * bits);
        }
    }
    if (sf->slice_segment_header_extension_present_flag)
        br_skip(&r, 8 * (size_t)br_ue(&r));
    size_t pos_end = r.pos;
    if (!br_u(&r, 1) || r.overflow)         /* byte_alignment(): alignment_bit_equal_to_one */
        goto fail;
    size_t data_rbsp = (r.pos + 7) / 8;
    size_t data_raw = data_rbsp;
    for (size_t i = 0; i < nepb && i < 512; i++)
        if (epb[i] <= data_rbsp)
            data_raw++;
    if (data_raw > len)
        goto fail;

    /* Explicit short-term RPS from ReferenceFrames[]. */
    rps_entry neg[16], pos[16];
    int nneg = 0, npos = 0, nltref = 0;
    int cur_poc = pic->CurrPic.pic_order_cnt;
    int lt_poc[16], lt_curr[16];
    for (int i = 0; i < 15; i++) {
        const VAPictureHEVC *p = &pic->ReferenceFrames[i];
        if (!valid_ref(p))
            continue;
        if (p->flags & VA_PICTURE_HEVC_LONG_TERM_REFERENCE) {
            lt_poc[nltref] = p->pic_order_cnt;
            lt_curr[nltref++] = !!(p->flags & VA_PICTURE_HEVC_RPS_LT_CURR);
            continue;
        }
        rps_entry e = { p->pic_order_cnt, !!(p->flags & (VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE | VA_PICTURE_HEVC_RPS_ST_CURR_AFTER)) };
        if (e.poc < cur_poc)
            neg[nneg++] = e;
        else if (e.poc > cur_poc)
            pos[npos++] = e;
    }
    qsort(neg, nneg, sizeof(rps_entry), cmp_desc);
    qsort(pos, npos, sizeof(rps_entry), cmp_asc);

    /* Resolve SPS-indexed long-term entries against the long-term references VA lists. */
    int max_lsb = 1 << poc_bits;
    uint8_t taken[16] = { 0 };
    for (int i = 0; i < nlt; i++)
        if (!lt_from_sps[i])
            for (int j = 0; j < nltref; j++)
                if (!taken[j] && (lt_poc[j] & (max_lsb - 1)) == lt_lsb[i]) {
                    taken[j] = 1;
                    break;
                }
    for (int i = 0; i < nlt; i++) {
        if (!lt_from_sps[i])
            continue;
        for (int j = 0; j < nltref; j++)
            if (!taken[j]) {
                taken[j] = 1;
                lt_lsb[i] = lt_poc[j] & (max_lsb - 1);
                lt_used[i] = lt_curr[j];
                break;
            }
    }

    uint8_t *hdr = malloc(n + 256), *out = malloc((n + 256) * 2 + len);
    bitwriter w;
    bw_init(&w, hdr, n + 256);
    bits_copy(&w, &r, 0, pos_rps);
    bw_u(&w, 0, 1);                         /* short_term_ref_pic_set_sps_flag */
    bw_ue(&w, nneg);
    bw_ue(&w, npos);
    int prev = cur_poc;
    for (int i = 0; i < nneg; i++) {
        bw_ue(&w, prev - neg[i].poc - 1);
        bw_u(&w, neg[i].used, 1);
        prev = neg[i].poc;
    }
    prev = cur_poc;
    for (int i = 0; i < npos; i++) {
        bw_ue(&w, pos[i].poc - prev - 1);
        bw_u(&w, pos[i].used, 1);
        prev = pos[i].poc;
    }
    if (sf->long_term_ref_pics_present_flag) {
        bw_ue(&w, nlt);                     /* num_long_term_pics (num_long_term_sps is absent) */
        for (int i = 0; i < nlt; i++) {
            bw_u(&w, lt_lsb[i], poc_bits);
            bw_u(&w, lt_used[i], 1);
            bw_u(&w, lt_msb[i], 1);
            if (lt_msb[i]) {
                int d = i == 0 ? lt_cycle[0] : lt_cycle[i] - lt_cycle[i - 1];
                bw_ue(&w, d < 0 ? 0 : d);
            }
        }
    }
    bits_copy(&w, &r, pos_after_lt, pos_end);
    bw_trailing(&w);
    if (w.overflow) {
        free(hdr);
        free(out);
        goto fail;
    }
    size_t o = nal_escape(hdr, bw_bytes(&w), out);
    memcpy(out + o, nal + data_raw, len - data_raw);
    bb_entry(slices, out, o + len - data_raw);
    free(hdr);
    free(out);
    free(rbsp);
    return 0;
fail:
    free(rbsp);
    return -1;
}

static void profile_tier_level(bitwriter *w, int profile_idc, int level_idc)
{
    bw_u(w, 0, 2);                          /* general_profile_space */
    bw_u(w, 0, 1);                          /* general_tier_flag */
    bw_u(w, profile_idc, 5);
    for (int j = 0; j < 32; j++)
        bw_u(w, j == profile_idc || (profile_idc == 1 && j == 2), 1);
    bw_u(w, 1, 1);                          /* progressive_source_flag */
    bw_u(w, 0, 1);                          /* interlaced_source_flag */
    bw_u(w, 0, 1);                          /* non_packed_constraint_flag */
    bw_u(w, 1, 1);                          /* frame_only_constraint_flag */
    bw_u(w, 0, 32);                         /* 43 reserved bits + general_inbld_flag */
    bw_u(w, 0, 12);
    bw_u(w, level_idc, 8);
}

/* Up-right diagonal scan of an n×n block, as raster positions. */
static void diag_scan(int n, uint8_t *scan)
{
    int i = 0, x = 0, y = 0;
    while (i < n * n) {
        while (y >= 0) {
            if (x < n && y < n)
                scan[i++] = (uint8_t)(y * n + x);
            y--;
            x++;
        }
        y = x;
        x = 0;
    }
}

static void scaling_list_data(bitwriter *w, const VAIQMatrixBufferHEVC *iq)
{
    uint8_t scan4[16], scan8[64];
    diag_scan(4, scan4);
    diag_scan(8, scan8);
    for (int size = 0; size < 4; size++) {
        for (int m = 0; m < 6; m += size == 3 ? 3 : 1) {
            const uint8_t *list;
            int dc = -1;
            switch (size) {
            case 0: list = iq->ScalingList4x4[m]; break;
            case 1: list = iq->ScalingList8x8[m]; break;
            case 2: list = iq->ScalingList16x16[m]; dc = iq->ScalingListDC16x16[m]; break;
            default: list = iq->ScalingList32x32[m / 3]; dc = iq->ScalingListDC32x32[m / 3]; break;
            }
            bw_u(w, 1, 1);                  /* scaling_list_pred_mode_flag: explicit */
            int next = 8, count = size == 0 ? 16 : 64;
            if (dc >= 0) {
                bw_se(w, dc - 8);
                next = dc;
            }
            for (int i = 0; i < count; i++) {
                int v = list[size == 0 ? scan4[i] : scan8[i]];
                bw_se(w, ((v - next + 128) & 255) - 128);
                next = v;
            }
        }
    }
}

static size_t finish_nal(bitwriter *w, uint8_t *out)
{
    bw_trailing(w);
    return nal_escape(w->buf, bw_bytes(w), out);
}

int hevc_build_params(hevc_state *s, const VAPictureParameterBufferHEVC *pic,
                      const VAIQMatrixBufferHEVC *iq, bytebuf *params)
{
    uint8_t raw[2048], out[3100];
    bitwriter w;
    const __typeof__(pic->pic_fields.bits) *pf = &pic->pic_fields.bits;
    const __typeof__(pic->slice_parsing_fields.bits) *sf = &pic->slice_parsing_fields.bits;
    int profile = s->profile_idc;
    if (pic->bit_depth_luma_minus8 || pic->bit_depth_chroma_minus8)
        profile = 2;
    long samples = (long)pic->pic_width_in_luma_samples * pic->pic_height_in_luma_samples;
    int level = samples <= 2228224 ? 123 : samples <= 8912896 ? 153 : 183;
    int dpb = pic->sps_max_dec_pic_buffering_minus1;

    /* video_parameter_set_rbsp() */
    bw_init(&w, raw, sizeof(raw));
    bw_u(&w, 32 << 1, 8);
    bw_u(&w, 1, 8);
    bw_u(&w, 0, 4);                         /* vps_video_parameter_set_id */
    bw_u(&w, 1, 1);                         /* vps_base_layer_internal_flag */
    bw_u(&w, 1, 1);                         /* vps_base_layer_available_flag */
    bw_u(&w, 0, 6);                         /* vps_max_layers_minus1 */
    bw_u(&w, 0, 3);                         /* vps_max_sub_layers_minus1 */
    bw_u(&w, 1, 1);                         /* vps_temporal_id_nesting_flag */
    bw_u(&w, 0xffff, 16);
    profile_tier_level(&w, profile, level);
    bw_u(&w, 1, 1);                         /* vps_sub_layer_ordering_info_present_flag */
    bw_ue(&w, dpb);
    bw_ue(&w, dpb);
    bw_ue(&w, 0);
    bw_u(&w, 0, 6);                         /* vps_max_layer_id */
    bw_ue(&w, 0);                           /* vps_num_layer_sets_minus1 */
    bw_u(&w, 0, 1);                         /* vps_timing_info_present_flag */
    bw_u(&w, 0, 1);                         /* vps_extension_flag */
    bb_entry(params, out, finish_nal(&w, out));

    /* seq_parameter_set_rbsp() */
    bw_init(&w, raw, sizeof(raw));
    bw_u(&w, 33 << 1, 8);
    bw_u(&w, 1, 8);
    bw_u(&w, 0, 4);
    bw_u(&w, 0, 3);
    bw_u(&w, 1, 1);
    profile_tier_level(&w, profile, level);
    bw_ue(&w, 0);                           /* sps_seq_parameter_set_id */
    bw_ue(&w, pf->chroma_format_idc);
    if (pf->chroma_format_idc == 3)
        bw_u(&w, pf->separate_colour_plane_flag, 1);
    bw_ue(&w, pic->pic_width_in_luma_samples);
    bw_ue(&w, pic->pic_height_in_luma_samples);
    bw_u(&w, 0, 1);                         /* conformance_window_flag */
    bw_ue(&w, pic->bit_depth_luma_minus8);
    bw_ue(&w, pic->bit_depth_chroma_minus8);
    bw_ue(&w, pic->log2_max_pic_order_cnt_lsb_minus4);
    bw_u(&w, 1, 1);                         /* sps_sub_layer_ordering_info_present_flag */
    bw_ue(&w, dpb);
    bw_ue(&w, dpb);
    bw_ue(&w, 0);
    bw_ue(&w, pic->log2_min_luma_coding_block_size_minus3);
    bw_ue(&w, pic->log2_diff_max_min_luma_coding_block_size);
    bw_ue(&w, pic->log2_min_transform_block_size_minus2);
    bw_ue(&w, pic->log2_diff_max_min_transform_block_size);
    bw_ue(&w, pic->max_transform_hierarchy_depth_inter);
    bw_ue(&w, pic->max_transform_hierarchy_depth_intra);
    bw_u(&w, pf->scaling_list_enabled_flag, 1);
    if (pf->scaling_list_enabled_flag) {
        bw_u(&w, iq != NULL, 1);            /* sps_scaling_list_data_present_flag */
        if (iq)
            scaling_list_data(&w, iq);
    }
    bw_u(&w, pf->amp_enabled_flag, 1);
    bw_u(&w, sf->sample_adaptive_offset_enabled_flag, 1);
    bw_u(&w, pf->pcm_enabled_flag, 1);
    if (pf->pcm_enabled_flag) {
        bw_u(&w, pic->pcm_sample_bit_depth_luma_minus1, 4);
        bw_u(&w, pic->pcm_sample_bit_depth_chroma_minus1, 4);
        bw_ue(&w, pic->log2_min_pcm_luma_coding_block_size_minus3);
        bw_ue(&w, pic->log2_diff_max_min_pcm_luma_coding_block_size);
        bw_u(&w, pf->pcm_loop_filter_disabled_flag, 1);
    }
    bw_ue(&w, 0);                           /* num_short_term_ref_pic_sets: slices carry them */
    bw_u(&w, sf->long_term_ref_pics_present_flag, 1);
    if (sf->long_term_ref_pics_present_flag)
        bw_ue(&w, 0);                       /* num_long_term_ref_pics_sps */
    bw_u(&w, sf->sps_temporal_mvp_enabled_flag, 1);
    bw_u(&w, pf->strong_intra_smoothing_enabled_flag, 1);
    bw_u(&w, 0, 1);                         /* vui_parameters_present_flag */
    bw_u(&w, 0, 1);                         /* sps_extension_present_flag */
    if (w.overflow)
        return -1;
    bb_entry(params, out, finish_nal(&w, out));

    /* pic_parameter_set_rbsp() for the ids this picture uses */
    for (int id = 0; id < 64; id++) {
        if (!s->used[id])
            continue;
        bw_init(&w, raw, sizeof(raw));
        bw_u(&w, 34 << 1, 8);
        bw_u(&w, 1, 8);
        bw_ue(&w, id);
        bw_ue(&w, 0);
        bw_u(&w, sf->dependent_slice_segments_enabled_flag, 1);
        bw_u(&w, sf->output_flag_present_flag, 1);
        bw_u(&w, pic->num_extra_slice_header_bits, 3);
        bw_u(&w, pf->sign_data_hiding_enabled_flag, 1);
        bw_u(&w, sf->cabac_init_present_flag, 1);
        bw_ue(&w, pic->num_ref_idx_l0_default_active_minus1);
        bw_ue(&w, pic->num_ref_idx_l1_default_active_minus1);
        bw_se(&w, pic->init_qp_minus26);
        bw_u(&w, pf->constrained_intra_pred_flag, 1);
        bw_u(&w, pf->transform_skip_enabled_flag, 1);
        bw_u(&w, pf->cu_qp_delta_enabled_flag, 1);
        if (pf->cu_qp_delta_enabled_flag)
            bw_ue(&w, pic->diff_cu_qp_delta_depth);
        bw_se(&w, pic->pps_cb_qp_offset);
        bw_se(&w, pic->pps_cr_qp_offset);
        bw_u(&w, sf->pps_slice_chroma_qp_offsets_present_flag, 1);
        bw_u(&w, pf->weighted_pred_flag, 1);
        bw_u(&w, pf->weighted_bipred_flag, 1);
        bw_u(&w, pf->transquant_bypass_enabled_flag, 1);
        bw_u(&w, pf->tiles_enabled_flag, 1);
        bw_u(&w, pf->entropy_coding_sync_enabled_flag, 1);
        if (pf->tiles_enabled_flag) {
            bw_ue(&w, pic->num_tile_columns_minus1);
            bw_ue(&w, pic->num_tile_rows_minus1);
            bw_u(&w, 0, 1);                 /* uniform_spacing_flag: VA gives explicit sizes */
            for (int i = 0; i < pic->num_tile_columns_minus1; i++)
                bw_ue(&w, pic->column_width_minus1[i]);
            for (int i = 0; i < pic->num_tile_rows_minus1; i++)
                bw_ue(&w, pic->row_height_minus1[i]);
            bw_u(&w, pf->loop_filter_across_tiles_enabled_flag, 1);
        }
        bw_u(&w, pf->pps_loop_filter_across_slices_enabled_flag, 1);
        bw_u(&w, 1, 1);                     /* deblocking_filter_control_present_flag */
        bw_u(&w, sf->deblocking_filter_override_enabled_flag, 1);
        bw_u(&w, sf->pps_disable_deblocking_filter_flag, 1);
        if (!sf->pps_disable_deblocking_filter_flag) {
            bw_se(&w, pic->pps_beta_offset_div2);
            bw_se(&w, pic->pps_tc_offset_div2);
        }
        bw_u(&w, 0, 1);                     /* pps_scaling_list_data_present_flag */
        bw_u(&w, sf->lists_modification_present_flag, 1);
        bw_ue(&w, pic->log2_parallel_merge_level_minus2);
        bw_u(&w, sf->slice_segment_header_extension_present_flag, 1);
        bw_u(&w, 0, 1);                     /* pps_extension_present_flag */
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
    for (int id = 0; id < 64; id++)
        if (s->pps[id])
            bb_entry(params, s->pps[id], s->pps_len[id]);
    return 0;
}
