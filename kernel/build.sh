#!/bin/sh
# Builds mdock's guest kernel from kernel.org source: Alpine's linux-virt configuration
# (config-6.18-virt, copied from the guest's /boot) plus the patches in patches/:
#   0014-0017  Asahi Linux's TSO series (PR_SET_MEM_MODEL, per-thread ACTLR_EL1, Apple TSO control),
#              as rebased onto 6.18 by smol-machines/libkrunfw. x86 translators (Rosetta, FEX) call
#              prctl(PR_SET_MEM_MODEL, PR_SET_MEM_MODEL_TSO); the CPU then runs that thread in x86's
#              memory order (TSO) instead of the translator emulating it.
#   0018       mdock: touch ACTLR_EL1 on a context switch only when the memory model changes (each
#              access traps to the hypervisor in a VM).
# The VM's own devices (virtio block, mmio, net, vsock, balloon, rng, virtiofs) and ext4 are built in, not
# modules: the kernel mounts the root disk itself and mdock boots it without an initramfs (~0.2 s).
# Compiled in an Alpine container on mdock (the guest's release). The object tree stays in the Docker
# volume mdock-kernel-build, so after a patch change only what it touches is rebuilt. Output in out/:
#   Image (raw arm64 kernel), modules.tar.gz, config, release. Install: mdock kernel install.
set -eu
cd "$(dirname "$0")"
VER=6.18.56
SHA256=4633bbda2ab95eaf2a7af4041236451d6759c72e6946265531af4b3aacefbf89
# Greg Kroah-Hartman signs the stable releases.
SIGNER=647F28654894E3BD457199BE38DBBDC86092693E
mkdir -p src out
[ -f src/linux-$VER.tar.xz ] || curl -fsSL -o src/linux-$VER.tar.xz https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.xz
[ -f src/linux-$VER.tar.sign ] || curl -fsSL -o src/linux-$VER.tar.sign https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$VER.tar.sign
echo "$SHA256  src/linux-$VER.tar.xz" | shasum -a 256 -c -
docker volume create mdock-kernel-build >/dev/null
docker run --rm --platform linux/arm64 -v "$PWD":/k -v mdock-kernel-build:/build -w /build alpine:3.24 sh -euc "
  apk add -q --no-cache build-base perl gmp-dev mpc1-dev mpfr-dev elfutils-dev bash flex bison zstd bc \
    linux-headers openssl-dev openssl mawk diffutils findutils pahole python3 xz gnupg tar gzip
  # kernel.org publishes its developers' keys over WKD; the signer's fingerprint is pinned above.
  gpg -q --auto-key-locate clear,wkd --locate-keys gregkh@kernel.org >/dev/null
  xz -dc /k/src/linux-$VER.tar.xz | gpg --status-fd 1 --verify /k/src/linux-$VER.tar.sign - 2>/dev/null \
    | grep -q 'VALIDSIG .*$SIGNER'
  # Fresh source with the release's timestamps; patched files are newer than the kept objects.
  rm -rf linux-$VER && tar -xJf /k/src/linux-$VER.tar.xz
  cd linux-$VER
  for p in /k/patches/*.patch; do patch -s -p1 < \$p; done
  mkdir -p /build/obj
  cp /k/config-6.18-virt /tmp/config
  ./scripts/config --file /tmp/config --set-str LOCALVERSION -mdock --disable LOCALVERSION_AUTO \
    --set-str MODULE_SIG_KEY certs/signing_key.pem --enable ARM64_MEMORY_MODEL_CONTROL \
    --enable VIRTIO_BLK --enable EXT4_FS --enable VIRTIO_MMIO --enable VIRTIO_NET --enable VSOCKETS \
    --enable VIRTIO_VSOCKETS --enable VIRTIO_BALLOON --enable HW_RANDOM --enable HW_RANDOM_VIRTIO --enable FUSE_FS \
    --enable VIRTIO_FS
  cmp -s /tmp/config /build/obj/.config.mdock 2>/dev/null || { cp /tmp/config /build/obj/.config; cp /tmp/config /build/obj/.config.mdock; }
  make -s O=/build/obj olddefconfig
  grep -q '^CONFIG_ARM64_MEMORY_MODEL_CONTROL=y' /build/obj/.config
  grep -q '^CONFIG_VIRTIO_BLK=y' /build/obj/.config && grep -q '^CONFIG_EXT4_FS=y' /build/obj/.config
  make -s O=/build/obj -j\$(nproc) Image modules
  rm -rf /tmp/mods && make -s O=/build/obj modules_install INSTALL_MOD_PATH=/tmp/mods INSTALL_MOD_STRIP=1
  release=\$(make -s O=/build/obj kernelrelease)
  tar -czf /k/out/modules.tar.gz -C /tmp/mods lib/modules/\$release
  cp /build/obj/arch/arm64/boot/Image /k/out/Image
  cp /build/obj/.config /k/out/config
  echo \$release > /k/out/release"
ls -la out/
