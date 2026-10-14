# mdock-llm: native Metal LLM inference for containers

Containers can already reach the GPU through Vulkan/Venus, but llama.cpp's Vulkan backend on
MoltenVK decodes at about a third of the speed of its Metal backend. `mdock-llm` runs llama.cpp
natively on the Mac and offers it to containers two ways:

| | In-container endpoint | What runs where |
|---|---|---|
| **HTTP API** (OpenAI + Ollama) | `http://llm.mdock.internal:8200` | everything on the Mac; the container sends JSON |
| **ggml RPC** (Metal) | `llm.mdock.internal:50052` | llama.cpp in the container, its layers computed on the Mac GPU |

```
container ─tcp─▶ guest relay ─vsock 1029─▶ mdock daemon ─▶ ~/.mdock/accel/llm.sock ─▶ mdock-llm ─▶ llama-server (127.0.0.1:random, per model)
container ─tcp─▶ guest relay ─vsock 1030─▶ mdock daemon ─▶ ~/.mdock/accel/llm-rpc.sock ─▶ mdock-llm ─▶ ggml-rpc-server (127.0.0.1:random, per connection)
```

## Build

```sh
accel/llm/build.sh      # llama.cpp v0.6.0 from source → accel/llm/prefix/bin (~2.5 min on M1)
swift build -c release --product mdock-llm --build-path .build-mdock-llm
```

`build.sh` pins llama.cpp `v0.6.0` (commit `d812350`, the same release homebrew-core ships), applies
`patches/`, and builds static binaries (`llama-server`, `ggml-rpc-server`, `llama-bench`, `llama-cli`,
`llama-completion`) with CMake Release, `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON`,
`GGML_NATIVE=ON` (`-mcpu=native`, i.e. apple-m1, for all C/C++), `GGML_RPC=ON` and Accelerate BLAS.
No web UI, no OpenSSL, no runtime dependencies besides macOS. `LTO=ON accel/llm/build.sh` turns on LTO.

`mdock-llm` finds the binaries in `$MDOCK_LLM_PREFIX/bin`, next to itself (app bundle), in
`accel/llm/prefix/bin` above its build directory, or in `/opt/homebrew/bin` (Homebrew has no RPC
server, so RPC needs this build).

### Build flags, measured

M1 MacBook Air (fanless, so runs alternate in rotated order with 15 s cool-downs), Qwen2.5-0.5B
Q4_K_M, `llama-bench -p 512 -n 128 -r 5` per run, medians over 10 runs (6 for LTO):

| build | pp512 tok/s | tg128 tok/s | tg128 range |
|---|---:|---:|---:|
| Homebrew 0.6.0 (`/opt/homebrew/bin/llama-bench`) | 1,791 | 84.9 | 82.5–97.3 |
| this build, LTO | 1,778 | 86.8 | 79.1–92.8 |
| **this build, no LTO (default)** | 1,784 | **93.4** | 83.8–103.0 |

Prompt processing is identical (GPU-bound; the Metal kernels are compiled by macOS at run time
whatever the host flags). Generation of this small model also pays per-token CPU work (graph
build, sampling), where the static `-mcpu=native` build is about 10% faster than Homebrew's
dynamically loaded backends; the ranges overlap, so treat it as a modest gain. LTO showed no gain and
triples the build time (~8 min vs ~2.5), so it is off. Besides speed, this build is the only one with
`ggml-rpc-server`, carries the RPC memory-cap patch, and has no runtime dependencies.

The first start after a (re)build takes ~10 s while macOS compiles the embedded Metal library;
later starts hit the system shader cache (a model loads in ~0.5–1 s).

## Run

The mdock daemon starts it on the first connection from the guest:

```sh
mdock-llm serve --socket ~/.mdock/accel/llm.sock --rpc-socket ~/.mdock/accel/llm-rpc.sock
```

| option | default | |
|---|---|---|
| `--models <dir>` | `~/.mdock/models` | GGUF files; the model id is the file name without `.gguf` |
| `--ctx-size <n>` | 8192 | context per model (one KV pool shared by its parallel slots), capped at the model's own |
| `--parallel <n>` | 4 | concurrent requests per model |
| `--idle <s>` | 300 | unload a model after this long without requests |
| `--max-memory <GiB>` | 40% of RAM (6.4 on 16 GB) | budget for all loaded models (weights + KV + compute estimate) |
| `--max-models <n>` | 3 | loaded models at once (a model and its embedding instance count separately) |
| `--rpc-sessions <n>` | 2 | concurrent RPC clients; further connections are closed |
| `--rpc-max-memory <GiB>` | = `--max-memory` | GPU memory one RPC client may allocate |
| `--rpc-cache` | off | cache uploaded weights in `~/.mdock/cache/llm-rpc` (16 GiB LRU) |
| `--server-arg <arg>` | | extra `llama-server` flag, repeatable (e.g. `--server-arg --flash-attn --server-arg on`) |
| `--tcp ip:port`, `--rpc-tcp ip:port` | | test listeners; `0.0.0.0` is refused |

Logs (including every llama-server's output, prefixed) go to stderr, i.e. `~/.mdock/accel/mdock-llm.log`.

## HTTP API

Plain HTTP/1.1; every response closes the connection. No API key is checked (SDKs that insist on one
accept any string).

- OpenAI: `GET /v1/models`, `POST /v1/chat/completions`, `/v1/completions`, `/v1/embeddings`
  (streaming SSE included). Any other `POST /v1/*` that llama-server implements (e.g. `/v1/messages`
  for Anthropic clients, `/v1/responses`) and its native `/completion`, `/tokenize`, `/detokenize`,
  `/apply-template`, `/infill` are passed through too. Requests and responses are relayed byte for
  byte as they arrive, with no buffering; a client that disconnects cancels its generation.
- Ollama: `GET /api/tags`, `/api/ps`, `/api/version`, `POST /api/chat`, `/api/generate`, `/api/embed`,
  `/api/embeddings`, `/api/show`, `/api/pull` (translated to the OpenAI routes: streaming NDJSON,
  `options`, `format` json/schema, tools, `think`; an empty `/api/generate` preloads the model).
  Ollama-style tags such as `llama3.2:3b` are not resolved; use file names or Hugging Face ids.

Models: the first request for a model starts `llama-server -m <file> -ngl 999 --jinja --kv-unified`
for it on a random 127.0.0.1 port; `/v1/embeddings` uses a second instance with `--embeddings`
(mean pooling unless the GGUF declares its own). A model id may also be a Hugging Face reference,
downloaded once into the models directory (`HF_TOKEN` is used for gated repos):

```sh
curl http://llm.mdock.internal:8200/v1/chat/completions -d '{
  "model": "bartowski/SmolLM2-135M-Instruct-GGUF:Q4_K_M",
  "messages": [{"role": "user", "content": "Hello"}]}'
# owner/repo:file.gguf picks an exact file; owner/repo[:QUANT] picks the first matching GGUF (default Q4_K_M)
```

Memory: before loading, mdock-llm estimates weights + KV cache (f16, `--ctx-size` tokens) + compute
buffers. If the model doesn't fit next to the loaded ones, idle models are unloaded (least recently
used first); if the others are busy the request waits for them (up to 10 min), and a model larger
than the whole budget is refused with HTTP 507.

## ggml RPC: llama.cpp in the container, layers on the Mac GPU

```sh
docker build -t llm-rpc-client accel/llm/rpc-client     # llama.cpp v0.6.0, CPU + RPC, linux/arm64
docker run --rm -v ~/mdock/models:/models llm-rpc-client \
  llama-bench -m /models/qwen2.5-0.5b-q4_k_m.gguf --rpc llm.mdock.internal:50052 -dev RPC0
```

- The client must be built from the **same llama.cpp release** (RPC protocol 7.0.0 in v0.6.0);
  mismatched versions fail at the handshake.
- The GGUF is read in the container and its weights are uploaded over the connection on every load
  (~0.5 GB for the example model). `--rpc-cache` makes repeat loads skip the upload.
- Mount real files: symlinks under `~/.mdock/models` that point outside the mounted directory don't
  resolve inside a container.
- `-dev RPC0` keeps everything on the Mac GPU; without it llama.cpp splits layers between the
  container's CPU and the RPC device.

## Performance

Qwen2.5-0.5B Q4_K_M, M1 MacBook Air 16 GB, macOS 26.6, tok/s. Measured in rotated order with
cool-downs at load average 3–6 (other work was running on the machine; the fanless Air throttles, so
single runs vary by ±10%).

| path | prompt (pp512) | generation (tg128) |
|---|---:|---:|
| Native llama-bench, this build | 1,784 | 93.4 |
| **HTTP API from the Mac** (`bench-api.py`, unix socket) | 1,694–1,734 | **96–98** |
| **HTTP API from a container** (`llm.mdock.internal:8200`) | 1,729 | **96.4** |
| RPC from the Mac (`--rpc 127.0.0.1`, llama.cpp on the host) | 1,745–1,754 | 92.0–92.4 |
| **RPC from a container** (`--rpc llm.mdock.internal:50052 -dev RPC0`) | 1,636 | **67.0** |
| Container, Vulkan/Venus (GPU engine; from the top-level README) | 970 | 32.6 |
| Container, CPU only, 8 vCPUs (from the top-level README) | 148 | 10.8 |

- The HTTP API costs nothing measurable: client-side decode rate equals llama-server's own timing,
  and from a container it is ~3× the Vulkan/Venus path. (API prompt numbers are llama-server's
  timings for a ~530-token prompt, not llama-bench's synthetic batch.)
- RPC from a container decodes at ~2× Vulkan/Venus but ~30% below native: every token needs several
  request/response round trips (inputs, graph compute, logits), and each crosses the guest relay,
  vsock, the daemon and mdock-llm. On the Mac itself (loopback TCP only) RPC is within 2% of native.
  Prompt processing is barely affected (few large messages).
- RPC uploads the weights at every model load. On the Mac the 0.5B model loads in 1.5 s, 0.85 s with
  `--rpc-cache` (only tensors over 10 MB are cached); load time through vsock was not measured.
- The container rows were measured once each at low load; under heavy load (load average 20–90)
  RPC-from-container measured 43–60 tok/s and the API 50–65.


## Security model

**Who can connect.** The sockets are mode 0600 in `~/.mdock/accel` (the user only). Every helper
process (llama-server, ggml-rpc-server) listens on 127.0.0.1 only, on a random port. Inside the VM,
**any container** can reach `llm.mdock.internal`; there is no authentication on either service. Treat
both as available to all code running in mdock containers, and to any local process of any user that
can connect to 127.0.0.1 ports (the helper ports are not secret).

**HTTP API.** Containers can run any local model, download GGUFs from Hugging Face into
`~/.mdock/models` (by naming them), and use GPU time and up to `--max-memory` of RAM. Requests go to
llama-server, a large C++ parser; a bug there would run code as the user on the Mac, outside the VM.

**RPC.** ggml RPC is unauthenticated and was designed for trusted networks; llama.cpp warns never to
expose it. A client can allocate buffers, write and read arbitrary tensor data in its own buffers,
and run compute graphs on the GPU. mdock-llm limits the damage:

- one ggml-rpc-server process per connection, so clients cannot see or reuse each other's buffers,
  and everything a client allocated is freed when it disconnects;
- `patches/rpc-server-alloc-limit.patch` caps what one client may allocate (`--rpc-max-memory`;
  allocations beyond it fail and the device reports that size), and `--rpc-sessions` caps concurrent
  clients, so the worst case is `--rpc-sessions × --rpc-max-memory` (12.8 GiB with defaults on a
  16 GB Mac; lower them on shared machines). This memory is not part of the `--max-memory` budget of
  the HTTP API;
- the tensor cache is off by default: it is shared by all clients and keyed by a 64-bit FNV hash,
  which is not collision resistant, so a malicious client could plant data that another client's
  model load then uses.

The RPC server still parses untrusted input in C++ (upstream bounds-checks tensor and graph
messages, but it has had memory-safety bugs before). The boundary that matters is: **anything that
can run in an mdock container can use the Mac GPU and memory through these services**, and the
RPC/llama-server parsers are attack surface that runs outside the VM.
