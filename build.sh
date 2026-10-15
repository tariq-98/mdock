#!/bin/sh
# Builds mdock and signs it with the virtualization entitlement.
set -e
cd "$(dirname "$0")"
swift build -c release --product mdock
swift build -c release --product MdockDesktop
# A fixed identifier and designated requirement: still an ad-hoc signature, but one macOS recognises
# as the same program after every rebuild, so permissions it grants mdock (Local Network) stick.
codesign --force --sign - --identifier dev.mdock.cli -r='designated => identifier "dev.mdock.cli"' \
  --entitlements mdock.entitlements .build/release/mdock
echo "built .build/release/mdock"
# `mdock` on PATH (~/.local/bin is ahead of /usr/local/bin), and as the `docker mdock` CLI plugin;
# symlinks follow rebuilds.
mkdir -p "$HOME/.local/bin" "$HOME/.local/lib/docker/cli-plugins"
ln -sf "$PWD/.build/release/mdock" "$HOME/.local/bin/mdock"
ln -sf "$PWD/.build/release/mdock" "$HOME/.local/lib/docker/cli-plugins/docker-mdock"
