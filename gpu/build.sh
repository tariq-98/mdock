#!/bin/sh
# Builds mdock's GPU engine from source into gpu/prefix:
#   virglrenderer (Venus, macOS/krunkit branch, + mdock patches) -> libkrun (+ mdock patches) -> gvproxy
# Everything is compiled for Apple silicon (-mcpu=apple-m1 / target-cpu=apple-m1, -O3, LTO).
#
# Toolchain and generic libraries come from homebrew-core:
#   brew install rust lld meson ninja go pkg-config dtc libepoxy molten-vk vulkan-headers
# (MoltenVK itself needs a full Xcode to build, so the homebrew-core bottle is used.)
set -eu
cd "$(dirname "$0")"
GPU=$(pwd)
SRC=$GPU/src
PREFIX=$GPU/prefix
mkdir -p "$SRC" "$PREFIX/lib" "$PREFIX/bin" "$PREFIX/include"

fetch() { # url sha256 file
  [ -f "$SRC/$3" ] || curl -fsSL "$1" -o "$SRC/$3"
  echo "$2  $SRC/$3" | shasum -a 256 -c -
}
fetch https://gitlab.freedesktop.org/slp/virglrenderer/-/archive/0.10.4e-krunkit/virglrenderer-0.10.4e-krunkit.tar.gz \
  09d000623fbdb966cb604eb48c962a0815e8142383e6066d6494809335b76dbb virgl.tgz
fetch https://github.com/containers/libkrun/archive/refs/tags/v1.19.6.tar.gz \
  7025d72208172dc06f791ad5af7ccaafeabdac9869f74ccb45fb6d4f6e5991cd libkrun.tgz
fetch https://github.com/containers/gvisor-tap-vsock/archive/refs/tags/v0.8.9.tar.gz \
  6cbcb7959a5d90b59253ea6d8bdf0285e2cfbc3b301398704b41e3069293f4fb gvproxy.tgz

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"

echo "== virglrenderer (Venus)"
rm -rf "$SRC/virglrenderer-0.10.4e-krunkit" && tar -xzf "$SRC/virgl.tgz" -C "$SRC"
cd "$SRC/virglrenderer-0.10.4e-krunkit"
for p in "$GPU"/patches/virglrenderer-*.patch; do patch -p1 < "$p"; done
CFLAGS="-mcpu=apple-m1" CXXFLAGS="-mcpu=apple-m1" LDFLAGS="-L/opt/homebrew/lib -Wl,-rpath,/opt/homebrew/lib" \
  meson setup build --prefix="$PREFIX" --libdir=lib -Dbuildtype=release -Doptimization=3 -Db_lto=true \
  -Db_ndebug=true -Dvenus=true -Drender-server=false
meson compile -C build && meson install -C build

echo "== libkrun (block, net, gpu) + mdock patches"
rm -rf "$SRC/libkrun-1.19.6" && tar -xzf "$SRC/libkrun.tgz" -C "$SRC"
cd "$SRC/libkrun-1.19.6"
for p in "$GPU"/patches/libkrun-*.patch; do patch -p1 < "$p"; done
LIBRARY_PATH=/opt/homebrew/lib RUSTFLAGS="-C target-cpu=apple-m1" \
  CARGO_PROFILE_RELEASE_LTO=fat CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
  PATH="/opt/homebrew/opt/lld/bin:$PATH" make INIT_BLOB=0 BLK=1 NET=1 GPU=1
cp target/release/libkrun.dylib "$PREFIX/lib/libkrun.dylib"
install_name_tool -id @rpath/libkrun.dylib "$PREFIX/lib/libkrun.dylib"
cp include/libkrun.h "$PREFIX/include/"

echo "== gvproxy"
rm -rf "$SRC/gvisor-tap-vsock-0.8.9" && tar -xzf "$SRC/gvproxy.tgz" -C "$SRC"
cd "$SRC/gvisor-tap-vsock-0.8.9"
GOARM64=v8.4,lse CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$PREFIX/bin/gvproxy" ./cmd/gvproxy

echo "GPU stack ready in $PREFIX"
