# llama.cpp with the Vulkan backend, for the mdock GPU engine:
#   docker build -t llama-vulkan examples/llama-vulkan
#   docker run --rm --device mdock.dev/gpu=all -v $PWD/models:/models llama-vulkan \
#     llama-bench -m /models/model.gguf
FROM fedora:42 AS build
RUN dnf install -y -q gcc-c++ cmake git vulkan-loader-devel vulkan-headers glslc libcurl-devel && dnf clean all
ARG LLAMA_REF=b6700
RUN git clone --depth 1 --branch ${LLAMA_REF} https://github.com/ggml-org/llama.cpp /src
RUN cmake -S /src -B /build -DGGML_VULKAN=ON -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod \
      -DLLAMA_CURL=OFF -DCMAKE_BUILD_TYPE=Release \
 && cmake --build /build -j"$(nproc)" --target llama-bench llama-cli llama-server

FROM fedora:42
RUN dnf install -y -q mesa-vulkan-drivers vulkan-loader libgomp && dnf clean all
COPY --from=build /build/bin/ /usr/local/bin/
COPY --from=build /build/bin/*.so* /usr/local/lib/
ENV LD_LIBRARY_PATH=/usr/local/lib
