# Media engine bridge

Lets containers transcode on the Mac's media engine (VideoToolbox).

## How it works

`--device mdock.dev/media=ffmpeg` (CDI) mounts a static shim over `ffmpeg`/`ffprobe`
(`/usr/lib/mdock/bin/` and `/usr/lib/jellyfin-ffmpeg/`). Each call runs on the Mac through the mdock
bridge (vsock port 1026, served by the mdock daemon), with stdin, stdout, stderr, signals and exit
codes relayed. Container paths on bind mounts from macOS are rewritten to Mac paths, and ffprobe's
output is rewritten back. The Mac-side ffmpeg is jellyfin-ffmpeg 8.1.3 built from source
(`build-ffmpeg.sh`): VideoToolbox decode and encode (`h264/hevc/prores_videotoolbox`), `scale_vt`,
and SIMD CPU tone mapping (`tonemapx`). The Metal filters need full Xcode and are not built.

Any image that runs ffmpeg from those paths, or has `/usr/lib/mdock/bin` on its PATH, can use it.
Arguments must ask for VideoToolbox (`-hwaccel videotoolbox`, `-c:v hevc_videotoolbox`). Software
codecs also work; they then run on the Mac's CPU rather than the VM's.

## Jellyfin

Jellyfin only builds VideoToolbox pipelines on macOS. `jellyfin/Dockerfile` rebuilds the two
encoding assemblies of the matching release so that `JELLYFIN_REMOTE_VIDEOTOOLBOX=1` (set by the CDI
device) also counts. See `jellyfin/compose.yaml`. Measured on an M1, 4K HDR10 HEVC → 1080p SDR H.264
at 8 Mb/s:

| | fps | real-time |
|---|---:|---:|
| Stock Jellyfin in a container (software, 8 vCPUs) | 31 | 1.3× |
| mdock bridge (media engine + CPU tone mapping) | 59–70 | 2.4–2.9× |
| SDR 1080p H.264 → HEVC, media engine only | 154 | 5.1× |

## Limits

- Files must live on bind mounts from macOS (`/Users`, `/Volumes`, `/private`). Container-internal
  paths and named volumes aren't visible to the Mac.
- Any container given this device can run ffmpeg as your macOS user, with access to whatever your
  account can read and write. Only give it to containers you trust.
- No AV1 decode on M1 (the M3 and later have it).

## Rebuild

    ./build-ffmpeg.sh       # jellyfin-ffmpeg for macOS → prefix/
    ./build-shim.sh         # static linux/arm64 shim → ~/.mdock/accel/guest/
