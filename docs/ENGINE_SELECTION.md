# Engine selection: why vLLM for Inkling 2 Mini on GB10

Researched 2026-11-24, four days after Inkling 2 Mini was released (2026-11-20). Things move fast; recheck
the support column below before changing engines.

## The constraint that decides most of it

Inkling 2 Mini is a **looped** mixture-of-experts transformer: 26.4B total parameters, 3.4B active, and its
middle layers run three times per token (about 5.4B effective active parameters). It takes image input and
ships as one ~20 GB checkpoint in NVFP4 (experts) plus MXFP8 (last four layers), with a bundled
MTP-style drafter (`mtp.safetensors`, used by the "DSpark" speculative method).

The fast GB10-specific engines that r/LocalLLaMA has been experimenting with (Basalt, NInfer and its GB10
forks, Infernix, Strata) are hand-written kernels for the **Qwen3.x** families. None of them implements the
looped architecture, so they cannot serve this model, however fast they are on Qwen.

## Candidates

| Engine | Inkling 2 Mini on DGX Spark today | Evidence | Verdict |
|---|---|---|---|
| **vLLM** (`vllm/vllm-openai:inkling-2-mini`, build `0.1.dev25855+g7cb5dae22`, cu130, arm64) | Supported. Official recipe lists DGX Spark; 3+ independent GB10 write-ups with measured numbers, all on this exact image | Recipe, tedngai, tonyd2wild, dedene, Classmethod (below) | **Chosen** |
| SGLang (`lmsysorg/sglang:inkling-2-mini`, PR #51926) | Listed as supported in the official cookbook (gsm8k accuracy only) | No published GB10 throughput; launch command only via an interactive page; arm64 build not stated | Credible alternative; re-evaluate once it has GB10 numbers |
| llama.cpp (GGUF: Unsloth, ggml-org) | Partial. Looped support was still in unmerged PRs (#32694, #32695) at launch; reports of gibberish from some GGUF/build combos | HN thread, local-run guides | Not production-ready for this model yet; no batching story comparable to vLLM |
| TokenSpeed | Inkling 2 Mini recipe is AMD MI350X only | lightseek.org recipe page | No GB10 path |
| NInfer / ninfer-gb10 / Infernix | Qwen3.5-3.8 only; no Inkling or looped-model support | Fork READMEs | Not applicable |
| Basalt (and the `basalt-arm-sm121` ports) | Qwen3.8 MoE only; upstream has no sm_121 support yet | GitHub issues, NVIDIA forum | Not applicable |
| Strata | Qwen3.8-Flash-Next expert offload; no GB10 or Inkling numbers | Blog mentions only | Not applicable |
| Unsloth's engine (llama.cpp fork `b12649-mix-c7059d6`, UD-Q4_K_XL GGUF + DSpark) | Runs on GB10 (sm_121 prebuilt) | **Measured on this box:** ties vLLM at 1 user (36 tok/s), 3.7× slower at 32 users (86 vs 318 tok/s); 17 s startup | Good for single-user or desktop use; not for a multi-user gateway. See [BENCHMARKS.md](BENCHMARKS.md) |
| Ollama / LM Studio / MLX | Consumer runtimes; MLX-Serve didn't run it at launch | HN | Not suited to a multi-user gateway backend |

## What the GB10 measurements say (vLLM, official weights)

All of these are self-reported community numbers on one DGX Spark, on the same image as this repo.

| Source | Setup | Result |
|---|---|---|
| Classmethod | Recipe verbatim (262K, DSpark 7) | 37.8 tok/s single stream, TTFT 0.21 s, startup 380 s |
| Classmethod | 131K, 8 seqs, no spec | C1 39.4, C4 86.9, C8 133.4 tok/s aggregate |
| sambit9238 (official weights) | 131K, 32 seqs, T=1.0 chat | MTP off: C1 34.2, C8 107, C32 218 tok/s. **MTP on: C1 38.9, C8 121, C32 244 tok/s** |
| tedngai | 400K, FP8 KV, DSpark, 8 seqs | Code-shaped C1 76-94 tok/s (71% draft acceptance); chat ~35-40 tok/s (15-20% acceptance); DSpark on/off tie on chat |
| tonyd2wild | 262K BF16 KV, 0.80 util | ~40-48 tok/s short chats; 69-scenario tool eval 88.4 (BF16 KV) vs 87.0 (FP8 KV) |
| dedene | 262K, 8 seqs, 32 GiB KV | 43.2 tok/s weighted single stream, 81.5 tok/s at 4 in flight, ~56 GB server memory |

Takeaways that shaped the defaults in `.env.example`:

- **DSpark on.** On chat it is a wash for a single stream, but it helps under concurrency (+13% at C8, +12% at
  C32) and more than doubles single-stream speed on code-shaped output. A gateway sees a mix of both.
  **Measured on this box:** −7% at C1 but +52% to +80% from C4 to C32 (318 vs 176 tok/s at C32). See
  [BENCHMARKS.md](BENCHMARKS.md).
- **32 concurrent sequences.** Aggregate throughput was still climbing at C32 (244 tok/s).
- **BF16 KV cache.** FP8 KV buys capacity we don't need at 262K and showed longer reasoning and a lower tool-eval score.
- **262,144 context.** That is the official Spark cap; 1M works but prefill at that length takes ~26 min.
- **Prefix caching on.** Gateways and agents resend long shared system prompts.
- **Memory headroom.** A unified-memory OOM on GB10 can hang the box until a power cycle. The first runs used
  `0.75`; the default is now `0.45` (~55 GiB active), with idle cache release down to ~22 GiB (see BENCHMARKS.md),
  which leaves far more room for the other users of this machine.

A modified community checkpoint (sambit9238 "M2", attention re-quantized to NVFP4) reached 55.5 tok/s single
stream, but MMLU-Pro dropped 0.637 → 0.574 and it needs a patched image. Not used.

## Known issues to watch

- **sm_121 shared-memory crash** (vllm#69012): the MoE router kernel can need more shared memory than GB10 has
  per block at large batched-token counts. The day-0 image avoids that path; if a newer image brings it back,
  set `MAX_NUM_BATCHED_TOKENS=2048` (or 1024).
- **Page cache and `cudaMemGetInfo`.** On GB10, CUDA reports page cache as used memory. Right after the downloads
  it showed 23.7 GiB free while 110 GiB was reclaimable. Community guides fix this with `drop_caches`, but this
  image's vLLM already uses `MemAvailable` on integrated GPUs (`vllm/utils/mem_utils.py`, `device_memory_info`),
  so no workaround is needed. `scripts/up.sh` runs the same check, with headroom, before starting.
- **Overthinking.** With no `reasoning_effort`, the chat template defaults to 0.9 ("high"). If thinking uses up
  `max_tokens`, `content` comes back empty. Gateways should send `reasoning_effort` and a sensible `max_tokens`.
- **Tool selection.** Fine for a handful of tools; one review saw weak selection from 40 tools. Test your own agent harness.

## Sources

- Thinking Machines: [announcement](https://thinkingmachines.ai/news/inkling-2-mini/), [model card](https://thinkingmachines.ai/model-card/inkling-2-mini/), [Hugging Face](https://huggingface.co/thinkingmachines/Inkling-2-Mini)
- [vLLM recipe (DGX Spark)](https://recipes.vllm.ai/thinkingmachines/Inkling-2-Mini?hardware=dgx_spark_gb10), [SGLang cookbook](https://docs.sglang.io/cookbook/autoregressive/ThinkingMachines/Inkling-2-Mini), [TokenSpeed recipes](https://lightseek.org/tokenspeed/recipes/models#inkling-2-mini)
- GB10 write-ups: [tedngai/inkling-2-mini-dgx-spark](https://github.com/tedngai/inkling-2-mini-dgx-spark), [tonyd2wild/Inkling-2-Mini-NVFP4-DGX-Spark](https://github.com/tonyd2wild/Inkling-2-Mini-NVFP4-DGX-Spark), [dedene/Inkling-2-Mini-DGX-Spark](https://github.com/dedene/Inkling-2-Mini-DGX-Spark), [Classmethod first touch](https://dev.classmethod.jp/en/articles/dgx-spark-inkling-2-mini-first-touch/), [sambit9238/Inkling-2-Mini-NVFP4-M2](https://huggingface.co/sambit9238/Inkling-2-Mini-NVFP4-M2)
- Other engines: [Basalt issues](https://github.com/jesdga95/basalt/issues), [Basalt on DGX Spark (NVIDIA forum)](https://forums.developer.nvidia.com/t/first-successful-basalt-qwen3-8-flash-next-moe-run-on-dgx-spark-24-576-experts-fully-resident-plus-a-linux-uma-memory-fix/389794), [gdevsnack-ai-labs/ninfer-gb10](https://github.com/gdevsnack-ai-labs/ninfer-gb10), [baristahaus/ninfer-gb10](https://github.com/baristahaus/ninfer-gb10), [Infernix](https://github.com/eugene-kamenev/Infernix-dgx-spark-gb10), [llama.cpp MTP on GB10](https://site-one-liart-13.vercel.app/en/dgx/llamacpp-mtp-speculative-decoding-qwen36-dgx-spark/)
- Community discussion: [Hacker News thread](https://news.ycombinator.com/item?id=50581260) (links the r/LocalLLaMA launch threads), [Atomic Engine write-up](https://explainx.ai/blog/atomic-engine-inkling-2-mini-3x-speed-memory-budget-november-2026)

r/LocalLLaMA itself blocks automated fetching, so its threads were read through the sources above that quote
them. Numbers from those threads are hearsay and none of them were on GB10.
