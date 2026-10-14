#!/usr/bin/env python3
"""Measures generation speed through the mdock-llm API (stdlib only).

  accel/llm/bench-api.py --socket ~/.mdock/accel/llm.sock --model qwen2.5-0.5b-q4_k_m
  python3 bench-api.py --url http://llm.mdock.internal:8200 --model ...    # from a container

Streams /v1/completions with ignore_eos and reports, per run, the client-side decode rate
(tokens after the first / time from first to last token), time to first token, and llama-server's
own prompt and decode timings.
"""
import argparse, http.client, json, socket, statistics, time


class UnixHTTPConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=600)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.path)


def connect(args):
    if args.socket:
        return UnixHTTPConnection(args.socket)
    host = args.url.split("://", 1)[-1].rstrip("/")
    return http.client.HTTPConnection(host, timeout=600)


def run(args, prompt):
    body = {"model": args.model, "prompt": prompt, "max_tokens": args.n, "stream": True,
            "ignore_eos": True, "temperature": 0, "cache_prompt": False}
    conn = connect(args)
    start = time.perf_counter()
    conn.request("POST", "/v1/completions", json.dumps(body), {"Content-Type": "application/json"})
    resp = conn.getresponse()
    if resp.status != 200:
        raise SystemExit(f"HTTP {resp.status}: {resp.read()[:300]}")
    stamps, timings = [], None
    for raw in resp:
        line = raw.decode().strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue
        chunk = json.loads(line[5:])
        if chunk.get("timings"):
            timings = chunk["timings"]
        if chunk.get("choices") and chunk["choices"][0].get("text"):
            stamps.append(time.perf_counter())
    conn.close()
    decode = (len(stamps) - 1) / (stamps[-1] - stamps[0]) if len(stamps) > 1 else 0
    return decode, stamps[0] - start if stamps else 0, timings or {}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--socket")
    p.add_argument("--url", default="http://127.0.0.1:8200")
    p.add_argument("--model", required=True)
    p.add_argument("-n", type=int, default=128)
    p.add_argument("-p", type=int, default=512, help="approximate prompt tokens")
    p.add_argument("-r", type=int, default=5)
    args = p.parse_args()
    run(args, "warm up")
    rows = []
    for i in range(args.r):
        # A different prompt each run so the prompt cache can't skip prefill.
        prompt = f"Run {i} {time.time()}. " + "The quick brown fox jumps over the lazy dog. " * (args.p // 10)
        decode, ttft, t = run(args, prompt)
        rows.append((decode, ttft, t.get("prompt_per_second", 0), t.get("predicted_per_second", 0), t.get("prompt_n", 0)))
        print(f"run {i}: client decode {decode:6.1f} tok/s  ttft {ttft*1000:6.0f} ms  "
              f"server pp{t.get('prompt_n', 0)} {t.get('prompt_per_second', 0):7.1f} tok/s  "
              f"server tg {t.get('predicted_per_second', 0):6.1f} tok/s")
    med = lambda k: statistics.median(r[k] for r in rows)
    print(f"median: client decode {med(0):.1f} tok/s, ttft {med(1)*1000:.0f} ms, "
          f"server prompt {med(2):.1f} tok/s, server decode {med(3):.1f} tok/s")


if __name__ == "__main__":
    main()
