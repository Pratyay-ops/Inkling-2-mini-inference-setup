#!/usr/bin/env bash
# Start the stack, or restart it to apply .env changes.
# First run: creates .env and the secrets. Every run: memory preflight, compose up, wait for /health.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_docker "$@"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$REPO_ROOT/.env.example" "$ENV_FILE"
  log "created .env from .env.example"
fi
load_env

# --- Secrets (outside the repo, mode 600) -----------------------------------------------------
#   internal-key              vLLM's own key; only the proxy knows it
#   nginx/upstream-auth.conf  nginx include that swaps the client's key for the internal one
#   nginx/clients.map         per-client keys (scripts/keys.sh)
mkdir -p "$SECRETS_DIR/nginx"
chmod 700 "$SECRETS_DIR" "$SECRETS_DIR/nginx"
if [[ ! -s "$SECRETS_DIR/internal-key" ]]; then
  (umask 077 && openssl rand -hex 32 > "$SECRETS_DIR/internal-key")
  log "generated internal vLLM key"
fi
(umask 077 && printf 'proxy_set_header Authorization "Bearer %s";\n' "$(tr -d '[:space:]' < "$SECRETS_DIR/internal-key")" \
  > "$SECRETS_DIR/nginx/upstream-auth.conf")
if [[ ! -f "$SECRETS_DIR/nginx/clients.map" ]]; then
  (umask 077 && printf '# Per-client API keys, managed by scripts/keys.sh. Format: "Bearer <key>" <name>;\n' \
    > "$SECRETS_DIR/nginx/clients.map")
fi
# The local "ops" client is what smoke-test.sh and bench.sh use.
if ! grep -q '" ops;' "$SECRETS_DIR/nginx/clients.map"; then
  KEYS_NO_RELOAD=1 KEYS_QUIET=1 "$REPO_ROOT/scripts/keys.sh" add ops
  log "created the local 'ops' client key"
fi

snap="$(snapshot_dir)"
[[ -e "$snap/model-00001-of-00001.safetensors" ]] || die "model not found at $snap. Run scripts/download-model.sh"
mkdir -p "$VLLM_CACHE_DIR"

running=false
[[ "$(docker inspect -f '{{.State.Running}}' inkling-2-mini 2>/dev/null || true)" == "true" ]] && running=true

if $running; then
  # Compose recreates only services whose config changed (e.g. adding Funnel leaves vLLM up). If vLLM itself
  # is recreated, the old container stops first and vLLM's own startup check guards memory.
  log "stack is running; applying changes (only changed services restart)"
else
  # --- Unified-memory preflight -----------------------------------------------------------------
  # vLLM takes GPU_MEMORY_UTILIZATION x total memory and, on GB10, checks it against MemAvailable
  # (page cache counts as reclaimable). Check the same thing first, with headroom for the rest of the
  # box: a unified-memory OOM can hang GB10 until a power cycle.
  meminfo() { awk -v k="$1:" '$1 == k {print int($2 / 1048576)}' /proc/meminfo; }  # GiB
  need=$(awk -v u="$GPU_MEMORY_UTILIZATION" -v t="$(meminfo MemTotal)" 'BEGIN {print int(u * t + 0.999)}')
  headroom=6
  avail=$(meminfo MemAvailable)
  log "memory: total $(meminfo MemTotal) GiB, available ${avail} GiB; vLLM wants ${need} GiB"
  if (( avail < need + headroom )); then
    die "only ${avail} GiB available but vLLM needs ${need} GiB + ${headroom} GiB headroom. Lower GPU_MEMORY_UTILIZATION or stop other GPU jobs"
  fi
fi

log "starting $VLLM_IMAGE behind $PROXY_IMAGE"
compose up -d

# --- Wait for readiness (through the proxy, so the whole path is checked) ----------------------
url="$(local_base_url)"
deadline=$(( SECONDS + 30 * 60 ))
last_note=0
until curl -fsS -m 5 "$url/health" >/dev/null 2>&1; do
  for c in inkling-2-mini inkling-proxy; do
    state="$(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' "$c" 2>/dev/null || echo missing)"
    if [[ "$state" != running* || "$state" != *restarts=0 ]]; then
      docker logs --tail 60 "$c" 2>&1 || true
      die "$c is not healthy ($state); logs above"
    fi
  done
  (( SECONDS < deadline )) || die "not ready after 30 min; see: docker logs inkling-2-mini"
  if (( SECONDS - last_note >= 60 )); then
    last_note=$SECONDS
    log "waiting for /health ($(docker logs --tail 1 inkling-2-mini 2>&1 | cut -c1-140))"
  fi
  sleep 10
done

lan_ip="$(hostname -I | awk '{print $1}')"
log "ready after ${SECONDS}s"
cat <<EOF

  OpenAI base URL : $url/v1$( [[ "$BIND_ADDRESS" == "0.0.0.0" ]] && printf '   (LAN: http://%s:%s/v1)' "$lan_ip" "$PORT" )
  Model name      : $SERVED_MODEL_NAME
  Client keys     : scripts/keys.sh add <name>   (one per gateway/app; list, rotate, revoke)
  Smoke test      : scripts/smoke-test.sh
EOF
if [[ "${PUBLIC_ACCESS:-none}" == "tailscale-funnel" ]]; then
  echo
  "$REPO_ROOT/scripts/funnel.sh" status || true
fi
