# Benchmarks (this box)

**Hardware:** MSI EdgeXpert (NVIDIA GB10, 128 GB unified memory, DGX OS 7.5.0, driver 580.159.03).
**Stack:** `vllm/vllm-openai:inkling-2-mini@sha256:c2dc759f…d1449e` (vLLM `0.1.dev25855+g7cb5dae22`, torch 2.14 +
CUDA 13.0), official `thinkingmachines/Inkling-2-Mini@7a67ae23` weights, settings as in `.env.example`
(262K context, 32 sequences, 8192 batched tokens, BF16 KV, prefix caching, 0.75 memory utilization).
Measured 2026-11-24 **through the nginx proxy**, so the numbers include the auth hop.

## Method

`scripts/bench.sh --concurrency 1,4,8,16,32 --no-fixed-length --max-tokens 1024`:

- C client threads each send 2 streaming chat requests; prompts rotate through a mix of chat, code and agent-style tasks.
- `reasoning_effort: low`, model-default sampling (temperature 1.0), natural output length (up to 1024 tokens,
  reasoning included).
- **Aggregate** = all output tokens / wall time. **Per stream** = median decode speed of one request after its first token.
- TTFT is time to the first token of any kind (reasoning or content).
- Small samples (2 requests at C1), so treat differences under ~10% as noise.

## DSpark (MTP speculative decoding) on vs off

| Concurrency | DSpark on: aggregate tok/s | per stream | TTFT p50 | DSpark off: aggregate tok/s | per stream | TTFT p50 | DSpark gain |
|---|---|---|---|---|---|---|---|
| 1 | 35.5 | 36.8 | 0.20 s | 38.3 | 39.1 | 0.17 s | −7% |
| 4 | 88.8 | 25.2 | 0.36 s | 58.5 | 21.6 | 2.67 s | +52% |
| 8 | 138.2 | 19.3 | 0.44 s | 83.3 | 15.8 | 3.69 s | +66% |
| 16 | 198.2 | 15.3 | 3.04 s | 114.6 | 11.7 | 5.76 s | +73% |
| 32 | **317.9** | 13.1 | 3.20 s | 176.2 | 8.5 | 4.34 s | **+80%** |

0 errors in 246 requests. DSpark mean acceptance: 2.86 tokens per verification step (vLLM log, 36 windows).

**Reading it:**
- For a single chat user, DSpark costs about 7%. Prose drafts are accepted less often, which matches the community
  finding that it "ties on chat".
- Under concurrency it is the biggest lever available: +52% to +80% throughput.
- Queueing is also much better (TTFT 0.44 s vs 3.69 s at C8), because requests finish sooner and free their slots.
  A gateway serving several users is the concurrent case, so **DSpark stays on by default**.
- At C32, 318 tok/s is above the best published single-Spark figure for the official weights (244 tok/s,
  sambit9238, with different prompts and settings; see [ENGINE_SELECTION.md](ENGINE_SELECTION.md)).

## Startup and memory

| | |
|---|---|
| Cold start (first run, empty compile cache) | 312 s: weights 93 s, then compile, autotune and CUDA graphs for model + drafter |
| Warm restart (compile cache in `~/.cache/inkling/vllm`) | 214 s (DSpark off) |
| Weights in memory | 19.15 GiB |
| KV cache | 645,084 tokens (2.46× the 262,144-token maximum context) |
| vLLM cap at 0.75 utilization | 91.27 GiB, leaving ~20 GiB available to the rest of the box |

## Reproduce

```bash
scripts/bench.sh --concurrency 1,4,8,16,32 --no-fixed-length --max-tokens 1024 --label dspark
# set SPEC_DECODE=off in .env, scripts/up.sh, then:
scripts/bench.sh --concurrency 1,4,8,16,32 --no-fixed-length --max-tokens 1024 --label spec-off
```

Raw JSON lands in `results/` (git-ignored).
