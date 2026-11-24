#!/usr/bin/env bash
# Manage per-client API keys for the nginx proxy. Changes apply immediately (nginx reload, no restart).
#
#   scripts/keys.sh add NAME      create a key for a client and print it (one key per gateway/app/person)
#   scripts/keys.sh rotate NAME   replace a client's key and print the new one
#   scripts/keys.sh revoke NAME   delete a client's key
#   scripts/keys.sh list          client names, creation times and key fingerprints (no keys)
#   scripts/keys.sh show NAME     print a client's key
#
# Keys are 256-bit random, prefixed "sk-inkling-" so secret scanners can spot leaks. They live in
# SECRETS_DIR/nginx/clients.map (mode 600), which nginx needs in plaintext to compare against.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
cmd="${1:-}"
name="${2:-}"
[[ -n "$cmd" ]] || usage
case "$cmd" in add | rotate | revoke) ensure_docker "$@" ;; esac
load_env

map="$SECRETS_DIR/nginx/clients.map"
[[ -f "$map" ]] || die "$map not found. Run scripts/up.sh once to create it"

need_name() {
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]] || die "NAME must be 1-32 chars of a-z, 0-9, _ or - (got '$name')"
}
has_client() { grep -qE "^\"Bearer sk-inkling-[0-9a-f]{64}\" $1;" "$map"; }
key_of() { sed -nE "s/^\"Bearer (sk-inkling-[0-9a-f]{64})\" $1;.*/\1/p" "$map"; }

# Write the map atomically (temp file + rename in the same directory nginx has mounted).
rewrite_map() {
  local tmp
  tmp="$(mktemp "$map.XXXXXX")"
  chmod 600 "$tmp"
  cat > "$tmp"
  mv -f "$tmp" "$map"
}

# Reload nginx, then confirm through the proxy that each KEY now gets its EXPECTED result: "ok" (auth passes:
# 200, or 503 while vLLM is starting) or "denied" (401). `nginx -s reload` only sends a signal and new workers
# take a moment, so without this check a revoked key could briefly keep working.
# Usage: reload_proxy KEY EXPECTED [KEY EXPECTED ...]
reload_proxy() {
  [[ -n "${KEYS_NO_RELOAD:-}" ]] && return 0
  if [[ "$(docker inspect -f '{{.State.Running}}' inkling-proxy 2>/dev/null || true)" != "true" ]]; then
    log "proxy not running; the change applies on next scripts/up.sh"
    return 0
  fi
  docker exec inkling-proxy nginx -t -q
  docker exec inkling-proxy nginx -s reload 2>/dev/null
  local key expected code i
  while (( $# >= 2 )); do
    key="$1" expected="$2"
    shift 2
    for i in $(seq 50); do
      code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' -H "Authorization: Bearer $key" "$(local_base_url)/v1/models" || true)"
      case "$expected:$code" in ok:200 | ok:503 | denied:401) break ;; esac
      sleep 0.1
    done
    case "$expected:$code" in
      ok:200 | ok:503 | denied:401) ;;
      *) die "proxy reloaded but a key that should be $expected gets HTTP $code; check: docker logs inkling-proxy" ;;
    esac
  done
  log "proxy reloaded; verified through the proxy"
}

new_line() {
  printf '"Bearer sk-inkling-%s" %s; # created %s\n' "$(openssl rand -hex 32)" "$name" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}

case "$cmd" in
  add)
    need_name
    has_client "$name" && die "client '$name' already exists (use rotate to replace its key)"
    { cat "$map"; new_line; } | rewrite_map
    reload_proxy "$(key_of "$name")" ok
    [[ -n "${KEYS_QUIET:-}" ]] || printf 'API key for %s (shown once here; `keys.sh show %s` prints it again):\n%s\n' "$name" "$name" "$(key_of "$name")"
    ;;
  rotate)
    need_name
    has_client "$name" || die "no client named '$name'"
    old_key="$(key_of "$name")"
    { grep -vE "^\"Bearer sk-inkling-[0-9a-f]{64}\" $name;" "$map" || true; new_line; } | rewrite_map
    reload_proxy "$old_key" denied "$(key_of "$name")" ok
    printf 'new API key for %s (the old one stopped working):\n%s\n' "$name" "$(key_of "$name")"
    ;;
  revoke)
    need_name
    has_client "$name" || die "no client named '$name'"
    old_key="$(key_of "$name")"
    { grep -vE "^\"Bearer sk-inkling-[0-9a-f]{64}\" $name;" "$map" || true; } | rewrite_map
    reload_proxy "$old_key" denied
    log "revoked '$name'"
    ;;
  list)
    printf '%-24s %-22s %s\n' CLIENT CREATED FINGERPRINT
    sed -nE 's/^"Bearer (sk-inkling-[0-9a-f]{64})" ([a-z0-9_-]+); # created (.*)$/\2 \3 \1/p' "$map" |
      while read -r n created key; do
        printf '%-24s %-22s %s\n' "$n" "$created" "$(printf '%s' "$key" | sha256sum | cut -c1-12)"
      done
    ;;
  show)
    need_name
    has_client "$name" || die "no client named '$name'"
    key_of "$name"
    ;;
  *) usage ;;
esac
