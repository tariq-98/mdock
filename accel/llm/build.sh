#!/bin/bash
# Builds llama.cpp from source with the Metal backend, tuned for this Mac, into accel/llm/prefix.
#
#   accel/llm/build.sh            # default build (see LTO below)
#   LTO=ON accel/llm/build.sh     # with link-time optimisation
#
# Produces prefix/bin/{llama-server,ggml-rpc-server,llama-bench,llama-cli,...}: static binaries with the
# Metal shader library embedded, so they need nothing but macOS at run time.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src/llama.cpp"
PREFIX="${PREFIX:-$HERE/prefix}"

# Pinned release (same tag as homebrew-core's llama.cpp, so benchmarks compare build flags only).
TAG="v0.6.0"
COMMIT="d81235049384534c167caea52b85a694f6103d14"
# Measured on M1 (README.md): LTO made no measurable difference (decode is GPU-bound), so it is off
# by default to keep the build at ~2.5 min instead of ~8.
LTO="${LTO:-OFF}"
BUILD="$HERE/src/build-lto-$LTO"

if [ ! -d "$SRC/.git" ]; then
    mkdir -p "$HERE/src"
    git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi
actual="$(git -C "$SRC" rev-parse HEAD)"
if [ "$actual" != "$COMMIT" ]; then
    echo "llama.cpp checkout is $actual, expected $COMMIT ($TAG)" >&2
    exit 1
fi

# mdock patches (see patches/): applied once; a checkout that already has them is left alone.
for patch in "$HERE"/patches/*.patch; do
    if git -C "$SRC" apply --check "$patch" 2>/dev/null; then
        git -C "$SRC" apply "$patch"
    elif ! git -C "$SRC" apply --check --reverse "$patch" 2>/dev/null; then
        echo "patch $(basename "$patch") does not apply" >&2
        exit 1
    fi
done

# GGML_NATIVE compiles ggml-cpu with -mcpu=native (apple-m1 here). The rest of llama.cpp gets the
# same target so host-side code (sampling, tokenizer, server) is tuned too.
cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_C_FLAGS="-mcpu=native" \
    -DCMAKE_CXX_FLAGS="-mcpu=native" \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_METAL_NDEBUG=ON \
    -DGGML_NATIVE=ON \
    -DGGML_RPC=ON \
    -DGGML_LTO="$LTO" \
    -DGGML_BLAS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_USE_PREBUILT_UI=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_ALL_WARNINGS=OFF \
    -DLLAMA_BUILD_IS_DEV=OFF

cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.ncpu)" \
    --target llama-server ggml-rpc-server llama-bench llama-cli llama-completion
mkdir -p "$PREFIX/bin"
for tool in llama-server ggml-rpc-server llama-bench llama-cli llama-completion; do
    install -m 0755 "$BUILD/bin/$tool" "$PREFIX/bin/$tool"
done
echo "$TAG $COMMIT LTO=$LTO" > "$PREFIX/VERSION"
"$PREFIX/bin/llama-server" --version 2>&1 | head -2
