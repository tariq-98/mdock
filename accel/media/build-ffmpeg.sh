#!/bin/sh
# Builds jellyfin-ffmpeg for macOS from source into accel/media/prefix, for the media-exec bridge.
# Hardware decode/encode via VideoToolbox; no Metal filters (they need full Xcode), so tone mapping
# and deinterlacing use jellyfin-ffmpeg's SIMD CPU filters. Libraries come from homebrew-core:
#   brew install nasm pkg-config x264 x265 dav1d libass fribidi harfbuzz freetype fontconfig zimg \
#     webp opus lame libvorbis libvpx srt libbluray libxml2 xz
set -eu
cd "$(dirname "$0")"
HERE=$(pwd)
TAG=v8.1.3-1
SRC=$HERE/src/jellyfin-ffmpeg
PREFIX=$HERE/prefix

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/jellyfin/jellyfin-ffmpeg "$SRC"
fi
cd "$SRC"
# Apply jellyfin's patch series once (recorded in .mdock-patched).
if [ ! -f .mdock-patched ]; then
  while read -r p; do
    case "$p" in ''|'#'*) continue ;; esac
    patch -p1 -s -N < "debian/patches/$p"
  done < debian/patches/series
  touch .mdock-patched
fi

export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig:/opt/homebrew/opt/libxml2/lib/pkgconfig"
./configure --prefix="$PREFIX" \
  --cc=clang --extra-cflags="-mcpu=apple-m1 -O3 -I/opt/homebrew/include" \
  --extra-ldflags="-L/opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib" \
  --extra-version=mdock --enable-gpl --enable-version3 --disable-doc --disable-ffplay --disable-debug \
  --enable-shared --disable-static --enable-pthreads --enable-neon \
  --enable-videotoolbox --enable-audiotoolbox --disable-filter=transpose_vt \
  --enable-libx264 --enable-libx265 --enable-libdav1d --enable-libass --enable-libfreetype \
  --enable-libfribidi --enable-libharfbuzz --enable-fontconfig --enable-libzimg --enable-libwebp \
  --enable-libopus --enable-libmp3lame --enable-libvorbis --enable-libvpx --enable-libsrt \
  --enable-libbluray --enable-libxml2 --enable-lzma --enable-zlib --enable-iconv
make -j"$(sysctl -n hw.ncpu)"
make install
"$PREFIX/bin/ffmpeg" -hide_banner -version | head -1
