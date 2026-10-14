# mdock/gpu: Fedora 42 with Mesa built from source for mdock's GPU engine. Venus (Vulkan on the Mac's
# GPU through virtio-gpu), Zink (OpenGL on Vulkan) and rusticl (OpenCL on Zink), patched for a macOS
# host: Venus can't export memory as fds there, which stock Zink treats as fatal on the DRM path.
# Build: gpu/guest/build.sh. Use: docker run --device mdock.dev/gpu=all mdock/gpu clinfo
FROM fedora:42 AS build
RUN dnf install -y -q dnf-plugins-core patch xz && dnf builddep -y -q mesa && dnf clean all
COPY mesa-25.1.9.tar.xz mesa-*.patch /src/
RUN cd /src && echo "412df33a1bb3c785ed698555a3972118a37c458e7accf6ae53f4bb87b3db454a  mesa-25.1.9.tar.xz" | sha256sum -c - \
 && tar -xJf mesa-25.1.9.tar.xz && cd mesa-25.1.9 && for p in /src/mesa-*.patch; do patch -p1 < "$p"; done \
 && meson setup build --prefix=/usr --libdir=lib64 --buildtype=release -Db_ndebug=true \
      -Dgallium-drivers=zink,llvmpipe -Dvulkan-drivers=virtio,swrast -Dgallium-rusticl=true \
      -Dllvm=enabled -Dshared-llvm=enabled -Dplatforms=x11,wayland -Dglx=dri -Degl=enabled -Dgbm=enabled \
      -Dglvnd=enabled -Dgles1=disabled -Dgles2=enabled -Dvideo-codecs= -Dgallium-va=disabled \
      -Dgallium-vdpau=disabled -Dgallium-xa=disabled -Dvulkan-layers=device-select -Dteflon=false \
      -Dc_args=-mcpu=neoverse-n1 -Dcpp_args=-mcpu=neoverse-n1 >/dev/null \
 && ninja -C build >/dev/null && DESTDIR=/out ninja -C build install >/dev/null

FROM fedora:42
# Fedora's Mesa packages bring the runtime dependencies (glvnd, LLVM, libclc, SPIR-V tools); the
# from-source build (same Mesa version) then replaces their files.
RUN dnf install -y -q mesa-libEGL mesa-libGL mesa-libgbm mesa-dri-drivers mesa-vulkan-drivers mesa-libOpenCL \
      vulkan-loader vulkan-tools ocl-icd clinfo egl-utils glx-utils && dnf clean all
COPY --from=build /out/usr/ /usr/
# OpenCL through rusticl on Zink (on the Mac's GPU).
ENV RUSTICL_ENABLE=zink
