#!/usr/bin/env python3
"""Client for mdock-ml, Apple on-device ML for Linux containers. Standard library only.

Inside an mdock container the service is http://ml.mdock.internal:8100 (override with MDOCK_ML_URL).

  python3 mdock_ml.py health
  python3 mdock_ml.py caps
  python3 mdock_ml.py chat "Write a haiku about containers" [--stream] [--json-schema]
  python3 mdock_ml.py upload model.mlpackage|model.zip|model.mlmodel [--name ml-foo]
  python3 mdock_ml.py models
  python3 mdock_ml.py describe <id>
  python3 mdock_ml.py classify <id> image.jpg [--units cpuAndNeuralEngine]
  python3 mdock_ml.py bench <id> image.jpg [--runs 50]     # ANE vs GPU vs CPU latency
  python3 mdock_ml.py plan <id> [--units all]              # which device Core ML picks per op
  python3 mdock_ml.py transcribe audio.wav [--format verbose_json] [--language en]
"""
import argparse
import base64
import io
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
import zipfile

BASE = os.environ.get("MDOCK_ML_URL", "http://ml.mdock.internal:8100").rstrip("/")


class MLError(Exception):
    pass


def request(method, path, body=None, headers=None, raw=False, timeout=600):
    headers = dict(headers or {})
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
        headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = resp.read()
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        try:
            detail = json.loads(detail)["error"]["message"]
        except Exception:
            pass
        raise MLError(f"HTTP {e.code}: {detail}") from None
    return data if raw else json.loads(data)


def multipart(fields, files):
    """fields: {name: str}; files: {name: (filename, bytes, content_type)}."""
    boundary = uuid.uuid4().hex
    out = io.BytesIO()
    for name, value in fields.items():
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    for name, (filename, data, ctype) in files.items():
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
                  f"Content-Type: {ctype}\r\n\r\n".encode())
        out.write(data)
        out.write(b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    return out.getvalue(), f"multipart/form-data; boundary={boundary}"


# --- API wrappers ---------------------------------------------------------------------------------

def chat(messages, stream=False, **params):
    """OpenAI-style chat completion. With stream=True, yields content deltas."""
    body = {"model": "apple-foundation-model", "messages": messages, **params}
    if not stream:
        return request("POST", "/v1/chat/completions", body)
    body["stream"] = True
    body["stream_options"] = {"include_usage": True}
    req = urllib.request.Request(BASE + "/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")

    def events():
        try:
            resp = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            try:
                detail = json.loads(detail)["error"]["message"]
            except Exception:
                pass
            raise MLError(f"HTTP {e.code}: {detail}") from None
        with resp:
            for line in resp:
                line = line.strip()
                if not line.startswith(b"data: "):
                    continue
                payload = line[6:]
                if payload == b"[DONE]":
                    return
                event = json.loads(payload)
                if "error" in event:
                    raise MLError(event["error"].get("message", "stream error"))
                yield event
    return events()


def zip_model(path):
    """Returns upload bytes for a .mlpackage/.mlmodelc directory, or the file itself."""
    if os.path.isdir(path):
        buf = io.BytesIO()
        root = os.path.dirname(os.path.abspath(path))
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as z:
            for dirpath, _, filenames in os.walk(path):
                for f in filenames:
                    full = os.path.join(dirpath, f)
                    z.write(full, os.path.relpath(full, root))
        return buf.getvalue()
    with open(path, "rb") as f:
        return f.read()


def upload_model(path, name=None):
    name = name or os.path.splitext(os.path.basename(path.rstrip("/")))[0]
    return request("POST", f"/v1/coreml/models?name={urllib.request.quote(name)}", zip_model(path),
                   {"Content-Type": "application/octet-stream"})


def predict(model_id, inputs, compute_units="all", **params):
    return request("POST", f"/v1/coreml/models/{model_id}/predict",
                   {"inputs": inputs, "compute_units": compute_units, **params})


def image_b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode()


def transcribe(path, response_format="json", language=None):
    with open(path, "rb") as f:
        data = f.read()
    fields = {"model": "whisper-1", "response_format": response_format}
    if language:
        fields["language"] = language
    body, ctype = multipart(fields, {"file": (os.path.basename(path), data, "application/octet-stream")})
    out = request("POST", "/v1/audio/transcriptions", body, {"Content-Type": ctype},
                  raw=response_format in ("text", "srt", "vtt"))
    return out.decode() if isinstance(out, bytes) else out


# --- CLI ------------------------------------------------------------------------------------------

def image_input_name(model_id):
    desc = request("GET", f"/v1/coreml/models/{model_id}")
    for i in desc["inputs"]:
        if i["type"] == "image":
            return i["name"]
    raise MLError(f"{model_id} has no image input")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command")
    p.add_argument("args", nargs="*")
    p.add_argument("--stream", action="store_true")
    p.add_argument("--json-schema", action="store_true", help="chat: demo structured output")
    p.add_argument("--name")
    p.add_argument("--units", default="all")
    p.add_argument("--runs", type=int, default=50)
    p.add_argument("--format", default="json")
    p.add_argument("--language")
    a = p.parse_args()
    show = lambda o: print(json.dumps(o, indent=2))

    if a.command == "health":
        show(request("GET", "/health"))
    elif a.command == "caps":
        show(request("GET", "/v1/capabilities"))
    elif a.command == "chat":
        messages = [{"role": "system", "content": "You are concise."},
                    {"role": "user", "content": " ".join(a.args) or "Say hello from the Neural Engine."}]
        params = {}
        if a.json_schema:
            params["response_format"] = {"type": "json_schema", "json_schema": {"name": "Answer", "schema": {
                "type": "object", "required": ["title", "tags"],
                "properties": {"title": {"type": "string"}, "tags": {"type": "array", "items": {"type": "string"}}}}}}
        if a.stream:
            start, first, n = time.time(), None, 0
            for ev in chat(messages, stream=True, **params):
                for choice in ev.get("choices", []):
                    text = choice.get("delta", {}).get("content")
                    if text:
                        first = first or time.time()
                        n += 1
                        print(text, end="", flush=True)
                if ev.get("usage"):
                    u = ev["usage"]
                    dt = time.time() - (first or start)
                    print(f"\n\n[ttft {((first or start) - start) * 1000:.0f} ms, {u['completion_tokens']} tokens, "
                          f"{u['completion_tokens'] / dt if dt > 0 else 0:.1f} tok/s after first token]", file=sys.stderr)
            print()
        else:
            show(chat(messages, **params))
    elif a.command == "upload":
        show(upload_model(a.args[0], a.name))
    elif a.command == "models":
        show(request("GET", "/v1/coreml/models"))
    elif a.command == "describe":
        show(request("GET", f"/v1/coreml/models/{a.args[0]}"))
    elif a.command == "plan":
        show(request("GET", f"/v1/coreml/models/{a.args[0]}/plan?compute_units={a.units}"))
    elif a.command == "classify":
        model_id, image = a.args
        out = predict(model_id, {image_input_name(model_id): image_b64(image)}, a.units, top_k=5)
        for name, value in out["outputs"].items():
            if isinstance(value, dict) and "top" in value:
                for t in value["top"]:
                    print(f"{t['probability']:.3f}  {t['label']}")
        print(json.dumps(out["timing"]))
    elif a.command == "bench":
        model_id, image = a.args
        inputs = {image_input_name(model_id): image_b64(image)}
        print(f"{'compute_units':<20}{'load ms':>10}{'first ms':>10}{'median ms':>11}{'min ms':>9}{'p90 ms':>9}")
        for units in ("cpuOnly", "cpuAndGPU", "cpuAndNeuralEngine", "all"):
            t = predict(model_id, inputs, units, repeat=a.runs, top_k=1)["timing"]
            print(f"{units:<20}{t.get('load_ms', 0):>10.1f}{t.get('first_ms', t['predict_ms']):>10.2f}"
                  f"{t.get('median_ms', t['predict_ms']):>11.2f}{t.get('min_ms', 0):>9.2f}{t.get('p90_ms', 0):>9.2f}")
    elif a.command == "transcribe":
        out = transcribe(a.args[0], a.format, a.language)
        print(out if isinstance(out, str) else json.dumps(out, indent=2))
    else:
        p.error(f"unknown command {a.command}")


if __name__ == "__main__":
    try:
        main()
    except MLError as e:
        sys.exit(f"mdock-ml: {e}")
