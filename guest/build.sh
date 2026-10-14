#!/bin/sh
# Builds the guest's static linux/arm64 programs, compiled from source in Alpine containers on mdock
# itself. `mdock start` puts them on the guest's seed disk.
#   mdock-guestd              the guest side of mdock's bridges (guestd.c)
#   qemu-x86_64, qemu-i386    QEMU user-mode: linux/amd64 where Rosetta isn't available (the GPU
#                             engine) and linux/386 on both engines (Rosetta is 64-bit only)
#   FEXInterpreter            FEX-Emu (patches/fex-*.patch), static: linux/amd64 and linux/386 with
#                             the CPU's TSO mode (mdock's kernel); it handles Go and musl programs
set -eu
cd "$(dirname "$0")"
mkdir -p out src
docker run --rm --platform linux/arm64 -v "$PWD":/src -w /src alpine:3.22 sh -c '
  apk add -q --no-cache gcc musl-dev linux-headers &&
  gcc -O2 -march=armv8.4-a -static -Wall -Wextra -o out/mdock-guestd guestd.c -lpthread &&
  strip out/mdock-guestd'
chmod 755 out/mdock-guestd  # (the GPU engine's file share creates files 0600)
ls -la out/mdock-guestd

FEX=FEX-2610
FEX_COMMIT=14c92681f4d62cf84d901460e0358de09c8847a7
fex_stamp="$FEX $(cat patches/fex-*.patch | shasum -a 256 | cut -c1-16)"
if [ "$(cat out/fex.version 2>/dev/null)" = "$fex_stamp" ] && [ -x out/FEXInterpreter ]; then
  echo "FEX $FEX already built"
else
  [ -d src/FEX ] || git clone -q --depth 1 --branch $FEX --recurse-submodules --shallow-submodules \
    https://github.com/FEX-Emu/FEX.git src/FEX
  [ "$(git -C src/FEX rev-parse HEAD)" = "$FEX_COMMIT" ] || { echo "src/FEX is not $FEX ($FEX_COMMIT)" >&2; exit 1; }
  # Static (FEX has no option for it), so the pinned interpreter runs inside any x86 container. A
  # plain static binary loads at 0x400000, where non-PIE x86 programs (Go's, static glibc ones) must
  # be mapped, so it is linked up where a PIE FEX would load: above the x86 address space and the
  # region FEX's allocator reserves for itself. (Static-PIE crashes during FEX's start-up.)
  docker run --rm --platform linux/arm64 -v "$PWD":/src -w /tmp debian:trixie sh -euc '
    apt-get update -qq >/dev/null
    apt-get install -y -qq clang lld cmake ninja-build python3 python3-packaging pkgconf git >/dev/null 2>&1
    mkdir -p /tmp/FEX
    tar -C /src/src/FEX --exclude=./External/fex-gvisor-tests-bins --exclude=./External/fex-posixtest-bins \
        --exclude=./External/fex-gcc-target-tests-bins -cf - . | tar -C /tmp/FEX -xf -
    git config --global --add safe.directory "*"
    cd /tmp/FEX && for p in /src/patches/fex-*.patch; do patch -s -p1 < $p; done
    cmake -S /tmp/FEX -B /tmp/build -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DUSE_LINKER=lld \
      -DBUILD_FEXCONFIG=OFF -DBUILD_THUNKS=OFF -DBUILD_TESTING=OFF -DENABLE_LTO=OFF \
      -DENABLE_OFFLINE_TELEMETRY=OFF -DENABLE_CCACHE=OFF \
      "-DCMAKE_EXE_LINKER_FLAGS=-static -Wl,--image-base=0xb00000000000" >/dev/null
    ninja -C /tmp/build FEX 2>&1 | grep -E " error|FAILED" || true
    strip /tmp/build/Bin/FEX && cp /tmp/build/Bin/FEX /src/out/FEXInterpreter'
  chmod 755 out/FEXInterpreter
  echo "$fex_stamp" > out/fex.version
  ls -la out/FEXInterpreter
fi

QEMU=11.1.2
QEMU_SHA256=731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016
# QEMU's release signing key (Michael Roth), checked against the tarball's detached signature.
QEMU_KEY=CEACC9E15534EBABB82D3FA03353C9CEF108B584
if [ "$(cat out/qemu.version 2>/dev/null)" = "$QEMU" ] && [ -x out/qemu-x86_64 ] && [ -x out/qemu-i386 ]; then
  echo "QEMU $QEMU already built"
  exit 0
fi
[ -f src/qemu-$QEMU.tar.xz ] || curl -fsSL -o src/qemu-$QEMU.tar.xz https://download.qemu.org/qemu-$QEMU.tar.xz
[ -f src/qemu-$QEMU.tar.xz.sig ] || curl -fsSL -o src/qemu-$QEMU.tar.xz.sig https://download.qemu.org/qemu-$QEMU.tar.xz.sig
echo "$QEMU_SHA256  src/qemu-$QEMU.tar.xz" | shasum -a 256 -c -
docker run --rm --platform linux/arm64 -v "$PWD":/src -w /tmp alpine:3.22 sh -euc "
  apk add -q --no-cache gnupg build-base python3 ninja meson pkgconf glib-dev glib-static pcre2-dev pcre2-static \
    zlib-static libffi-dev linux-headers bash perl xz flex bison
  gpg -q --keyserver hkps://keys.openpgp.org --recv-keys $QEMU_KEY
  gpg -q --verify /src/src/qemu-$QEMU.tar.xz.sig /src/src/qemu-$QEMU.tar.xz
  tar -xJf /src/src/qemu-$QEMU.tar.xz
  cd qemu-$QEMU
  ./configure --static --disable-system --enable-linux-user --target-list=x86_64-linux-user,i386-linux-user \
    --without-default-features --disable-docs --disable-tools --disable-werror \
    --extra-cflags='-O2 -march=armv8.4-a -DMADV_POPULATE_READ=22 -DMADV_POPULATE_WRITE=23' >/dev/null
  make -j\$(nproc) 2>&1 | grep -E 'error|FAILED' || true
  [ -x build/qemu-x86_64 ] && [ -x build/qemu-i386 ]
  strip build/qemu-x86_64 build/qemu-i386
  cp build/qemu-x86_64 build/qemu-i386 /src/out/
  echo $QEMU > /src/out/qemu.version"
chmod 755 out/qemu-x86_64 out/qemu-i386
ls -la out/qemu-x86_64 out/qemu-i386
