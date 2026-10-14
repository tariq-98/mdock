# mdock-vt wire protocol (version 2)

Spoken between the guest VA-API driver (`mdock_drv_video.so`) and the host service `mdock-vt`.
One stream connection per `VADisplay` (each `vaInitialize`). Everything is little-endian. Each
connection owns its surfaces, codec sessions and frame file. Closing the socket frees all of them.

## Framing

Every message starts with a 16-byte header:

| offset | size | field |
|---:|---:|---|
| 0 | 4 | magic `0x5456444D` ("MDVT") |
| 4 | 2 | op. Replies set bit 15 (`0x8000`) |
| 6 | 2 | tag, chosen by the driver and echoed in the reply |
| 8 | 4 | status: 0 in requests; a `VAStatus` value in replies |
| 12 | 4 | payload length in bytes |

The host reads requests in order and executes them in order. Most replies are sent before the next
request is read. `ENCODE` is the exception: its reply is sent when VideoToolbox finishes the frame,
which may be after replies to later requests. The driver matches replies to requests by tag.

Because execution is ordered, the driver can send a request without waiting for its reply. It does
this for `DECODE` and `ENCODE`. A later `SURFACE_GET` of a decoded surface sees the decoded picture.
The driver reads replies that have already arrived on every send, and it keeps at most 16 requests
outstanding. A reply stream left unread would back up through the vsock relay.

Timeouts: the host drops a connection that stalls for 10 s in the middle of a request, or that leaves
replies unread for 10 s (`SO_SNDTIMEO`). In both cases it shuts the socket down at once and frees
the session. The driver fails a call after 30 s without a reply, and does not hang.

## Ops

All `u32`. "→" is the request payload and "←" the reply payload.

| op | name | payload |
|---:|---|---|
| 1 | HELLO | → `version, flags` (bit 0: driver can use a frame file) ← `version, caps, max_width, max_height, name_len, name[name_len]` |
| 2 | SURFACE_CREATE | → `sid, width, height, fourcc` (`NV12` or `P010`). The driver picks `sid` |
| 3 | SURFACE_DESTROY | → `sid` |
| 4 | SURFACE_PUT | → `sid, flags`, then the packed picture unless flags bit 0 is set (picture is in the frame file) |
| 5 | SURFACE_GET | → `sid, flags` (bit 0: deliver via frame file) ← `valid, mode`, then the packed picture if `mode` = 0. If `valid` = 0 the surface has never been written |
| 6 | DECODER_CREATE | → `cid, codec (1 H.264, 2 HEVC), width, height, bit_depth` |
| 7 | DECODE | → `cid, sid, n_params, n_slices`, then `n_params` and `n_slices` entries of `u32 len, bytes[len]`. Each is one NAL unit without a start code: parameter sets (VPS/SPS/PPS), then the picture's slices |
| 8 | CONTEXT_DESTROY | → `cid` (decoder or encoder) |
| 9 | ENCODER_CREATE | → `cid, codec, width, height, bit_depth, profile (0 CB, 1 Main, 2 High), rc (1 CQP, 2 CBR, 3 VBR), bitrate, max_bitrate, fps_num, fps_den, idr_period, qp, hrd_buffer_bits` |
| 10 | ENCODE | → `cid, sid, flags` (bit 0: force IDR) ← `keyframe`, then one Annex B access unit. SPS/PPS (and VPS) precede every keyframe |
| 11 | ENCODER_CONFIGURE | Same payload as ENCODER_CREATE. Rate control changes apply in place; anything else rebuilds the session |
| 12 | BENCH | → `reply_bytes` and any filler ← `reply_bytes` zero bytes (transport measurement) |
| 13 | SURFACE_COPY | → `src_sid, dst_sid` (dst shares src's picture) |
| 14 | PROCESS | → `src_sid, dst_sid, sx, sy, sw, sh, dx, dy, dw, dh`. Crops src to the source rectangle and scales into the destination rectangle of dst, converting NV12↔P010. Outside the rectangle dst is black |
| 15 | ENCODER_FLUSH | → `cid`. Forces out every frame submitted to the encoder. The driver sends it when an ENCODE reply is overdue |

Caps bits: 0 H.264 decode, 1 HEVC decode, 2 HEVC Main10 decode, 3 H.264 encode, 4 HEVC encode,
5 HEVC Main10 encode.

## Packed picture layout

This is the layout of `SURFACE_PUT`/`SURFACE_GET` data and of the frame file. With
`bps` = 1 for NV12 and 2 for P010 (10 bits in the high bits of each 16-bit sample):

- Y: `height` rows of `width × bps` bytes
- UV (interleaved): `⌈height/2⌉` rows of `2⌈width/2⌉ × bps` bytes

Rows are tightly packed, with no padding between rows or planes.

## Frame file (pixel transport)

The vsock relay moves about 100–450 MB/s, which is too slow for 4K (12–25 MB per picture). Pixels
can instead go through a per-connection file in a host directory that the container also mounts
(virtiofs):

- The host creates `<frames dir>/vt-<pid>-<conn>-<random>.frame` (mode 0666 in a 0711 directory,
  with an unguessable name). It is sized to 8192×4352×3 bytes up front, because the guest caches
  the file size and O_DIRECT reads stop at it. The name goes back in HELLO.
- The driver opens it as `$MDOCK_VT_FRAMES/<name>` (default `/run/mdock/vt-frames`) with
  `O_RDWR | O_DIRECT`. O_DIRECT is required: under VZ virtiofs, cached reads and `mmap` are not
  coherent with writes from the host. O_DIRECT reads and writes are, at about 1.2–1.8 GB/s.
- One picture at a time: `SURFACE_GET` with flag 1 makes the host write the packed picture at
  offset 0 before replying. Both sides split frame I/O of 4 MB or more into four concurrent
  ranges, because virtiofs throughput scales with the number of requests in flight. For `SURFACE_PUT` with flag 1, the driver writes the picture before the
  request. Requests on a connection are serialized, so one slot is enough.
- Frame I/O is padded to 4 KiB, and the driver's buffers are page-aligned.

If the file cannot be created or opened, pixels go inline in the socket payload.

## Decode bitstream reconstruction (driver side)

VA-API passes parsed headers, but VideoToolbox wants parameter sets plus NAL units.

- **H.264**: the slices are complete NAL units and go to VideoToolbox unchanged. The driver writes
  an SPS from `VAPictureParameterBufferH264` and a PPS for each `pic_parameter_set_id` the slices
  use. The PPS id is parsed from the slice header, and scaling lists come from the IQ matrix.
  `num_ref_idx_lX_default_active_minus1` is not in VA. It is learned from slices that do not set
  `num_ref_idx_active_override_flag`.
- **HEVC**: the driver writes VPS/SPS/PPS from `VAPictureParameterBufferHEVC` (+ IQ matrix). VA
  omits the SPS short-term RPS list and the SPS long-term POC list. The rebuilt SPS has neither,
  and each slice header that referenced them is rewritten with an explicit `st_ref_pic_set()` and
  explicit long-term entries. These are derived from `ReferenceFrames[]`, with POCs and
  `RPS_ST_CURR_BEFORE/AFTER/LT_CURR` flags. The rest of the header is copied bit for bit, and the
  slice data bytes are not touched.
- VideoToolbox decodes in decode order, with its own DPB and no temporal reordering. Each output
  lands in the VA target surface, so VA's "decode order per surface" contract holds. Decoding is
  asynchronous on the host: several frames are in flight, and any request that touches a surface
  first waits for a pending decode into it.
- Interlaced H.264 (`frame_mbs_only_flag` = 0) is rejected with `VA_STATUS_ERROR_UNSUPPORTED_PROFILE`.
  The Apple media engine does not decode it (VideoToolbox's hwaccel in macOS ffmpeg refuses it
  too).
