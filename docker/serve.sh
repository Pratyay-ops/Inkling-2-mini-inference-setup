#!/usr/bin/env bash
# Container entrypoint: turns the environment set in compose.yaml into `vllm serve` flags.
# Runs inside vllm/vllm-openai:inkling-2-mini. Edit .env on the host, not this file.
set -euo pipefail

: "${MODEL_ID:?}" "${MODEL_REVISION:?}" "${SERVED_MODEL_NAME:?}"
: "${MAX_MODEL_LEN:?}" "${MAX_NUM_SEQS:?}" "${MAX_NUM_BATCHED_TOKENS:?}" "${GPU_MEMORY_UTILIZATION:?}"

if [[ ! -s /run/secrets/api_key ]]; then
  echo "serve.sh: /run/secrets/api_key is missing or empty; refusing to start without auth" >&2
  exit 1
fi
# vLLM reads VLLM_API_KEY; exporting it keeps the key out of the process argv.
VLLM_API_KEY="$(tr -d '[:space:]' < /run/secrets/api_key)"
export VLLM_API_KEY

args=(
  "$MODEL_ID"
  --revision "$MODEL_REVISION"
  --served-model-name "$SERVED_MODEL_NAME"
  --host 0.0.0.0
  --port 8000
  --tensor-parallel-size 1
  --max-model-len "$MAX_MODEL_LEN"
  --max-num-seqs "$MAX_NUM_SEQS"
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
  --enable-prefix-caching
  --reasoning-parser inkling
  --enable-auto-tool-choice
  --tool-call-parser inkling
)

case "${KV_CACHE_DTYPE:-auto}" in
  auto | bf16 | bfloat16) ;;
  fp8) args+=(--kv-cache-dtype fp8) ;;
  *) echo "serve.sh: KV_CACHE_DTYPE must be auto or fp8, got '${KV_CACHE_DTYPE}'" >&2; exit 1 ;;
esac

case "${SPEC_DECODE:-dspark}" in
  # DSpark is the model's bundled MTP drafter (mtp.safetensors). vLLM requires exactly 7 draft tokens.
  dspark) args+=(--speculative-config '{"method":"dspark","num_speculative_tokens":7,"draft_sample_method":"probabilistic"}') ;;
  off) ;;
  *) echo "serve.sh: SPEC_DECODE must be dspark or off, got '${SPEC_DECODE}'" >&2; exit 1 ;;
esac

# Idle cache release (docker/cache_reaper.py). Sleep mode lets vLLM drop its KV cache and re-reserve it on demand;
# dev mode turns on the /release_kv_cache_memory, /wake_up and /reset_*_cache endpoints. Those have no auth, but
# vLLM is reachable only on the internal network, and the proxy's allowlist never forwards them.
if [[ "${CACHE_IDLE_MINUTES:-0}" =~ ^[0-9]+$ ]] && (( CACHE_IDLE_MINUTES > 0 )); then
  args+=(--enable-sleep-mode)
  export VLLM_SERVER_DEV_MODE=1
fi

# Free-form extra flags, split on whitespace (e.g. EXTRA_ARGS="--max-log-len 200").
if [[ -n "${EXTRA_ARGS:-}" ]]; then
  read -r -a extra <<< "$EXTRA_ARGS"
  args+=("${extra[@]}")
fi

echo "serve.sh: vllm serve ${args[*]}"
exec vllm serve "${args[@]}"
