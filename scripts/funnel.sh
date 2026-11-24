#!/usr/bin/env bash
# Tailscale Funnel helper (PUBLIC_ACCESS=tailscale-funnel).
#   scripts/funnel.sh status   login state, public URL, whether Funnel is serving
#   scripts/funnel.sh login    print the sign-in link (open it in any browser, e.g. on your laptop)
#   scripts/funnel.sh url      print just the public base URL for your gateway
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_docker "$@"
load_env
[[ "${PUBLIC_ACCESS:-none}" == "tailscale-funnel" ]] || die "PUBLIC_ACCESS is not tailscale-funnel in .env"
[[ "$(docker inspect -f '{{.State.Running}}' inkling-tailscale 2>/dev/null || true)" == "true" ]] ||
  die "inkling-tailscale is not running; run scripts/up.sh"

ts() { docker exec inkling-tailscale tailscale "$@"; }
backend_state() { ts status --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))'; }
dns_name() { ts status --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'; }

case "${1:-status}" in
  login)
    if [[ "$(backend_state)" == "Running" ]]; then
      log "already signed in as node $(dns_name)"
      exit 0
    fi
    link="$(docker logs inkling-tailscale 2>&1 | grep -oE 'https://login\.tailscale\.com/a/[A-Za-z0-9]+' | tail -1 || true)"
    [[ -n "$link" ]] || die "no sign-in link in the logs yet; wait a few seconds and retry (docker logs inkling-tailscale)"
    printf 'Open this link in any browser and sign in (free Personal plan):\n  %s\n' "$link"
    ;;
  url)
    [[ "$(backend_state)" == "Running" ]] || die "not signed in yet: scripts/funnel.sh login"
    printf 'https://%s/v1\n' "$(dns_name)"
    ;;
  status)
    state="$(backend_state)"
    log "tailscale: ${state:-unknown}"
    if [[ "$state" == "Running" ]]; then
      log "public base URL: https://$(dns_name)/v1"
      ts funnel status 2>&1 | sed 's/^/  /'
    else
      log "not signed in: scripts/funnel.sh login"
    fi
    ;;
  *) sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
