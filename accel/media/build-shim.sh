#!/bin/sh
# Builds the static linux/arm64 ffmpeg/ffprobe shim into ~/.mdock/accel/guest (needs mdock running).
set -eu
cd "$(dirname "$0")"
mkdir -p "$HOME/.mdock/accel/guest"
DOCKER_CONTEXT=${DOCKER_CONTEXT:-mdock} docker run --rm -v "$(pwd):/src" -v "$HOME/.mdock/accel/guest:/out" alpine:3.22 \
  sh -c 'apk add -q --no-cache build-base && gcc -O2 -Wall -static -o /out/mdock-media-shim /src/shim.c && strip /out/mdock-media-shim'
ls -la "$HOME/.mdock/accel/guest/mdock-media-shim"
