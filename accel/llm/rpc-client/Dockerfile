# llama.cpp CPU build with the ggml RPC backend, for offloading to the Mac GPU through mdock-llm:
#   docker build -t llm-rpc-client accel/llm/rpc-client
#   docker run --rm -v ~/.mdock/models:/models llm-rpc-client \
#     llama-bench -m /models/model.gguf --rpc llm.mdock.internal:50052 -dev RPC0
#
# The ggml RPC protocol is versioned: build the same llama.cpp tag as accel/llm/build.sh (LLAMA_REF).
FROM debian:bookworm AS build
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends g++ cmake git ca-certificates make \
 && rm -rf /var/lib/apt/lists/*
ARG LLAMA_REF=v0.6.0
RUN git clone -q --depth 1 --branch ${LLAMA_REF} https://github.com/ggml-org/llama.cpp /src
# armv8.4-a+dotprod runs on the M1 guest; GGML_NATIVE stays off so the image is portable.
RUN cmake -S /src -B /build -DCMAKE_BUILD_TYPE=Release -DGGML_RPC=ON -DGGML_NATIVE=OFF \
      -DGGML_CPU_ARM_ARCH=armv8.4-a+dotprod -DBUILD_SHARED_LIBS=OFF -DLLAMA_OPENSSL=OFF \
      -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF \
 && cmake --build /build -j"$(nproc)" --target llama-bench llama-cli llama-completion llama-server

FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends libgomp1 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY --from=build /build/bin/llama-bench /build/bin/llama-cli /build/bin/llama-completion /build/bin/llama-server /usr/local/bin/
