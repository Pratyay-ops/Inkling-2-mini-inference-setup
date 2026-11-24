"""End-to-end check of the OpenAI-compatible API, standard library only.

Checks: /health, auth is enforced, /v1/models, chat (with reasoning split out), streaming,
tool calling, and image input. Exits non-zero on the first failure.
Usage: INKLING_API_KEY=sk-inkling-... python3 -I smoke_test.py --base-url http://127.0.0.1:8000 --model NAME
(or use scripts/smoke-test.sh, which supplies the local "ops" key)
"""
import argparse
import base64
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request
import zlib


class Api:
    def __init__(self, base_url: str, key: str):
        self.base = base_url.rstrip("/")
        self.key = key

    def request(self, method, path, body=None, auth=True, timeout=600):
        headers = {"Content-Type": "application/json"}
        if auth:
            headers["Authorization"] = f"Bearer {self.key}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, headers=headers, method=method)
        return urllib.request.urlopen(req, timeout=timeout)

    def json(self, method, path, body=None, **kw):
        with self.request(method, path, body, **kw) as r:
            return json.load(r)


def load_key(path):
    if path:
        with open(path) as f:
            return f.read().strip()
    key = os.environ.get("INKLING_API_KEY", "").strip()
    if not key:
        sys.exit("no API key: pass --api-key-file or set INKLING_API_KEY")
    return key


def solid_png(rgb, size=64) -> str:
    """A size x size single-colour PNG as a data URL, no imaging library needed."""
    raw = zlib.compress((b"\x00" + bytes(rgb) * size) * size)

    def chunk(tag, payload):
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", raw) + chunk(b"IEND", b"")
    return "data:image/png;base64," + base64.b64encode(png).decode()


def reasoning_of(msg) -> str:
    return msg.get("reasoning_content") or msg.get("reasoning") or ""


def check(name, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{('  -- ' + detail) if detail else ''}")
    if not ok:
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--api-key-file", help="file holding the key; default: $INKLING_API_KEY")
    ap.add_argument("--model", required=True)
    ap.add_argument("--effort", default="low", help="reasoning_effort for the checks (keeps them fast)")
    a = ap.parse_args()
    api = Api(a.base_url, load_key(a.api_key_file))
    print(f"smoke test against {api.base} model={a.model} reasoning_effort={a.effort}")

    with api.request("GET", "/health", auth=False) as r:
        check("/health", r.status == 200)

    def status_of(method, path, body=None, key=None):
        probe = Api(a.base_url, key) if key is not None else api
        try:
            with probe.request(method, path, body, auth=key != "") as resp:
                return resp.status, resp.headers
        except urllib.error.HTTPError as e:
            return e.code, e.headers

    code, _ = status_of("GET", "/v1/models", key="")
    check("no key -> 401", code == 401, f"HTTP {code}")
    code, _ = status_of("GET", "/v1/models", key="sk-inkling-" + "0" * 64)
    check("wrong key -> 401", code == 401, f"HTTP {code}")
    # Routes vLLM serves but the proxy must not expose (some skip vLLM's own key check).
    for method, path in [("GET", "/metrics"), ("POST", "/invocations"), ("POST", "/tokenize"),
                         ("GET", "/version"), ("POST", "/v1/embeddings")]:
        code, _ = status_of(method, path, body={} if method == "POST" else None)
        check(f"{method} {path} blocked", code == 404, f"HTTP {code} with a valid key")

    code, headers = status_of("GET", "/v1/models")
    check("request id header", code == 200 and bool(headers.get("X-Request-Id")), f"X-Request-Id={headers.get('X-Request-Id')}")
    models = api.json("GET", "/v1/models")
    ids = [m["id"] for m in models["data"]]
    check("/v1/models lists the model", a.model in ids,
          f"{ids}, max_model_len={models['data'][0].get('max_model_len')}")

    t = time.time()
    r = api.json("POST", "/v1/chat/completions", {
        "model": a.model, "reasoning_effort": a.effort, "max_tokens": 4096,
        "messages": [{"role": "user", "content": "What is 17 * 23? Answer with just the number."}],
    })
    msg = r["choices"][0]["message"]
    content = msg.get("content") or ""
    check("chat completion", "391" in content,
          f"content={content.strip()!r} usage={r['usage']} {time.time() - t:.1f}s")
    check("reasoning split from content", "<|" not in content,
          f"reasoning field has {len(reasoning_of(msg))} chars, content has no template tokens")

    t = time.time()
    first, n_chunks, text, done, usage = None, 0, "", False, None
    with api.request("POST", "/v1/chat/completions", {
        "model": a.model, "reasoning_effort": a.effort, "max_tokens": 2048, "stream": True,
        "stream_options": {"include_usage": True},
        "messages": [{"role": "user", "content": "Name three primary colours, comma separated."}],
    }) as resp:
        for line in resp:
            line = line.decode().strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                done = True
                break
            ev = json.loads(payload)
            usage = ev.get("usage") or usage
            for ch in ev.get("choices", []):
                d = ch.get("delta", {})
                if first is None and (d.get("content") or reasoning_of(d)):
                    first = time.time() - t
                text += d.get("content") or ""
                n_chunks += 1
    check("streaming (SSE)", done and bool(text.strip()) and first is not None,
          f"ttft={first or 0:.2f}s chunks={n_chunks} text={text.strip()[:60]!r} usage={usage}")

    tools = [{"type": "function", "function": {
        "name": "get_weather", "description": "Get the current weather for a city.",
        "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}}]
    r = api.json("POST", "/v1/chat/completions", {
        "model": a.model, "reasoning_effort": a.effort, "max_tokens": 4096, "tools": tools, "tool_choice": "auto",
        "messages": [{"role": "user", "content": "What's the weather in Pune right now? Use the tool."}],
    })
    calls = r["choices"][0]["message"].get("tool_calls") or []
    args = json.loads(calls[0]["function"]["arguments"]) if calls else {}
    check("tool call", bool(calls) and calls[0]["function"]["name"] == "get_weather" and "pune" in str(args).lower(),
          f"calls={[(c['function']['name'], c['function']['arguments']) for c in calls]} "
          f"finish_reason={r['choices'][0]['finish_reason']}")

    r = api.json("POST", "/v1/chat/completions", {
        "model": a.model, "reasoning_effort": a.effort, "max_tokens": 4096,
        "messages": [{"role": "user", "content": [
            {"type": "text", "text": "What single colour fills this image? One word."},
            {"type": "image_url", "image_url": {"url": solid_png((220, 20, 20))}}]}],
    })
    content = (r["choices"][0]["message"].get("content") or "").lower()
    check("image input", "red" in content, f"content={content.strip()[:60]!r}")

    print("all checks passed")


if __name__ == "__main__":
    main()
