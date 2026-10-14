# mdock-ml: Apple on-device ML for containers

`mdock-ml` is the host service behind `http://ml.mdock.internal:8100`. It exposes Apple's on-device
language model, Core ML (Neural Engine, GPU, CPU) and speech recognition over plain HTTP/1.1, so any
Linux container can use them without drivers or devices (see [CONTRACT.md](../CONTRACT.md)).

```sh
swift build -c release --product mdock-ml --build-path .build-mdock-ml
.build-mdock-ml/release/mdock-ml serve --socket ~/.mdock/accel/ml.sock   # the daemon does this lazily
.build-mdock-ml/release/mdock-ml serve --tcp 127.0.0.1:18100              # test only, loopback/explicit IPv4
```

## Endpoints

| | |
|---|---|
| `GET /health` | liveness |
| `GET /v1/capabilities` | Foundation Models availability (with reason), Core ML devices (ANE cores, GPU), speech locales |
| `GET /v1/models` | `apple-foundation-model`, `apple-foundation-model-content-tagging` |
| `POST /v1/chat/completions` | OpenAI chat: system/user/assistant/tool messages, `temperature` (0 → greedy), `top_p`, `seed`, `max_tokens`, `stream` (SSE, `stream_options.include_usage`), `response_format` `json_schema` (guided generation) / `json_object`, `tools` (OpenAI function calling) |
| `POST /v1/audio/transcriptions` | OpenAI Whisper API: multipart `file`, `language`, `prompt`, `response_format` json/text/verbose_json/srt/vtt, `timestamp_granularities[]=word` |
| `GET /v1/coreml/models` | list stored models |
| `POST /v1/coreml/models?name=<id>` | upload a zipped `.mlpackage`/`.mlmodelc`/`.mlmodel`, a bare `.mlmodel`, or multipart `file`; compiles, stores under `~/.mdock/accel/ml/models/<id>`, then pre-compiles for the ANE in the background (`&warm=none` to skip, `&warm=cpuAndNeuralEngine` etc.) |
| `GET /v1/coreml/models/{id}` | input/output feature descriptions, metadata, class labels |
| `DELETE /v1/coreml/models/{id}` | remove |
| `POST /v1/coreml/models/{id}/load` | `{"compute_units": …}`: load into the LRU now and report `load_ms` |
| `POST /v1/coreml/models/{id}/predict` | see below |
| `GET /v1/coreml/models/{id}/plan?compute_units=all[&detail=1]` | `MLComputePlan`: which device Core ML picks for each op |

Errors use the OpenAI shape `{"error": {"message", "type", "code"}}`. If Apple Intelligence is off or the
model is still downloading, chat returns **503** `model_unavailable` with the reason.

### Predict

```json
{"inputs": {"image": "<base64 PNG/JPEG>", "input": [[...nested...]]},
 "compute_units": "cpuAndNeuralEngine",   // all | cpuAndNeuralEngine | cpuAndGPU | cpuOnly
 "repeat": 50,                            // optional: run N times, report min/median/mean/p90
 "output_format": "nested",               // or "base64" (float32 little-endian)
 "top_k": 5,                              // dictionary outputs (classifier probabilities)
 "image_crop": "center"}                  // center | fill | fit
```

Multiarrays can be nested arrays, `{"shape": [...], "values": [flat]}`, or
`{"shape": [...], "dtype": "float32|float16|float64|int32|int64|uint8", "data": "<base64>"}`; values are
converted to the model's declared dtype. Images are scaled/converted to the model's size and pixel format.
Strings, int64, double, dictionaries and sequences map to JSON. The response holds `outputs` plus
`timing` (`load_ms` when the model was loaded for this call, `prepare_ms`, `predict_ms`, `encode_ms`).
Loaded models stay in an LRU of 6 entries keyed by model and compute units.

## Examples (run inside any container)

`examples/mdock_ml.py` is a standard-library-only client and CLI (`MDOCK_ML_URL` overrides the URL).

```sh
docker run --rm -v ~/mdock/accel/ml:/ml:ro -w /ml/examples python:3.13-alpine sh -c '
  python3 mdock_ml.py caps
  python3 mdock_ml.py upload /ml/build/resnet50.mlpackage --name ml-resnet50
  python3 mdock_ml.py classify ml-resnet50 images/zebra.jpg --units cpuAndNeuralEngine
  python3 mdock_ml.py bench ml-resnet50 images/zebra.jpg
  python3 mdock_ml.py plan ml-resnet50
  python3 mdock_ml.py transcribe audio/hello.wav --format verbose_json
  python3 mdock_ml.py chat "Name three uses of a Neural Engine" --stream'
```

`examples/demo.sh` runs that sequence. The OpenAI Python SDK should work as-is (untested here, because Foundation Models are off on this Mac):
`OpenAI(base_url="http://ml.mdock.internal:8100/v1", api_key="unused")`.

To build the demo models (ResNet-50, ImageNet), use the venv under `accel/ml/`:

```sh
python3.12 -m venv accel/ml/.venv && accel/ml/.venv/bin/pip install coremltools torch torchvision
accel/ml/.venv/bin/python accel/ml/convert_resnet50.py   # → accel/ml/build/resnet50{,_tensor}.mlpackage
```

## Measured (M1, 16 GB, macOS 26.6, shared and busy machine)

ResNet-50 fp16 ML Program, batch 1, `predict_ms` median over 100–200 runs:

| compute units | image model (224², via container) | tensor model (host) |
|---|---:|---:|
| cpuOnly | 11.6–16.7 ms | 7.1 ms |
| cpuAndGPU | 8.9–24 ms (GPU shared with llama.cpp) | 8.6 ms |
| **cpuAndNeuralEngine** | **2.5–4.1 ms** | **1.7 ms** |
| all | 2.9–3.2 ms | |

`plan` shows 123 of 127 ops (98.5 % of estimated cost) on the Neural Engine. 64 concurrent ANE
predictions finish in 0.9 s. The first ANE load of a new model compiles it (2 s to 160 s on this
machine, depending on load); the OS caches the result, and uploads start that compile in the background.

Speech: 5.2 s of audio in about 0.3 s, and 20.8 s of AAC in 1.0 s (en-US, warm).

## Permissions and limits

- **Foundation Models** need Apple Intelligence turned on (System Settings › Apple Intelligence & Siri)
  and the model downloaded. No entitlement is needed for a CLI. The context window is 4096 tokens.
  Usage counts come from `SystemLanguageModel.tokenCount` (macOS 26.4+) and are otherwise estimated
  (`usage.estimated: true`). Images in chat aren't supported. `n > 1` and logprobs are ignored.
- **Tool calls**: the model's call is captured, generation stops, and the response is
  `finish_reason: "tool_calls"`. Send `role: "tool"` results back and generation continues from the
  transcript. `tool_choice: "required"` can't be enforced.
- **json_schema** supports object/array/string/integer/number/boolean, `enum`/`const`, `anyOf`,
  `$ref`/`$defs`, `minimum`/`maximum`, `minItems`/`maxItems` and `pattern`. Properties are generated with
  required keys first, then alphabetical (JSON object order is not preserved). When streaming, a
  schema response arrives as one chunk.
- **Speech** uses `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26), which needs **no TCC prompt** from a
  CLI. Locales that aren't installed are downloaded on first use. Accepted formats are whatever
  `AVAudioFile` reads (wav, aiff, caf, mp3, m4a/aac, flac). Convert ogg/webm/opus first.
- The unix socket path must fit in `sun_path` (103 bytes).
