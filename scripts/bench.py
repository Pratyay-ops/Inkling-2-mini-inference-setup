"""Concurrency sweep against the OpenAI-compatible endpoint, standard library only.

For each concurrency level C, C client threads each send ROUNDS streaming chat requests drawn from
a realistic prompt mix. Per request it measures TTFT (first content or reasoning token) and decode
speed; per level it reports aggregate output tokens/s over wall time. Random-token prompts are
deliberately not used: they make speculative decoding (DSpark) look useless.
Usage: INKLING_API_KEY=sk-inkling-... python3 -I bench.py --base-url URL --model NAME [--concurrency 1,4,8,16,32]
(or use scripts/bench.sh, which supplies the local "ops" key)
"""
import argparse
import json
import os
import statistics
import sys
import threading
import time
import urllib.request
from datetime import datetime
from pathlib import Path

PROMPTS = {
    "chat": [
        "Explain how a heat pump works to a homeowner, in a few paragraphs.",
        "Write a polite email declining a meeting invitation and proposing two alternative times.",
        "Summarise the main causes and consequences of the 2008 financial crisis.",
        "Compare renting and buying a home for someone who may move cities in three years.",
    ],
    "code": [
        "Write a Python function that merges overlapping intervals, with type hints and a docstring, plus pytest tests.",
        "Implement an LRU cache class in TypeScript with get/put in O(1), and explain the design briefly.",
        "Write a SQL query that returns the top 3 products by revenue per region from orders(region, product, qty, price).",
        "Write a bash script that rotates log files in a directory, keeping the newest 7, with error handling.",
    ],
    "agent": [
        "Given this JSON, list every user whose plan is 'pro' and who has not logged in for 30 days, as a table: "
        '{"users":[{"id":1,"plan":"pro","last_login_days":45},{"id":2,"plan":"free","last_login_days":90},'
        '{"id":3,"plan":"pro","last_login_days":3},{"id":4,"plan":"pro","last_login_days":31}]}',
        "You are a support triage agent. Classify this ticket by product area, urgency and sentiment, then draft a "
        "reply: 'Since this morning's update the export button does nothing and our month-end report is due today.'",
    ],
}


def one_request(base, key, body, timeout):
    req = urllib.request.Request(
        base + "/v1/chat/completions", data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {key}"})
    t0 = time.perf_counter()
    first = None
    usage = None
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:") or line == "data: [DONE]":
                continue
            ev = json.loads(line[5:])
            usage = ev.get("usage") or usage
            for ch in ev.get("choices", []):
                d = ch.get("delta", {})
                if first is None and (d.get("content") or d.get("reasoning_content") or d.get("reasoning")):
                    first = time.perf_counter()
    end = time.perf_counter()
    out = (usage or {}).get("completion_tokens", 0)
    ttft = (first or end) - t0
    decode = (out - 1) / (end - first) if first and end > first and out > 1 else 0.0
    return {"ttft_s": ttft, "decode_tps": decode, "out_tokens": out,
            "in_tokens": (usage or {}).get("prompt_tokens", 0), "latency_s": end - t0}


def run_level(a, key, prompts, conc):
    results, errors = [], []
    lock = threading.Lock()

    def worker(i):
        for r in range(a.rounds):
            prompt = prompts[(i * a.rounds + r) % len(prompts)]
            body = {"model": a.model, "stream": True, "stream_options": {"include_usage": True},
                    "max_tokens": a.max_tokens, "reasoning_effort": a.effort,
                    "messages": [{"role": "user", "content": prompt}]}
            if a.fixed_length:
                body["ignore_eos"] = True  # vLLM extension: every request decodes exactly max_tokens
            if a.temperature is not None:
                body["temperature"] = a.temperature
            try:
                res = one_request(a.base_url, key, body, a.timeout)
                with lock:
                    results.append(res)
            except Exception as e:  # report, keep the sweep going
                with lock:
                    errors.append(repr(e))

    t0 = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(i,)) for i in range(conc)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t0
    total_out = sum(r["out_tokens"] for r in results)

    def med(k):
        return statistics.median(r[k] for r in results) if results else 0.0

    def p95(k):
        v = sorted(r[k] for r in results)
        return v[min(len(v) - 1, int(0.95 * len(v)))] if v else 0.0

    return {"concurrency": conc, "requests": len(results), "errors": errors, "wall_s": wall,
            "aggregate_out_tps": total_out / wall if wall else 0.0,
            "per_stream_decode_tps_median": med("decode_tps"),
            "ttft_s_median": med("ttft_s"), "ttft_s_p95": p95("ttft_s"),
            "out_tokens_total": total_out}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--api-key-file", help="file holding the key; default: $INKLING_API_KEY")
    ap.add_argument("--model", required=True)
    ap.add_argument("--concurrency", default="1,4,8,16,32")
    ap.add_argument("--rounds", type=int, default=2, help="requests per client thread per level")
    ap.add_argument("--max-tokens", type=int, default=512)
    ap.add_argument("--fixed-length", action=argparse.BooleanOptionalAction, default=True,
                    help="force exactly --max-tokens output per request (ignore_eos)")
    ap.add_argument("--workload", choices=[*PROMPTS, "mixed"], default="mixed")
    ap.add_argument("--effort", default="low", help="reasoning_effort sent with each request")
    ap.add_argument("--temperature", type=float, default=None, help="default: model's generation_config (1.0)")
    ap.add_argument("--timeout", type=float, default=900)
    ap.add_argument("--label", default="", help="tag stored in the results file, e.g. 'dspark' or 'spec-off'")
    ap.add_argument("--out-dir", default=str(Path(__file__).resolve().parent.parent / "results"))
    a = ap.parse_args()

    if a.api_key_file:
        with open(a.api_key_file) as f:
            key = f.read().strip()
    else:
        key = os.environ.get("INKLING_API_KEY", "").strip() or sys.exit("no API key: pass --api-key-file or set INKLING_API_KEY")
    a.base_url = a.base_url.rstrip("/")
    prompts = sum(PROMPTS.values(), []) if a.workload == "mixed" else PROMPTS[a.workload]
    levels = [int(c) for c in a.concurrency.split(",")]

    print(f"bench {a.base_url} model={a.model} workload={a.workload} max_tokens={a.max_tokens} "
          f"fixed_length={a.fixed_length} effort={a.effort} label={a.label or '-'}")
    run_level(a, key, prompts[:1], 1)  # warm-up (prefix cache, graphs), not reported
    print(f"{'conc':>4} {'reqs':>4} {'agg tok/s':>10} {'per-stream tok/s':>17} {'TTFT p50':>9} {'TTFT p95':>9} {'err':>4}")
    rows = []
    for c in levels:
        row = run_level(a, key, prompts, c)
        rows.append(row)
        print(f"{c:>4} {row['requests']:>4} {row['aggregate_out_tps']:>10.1f} {row['per_stream_decode_tps_median']:>17.1f} "
              f"{row['ttft_s_median']:>8.2f}s {row['ttft_s_p95']:>8.2f}s {len(row['errors']):>4}")
        for e in row["errors"][:3]:
            print(f"      error: {e[:160]}")

    out = Path(a.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"bench-{datetime.now():%Y%m%d-%H%M%S}{('-' + a.label) if a.label else ''}.json"
    path.write_text(json.dumps({"args": {k: v for k, v in vars(a).items()}, "levels": rows}, indent=2))
    print(f"saved {path}")


if __name__ == "__main__":
    main()
