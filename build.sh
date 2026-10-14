#!/bin/sh
# Builds mdock and signs it with the virtualization entitlement.
set -e
cd "$(dirname "$0")"
swift build -c release --product mdock
swift build -c release --product MdockDesktop
codesign --force --sign - --entitlements mdock.entitlements .build/release/mdock
echo "built .build/release/mdock"
# `mdock` on PATH (~/.local/bin is ahead of /usr/local/bin), and as the `docker mdock` CLI plugin;
# symlinks follow rebuilds.
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/docker/cli-plugins"
ln -sf "$PWD/.build/release/mdock" "$HOME/.local/bin/mdock"
ln -sf "$PWD/.build/release/mdock" "$HOME/.local/lib/docker/cli-plugins/docker-mdock"
