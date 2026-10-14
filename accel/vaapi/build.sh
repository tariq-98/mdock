#!/bin/sh
# Builds mdock_drv_video.so (+ the DRM stand-in shim and vtbench) in a container on the mdock VM
# and installs the guest artifacts into ~/.mdock/accel/guest/.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dest=${MDOCK_ACCEL_GUEST:-$HOME/.mdock/accel/guest}
export DOCKER_CONTEXT=${DOCKER_CONTEXT:-mdock}

docker build --platform linux/arm64 -t vt-vaapi-build "$here"
id=$(docker create vt-vaapi-build /none)
trap 'docker rm -f "$id" >/dev/null' EXIT
mkdir -p "$dest" "$here/out"
docker cp "$id:/mdock_drv_video.so" "$here/out/"
docker cp "$id:/libmdock_drm_shim.so" "$here/out/"
docker cp "$id:/vtbench" "$here/out/"
# Replace via rename so running containers keep the inode they mapped.
for f in mdock_drv_video.so libmdock_drm_shim.so; do
  cp "$here/out/$f" "$dest/.$f.new" && mv -f "$dest/.$f.new" "$dest/$f"
done
# For CDI to bind-mount over /etc/ld.so.preload (glibc only; musl ignores the file).
printf '/usr/lib/mdock/libmdock_drm_shim.so\n' > "$dest/.ld.so.preload.new" && mv -f "$dest/.ld.so.preload.new" "$dest/ld.so.preload"
echo "installed mdock_drv_video.so, libmdock_drm_shim.so and ld.so.preload in $dest"
