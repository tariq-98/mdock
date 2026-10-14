#!/bin/sh
# Builds the mdock/gpu image (Mesa from source, see Dockerfile) on mdock itself.
set -eu
cd "$(dirname "$0")"
[ -f mesa-25.1.9.tar.xz ] || curl -fsSL -o mesa-25.1.9.tar.xz https://archive.mesa3d.org/mesa-25.1.9.tar.xz
docker build --platform linux/arm64 -t mdock/gpu:25.1.9 -t mdock/gpu:latest .
