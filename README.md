# Inkling 2 Mini inference on a DGX Spark-class box

An OpenAI-compatible endpoint for [Thinking Machines' Inkling 2 Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini)
on one NVIDIA GB10 machine (this repo runs on an MSI EdgeXpert; DGX Spark, ASUS Ascent GX10 and other GB10
boxes are the same platform). It serves chat completions with streaming, tool calling, reasoning and image
input, ready to sit behind an LLM gateway.

**Stack:** vLLM (`vllm/vllm-openai:inkling-2-mini`, pinned by digest) in Docker, the official NVFP4/MXFP8
checkpoint, DSpark speculative decoding (the model's bundled MTP drafter), prefix caching, 262K context,
32 concurrent sequences. In front of it, an nginx proxy is the only thing clients can reach. It handles
per-client API keys, a path allowlist and rate limits; vLLM itself publishes no port.
[Why vLLM and not llama.cpp, SGLang, Basalt, NInfer...](docs/ENGINE_SELECTION.md) · [Security model and public-access options](docs/SECURITY.md)

## Quick start

Needs: GB10 with driver r580+, Docker with the NVIDIA container toolkit, your user in the `docker` group,
~35 GB disk, internet for the first download.

```bash
git clone https://github.com/Pratyay-ops/Inkling-2-mini-inference-setup.git
cd Inkling-2-mini-inference-setup
cp .env.example .env              # review the settings; images are already pinned by digest
scripts/download-model.sh          # ~20 GB, pinned revision, into ~/.cache/inkling/huggingface
scripts/up.sh                      # secrets, memory preflight, start, wait for /health (cold start ~5-7 min)
scripts/smoke-test.sh              # auth, blocked routes, chat, streaming, tools, image input
scripts/keys.sh add gateway        # the key your LLM gateway will use
```

Both containers restart on reboot (`restart: unless-stopped`) until you run `scripts/down.sh`.

## Connect your gateway

| Setting | Value |
|---|---|
| Base URL | Public: `https://<TS_HOSTNAME>.<your-tailnet>.ts.net/v1` with Tailscale Funnel (`scripts/funnel.sh url` prints it). Local: `http://127.0.0.1:8000/v1`. LAN: `http://<this-host>:8000/v1` with `BIND_ADDRESS=0.0.0.0` |
| API key | A per-client key from `scripts/keys.sh add <name>`, sent as `Authorization: Bearer sk-inkling-…` |
| Model | `inkling-2-mini` |
| Endpoints | `/v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/models`, plus `/health` (no key). Everything else returns 404 |

```bash
export INKLING_BASE_URL="$(scripts/funnel.sh url)"   # or http://127.0.0.1:8000/v1 on the box itself
export INKLING_API_KEY="sk-inkling-..."              # from scripts/keys.sh add <name>
curl "$INKLING_BASE_URL/chat/completions" \
  -H "Authorization: Bearer $INKLING_API_KEY" -H "Content-Type: application/json" \
  -d '{"model": "inkling-2-mini", "reasoning_effort": "low", "max_tokens": 2048,
       "messages": [{"role": "user", "content": "Hello!"}]}'
```

LiteLLM (`config.yaml`):

```yaml
model_list:
  - model_name: inkling-2-mini
    litellm_params:
      model: hosted_vllm/inkling-2-mini
      api_base: https://inkling.<your-tailnet>.ts.net/v1
      api_key: os.environ/INKLING_API_KEY
      max_tokens: 8192
```

Any OpenAI SDK works too: `OpenAI(base_url="https://inkling.<your-tailnet>.ts.net/v1", api_key=...)`.

### Public access ($0, Tailscale Funnel)

This gives a public `https://<TS_HOSTNAME>.<your-tailnet>.ts.net` URL with a real certificate. It opens no
inbound ports, and nothing is exposed on the LAN: the Tailscale container only makes outbound connections.
TLS ends on this box, so Tailscale's relays carry only encrypted traffic. The per-client keys, allowlist and
rate limits all still apply, and the limits see each caller's real IP.

1. Set `PUBLIC_ACCESS=tailscale-funnel` in `.env` and run `scripts/up.sh`. Only the Tailscale container is
   added; vLLM keeps running.
2. Open the sign-in link it prints in **any** browser, e.g. on your laptop; you don't need to be at the box.
   `scripts/funnel.sh login` prints the link again.
3. `scripts/funnel.sh status` shows whether Funnel is live, and `scripts/funnel.sh url` prints the base URL for your gateway.

The free Personal plan is licensed for non-commercial use; see [docs/SECURITY.md](docs/SECURITY.md) for the
other options and their costs.

### Request tips

- **Send `reasoning_effort`.** The model always thinks first. Without the field the chat template uses 0.9
  ("high"). Accepted values: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or a number in [0, 0.99].
  `none` still produces some reasoning. Use `low` for chat-style traffic and `high` for hard problems.
- **Budget `max_tokens` for the thinking.** Reasoning tokens count against `max_tokens`; if they use it up,
  `content` is empty and `finish_reason` is `length`.
- Reasoning comes back separately in `message.reasoning` (`delta.reasoning` when streaming) and is never
  mixed into `content`. `usage.completion_tokens_details.reasoning_tokens` counts it.
- Defaults come from the model's `generation_config.json`: `temperature` 1.0, sampling on.
- Tool calling uses the standard `tools` / `tool_choice` fields.
- Images go in `image_url` content parts as base64 `data:` URLs. vLLM has no route to the internet (by design,
  see [SECURITY.md](docs/SECURITY.md)), so it can't download `http(s)://` image URLs.
- Use `stream: true` for long generations, especially behind a tunnel or load balancer with a response timeout.
- Errors are OpenAI-style JSON: 401 bad key, 404 route not exposed, 413 body too large, 429 rate limited
  (with `Retry-After`), 503 model server starting.

## Measured performance (this box)

Measured through the proxy, mixed chat/code/agent prompts, `reasoning_effort: low`
([method and full table](docs/BENCHMARKS.md)):

| Concurrent requests | Total output tok/s | Per request tok/s | Time to first token (p50) |
|---|---|---|---|
| 1 | 35.5 | 36.8 | 0.20 s |
| 8 | 138.2 | 19.3 | 0.44 s |
| 32 | **317.9** | 13.1 | 3.2 s |

DSpark (MTP) adds +52% to +80% throughput from 4 concurrent requests up, and costs ~7% for a single user.
Cold start takes about 5 minutes.

## Tuning

Everything is in `.env`. After changing it, run `scripts/up.sh`, which restarts the container.

| Variable | Default | Notes |
|---|---|---|
| `BIND_ADDRESS` / `PORT` | `127.0.0.1` / `8000` | Where the proxy listens. Localhost by default, which is also right behind a tunnel on this box. Set `0.0.0.0` for a gateway on the LAN; Docker-published ports **bypass ufw**, so the keys are then the gate |
| `PROXY_RATE_PER_KEY` / `PROXY_BURST_PER_KEY` | `20r/s` / `40` | Per-key request rate |
| `PROXY_MAX_CONCURRENT_PER_KEY` | `64` | Per-key requests in flight (vLLM runs 32 at once and queues the rest) |
| `PROXY_RATE_PER_IP` | `30r/s` | Per-IP rate; also throttles key guessing |
| `PROXY_MAX_BODY` / `PROXY_READ_TIMEOUT` | `32m` / `3600s` | Request size cap (images count) and longest generation |
| `GPU_MEMORY_UTILIZATION` | `0.75` | Share of the 128 GB unified memory. The box is shared and a unified-memory OOM can hang it, so leave headroom |
| `MAX_NUM_SEQS` | `32` | Concurrent sequences; aggregate throughput still climbs at 32 |
| `MAX_MODEL_LEN` | `262144` | Official Spark cap; 1M is possible with a bigger KV budget, but prefill at that size is very slow |
| `MAX_NUM_BATCHED_TOKENS` | `8192` | Prefill chunk size. Use 2048 if a newer image hits the sm_121 shared-memory crash |
| `SPEC_DECODE` | `dspark` | `off` disables speculative decoding. DSpark helps code and concurrency; it is neutral on chat |
| `KV_CACHE_DTYPE` | `auto` (BF16) | `fp8` holds ~1.45x more tokens at a small quality cost |
| `EXTRA_ARGS` | empty | Any other `vllm serve` flags |

## Operations

```bash
scripts/keys.sh list                           # who has access (add / rotate / revoke NAME)
docker logs -f inkling-2-mini                  # vLLM logs
docker logs -f inkling-proxy                   # access log: client name, path, status, latency (never keys)
docker stats --no-stream inkling-2-mini        # memory / CPU
docker exec inkling-2-mini curl -s localhost:8000/metrics | grep -E '^vllm:(num_requests|kv_cache_usage|spec_decode)'
scripts/bench.sh --concurrency 1,8,32          # benchmark (results/ is git-ignored)
scripts/down.sh                                # stop (model, caches and keys are kept)
```

Prometheus metrics are deliberately not exposed through the proxy. Read them with `docker exec`, as above.

**Updating:** pull a newer image, put its digest in `VLLM_IMAGE`, and set `MODEL_REVISION` if the weights
changed (then run `scripts/download-model.sh`). Then `scripts/up.sh`, `scripts/smoke-test.sh` and `scripts/bench.sh`.
Once Inkling support lands in a vLLM release, move to a release tag.

**Troubleshooting**

- *"Free memory on device ... is less than desired GPU memory utilization"*: other processes are using memory
  (this build already counts page cache as free on GB10). Lower `GPU_MEMORY_UTILIZATION` or stop other jobs.
- *Crash in a MoE/router kernel mentioning shared memory*: set `MAX_NUM_BATCHED_TOKENS=2048`.
- *Empty `content`*: thinking used up `max_tokens`. Raise `max_tokens` or lower `reasoning_effort`.
- *Slow first start*: torch.compile and CUDA graph capture run for both the model and the drafter. The compile
  cache in `~/.cache/inkling/vllm` makes later starts faster.

## Layout

```
compose.yaml                 vllm (GPU, internal network only) + proxy (published port), healthchecks, restart policy
.env.example                 every tunable, with the reasoning behind each default
docker/serve.sh              vLLM entrypoint: .env -> vllm serve flags; refuses to start without its key
nginx/default.conf.template  proxy: key check, allowlist, limits, SSE passthrough, JSON errors
scripts/up.sh, down.sh       start/restart (creates secrets, memory preflight), and stop
scripts/keys.sh              per-client API keys: add, rotate, revoke, list, show (each change verified live)
scripts/funnel.sh            Tailscale Funnel: sign-in link, status, public URL
tailscale/serve.json         Funnel config: HTTPS :443 on the ts.net name -> nginx on 127.0.0.1:8080
scripts/download-model.sh    pinned model download (runs as your uid, so the cache is yours)
scripts/smoke-test.sh        security and functional checks of the OpenAI API surface
scripts/bench.sh             concurrency sweep with realistic prompts
docs/                        engine selection, security model, benchmark results
```

Secrets live in `~/.config/inkling` (mode 700), never in the repo: `internal-key`, `nginx/clients.map`, `nginx/upstream-auth.conf`.
