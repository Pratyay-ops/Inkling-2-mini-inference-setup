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

## vLLM vs Unsloth's engine (GGUF)

Same harness, prompts and settings, measured 2026-11-24 directly against each server on this box (vLLM through
the proxy, whose hop costs well under a millisecond). Unsloth engine: their llama.cpp fork `b12649-mix-c7059d6`,
prebuilt `linux-arm64-cuda13-portable` (sha256 verified; sm_121 supported), recommended `UD-Q4_K_XL` GGUF
(17.6 GB), DSpark drafter at their tuned depth 2, `-np 32` with unified KV, `-c 262144`, `--reasoning-effort low`,
temperature 1.0 / top-p 1.0.

| Concurrency | vLLM + DSpark: aggregate tok/s | per stream | TTFT p50 | Unsloth + DSpark: aggregate tok/s | per stream | TTFT p50 | vLLM vs Unsloth |
|---|---|---|---|---|---|---|---|
| 1 | 35.5 | 36.8 | 0.20 s | 36.2 | 37.3 | 0.19 s | tie |
| 4 | 88.8 | 25.2 | 0.36 s | 63.8 | 18.3 | 0.67 s | +39% |
| 8 | 138.2 | 19.3 | 0.44 s | 81.1 | 12.4 | 1.17 s | +70% |
| 16 | 198.2 | 15.3 | 3.04 s | 106.0 | 9.1 | 1.45 s | +87% |
| 32 | **317.9** | 13.1 | 3.20 s | 86.0 | 3.3 | 4.36 s | **3.7×** |

0 errors on either. Unsloth DSpark acceptance: 54.1% of drafted tokens.

**Reading it:**
- **One user:** a tie. Unsloth's "1.9× faster" compares their build with their previous build and mainline
  llama.cpp on B200 and RTX PRO 6000. It is not a comparison with vLLM, and on GB10 it doesn't show up as a
  lead over vLLM.
- **Concurrent users:** vLLM pulls away, and Unsloth's aggregate falls at 32 (below its 16-request figure).
  That's the gateway case, so **vLLM stays**.
- **Where Unsloth wins:** startup in **~17 s** (vLLM 3.5-5 min) and a smaller download (17.6 vs 20.2 GB). It's a
  good fit for a single-user desktop or for fast iteration.
- **Quality was not measured here.** UD-Q4_K_XL re-quantizes weights that ship natively in NVFP4. Unsloth reports
  KLD 0.0107 against their Q8 GGUF, not against the original checkpoint.

## Startup and memory

| | |
|---|---|
| Cold start (first run, empty compile cache) | 312 s: weights 93 s, then compile, autotune and CUDA graphs for model + drafter |
| Warm restart (compile cache in `~/.cache/inkling/vllm`) | 214 s (DSpark off) |
| Weights in memory | 19.15 GiB |
| KV cache at 0.75 (first runs) | 645,084 tokens (2.46× the 262,144-token maximum context), vLLM ~87-90 GiB |
| KV cache at **0.45 (current default)** | 277,440 tokens (1.06× the maximum context), 27.14 GiB |

## Memory states (0.45 cap, idle cache release)

Measured 2026-11-24 with `nvidia-smi` and `/proc/meminfo`:

| State | vLLM memory | Box memory available |
|---|---|---|
| Active (KV pool reserved) | 49.5 GiB | 59 GiB |
| **Idle**: after `CACHE_IDLE_MINUTES`, caches cleared and KV released | **21.7 GiB** (weights + runtime) | **86 GiB** |
| First request after idle | wakes in **1.1-1.2 s**, then back to 49.5 GiB | 59 GiB |

How memory behaves under load (0.75 cap, KV pool 64 GiB, unique ~2.2K-token prompts):
- **Process memory stays flat:** 87.2 GiB idle, 89.6 GiB with 32 concurrent requests (+2.4 GiB of scratch,
  kept for reuse). More requests than fit wait in a queue; memory never grows past the cap.
- **Inside the pool, steady state:** 32 conversations generating together used 18.4% (11.8 GiB, ~0.37 GiB each),
  with 0 queued and 0 preempted.
- **During prefill** (prompt being read), usage spikes, because every layer holds the whole prompt until the
  20 local (1,024-token sliding-window) layers drop what's outside their window. 31 new prompts at once
  peaked at 39% (~25 GiB). One ~35K-token prompt peaked at 17.8 GiB.

Throughput at the 0.45 cap with sleep mode on (same method as above, 2 requests per thread):
C1 32.5 tok/s, C8 134.7, C32 304.0, all within the noise of the 0.75 runs (35.5 / 138.2 / 317.9). 0 errors.

## Reproduce

```bash
scripts/bench.sh --concurrency 1,4,8,16,32 --no-fixed-length --max-tokens 1024 --label dspark
# set SPEC_DECODE=off in .env, scripts/up.sh, then:
scripts/bench.sh --concurrency 1,4,8,16,32 --no-fixed-length --max-tokens 1024 --label spec-off
```

Raw JSON lands in `results/` (git-ignored).
