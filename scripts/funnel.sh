#!/usr/bin/env bash
# Public HTTPS through this host's Tailscale Funnel (free Personal plan; outbound-only; TLS ends on this box).
#   scripts/funnel.sh enable    publish the proxy's Funnel listener (127.0.0.1:FUNNEL_PORT) at https://<node>.ts.net
#   scripts/funnel.sh disable   stop publishing
#   scripts/funnel.sh status    node, public URL and what Funnel is serving
#   scripts/funnel.sh url       print just the public base URL for your gateway
#
# One-time setup on the host (needs sudo once):
#   sudo tailscale login                        # sign this machine in to your tailnet
#   sudo tailscale set --hostname=inkling       # public URL becomes https://inkling.<tailnet>.ts.net
#   sudo tailscale set --operator=$USER         # lets this script manage Funnel without sudo
# The first `enable` may print a one-time link to turn on HTTPS certificates and Funnel for your tailnet.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
command -v tailscale >/dev/null || die "tailscale is not installed on this host (https://tailscale.com/download/linux)"
port="${FUNNEL_PORT:-8001}"

backend_state() { tailscale status --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' || true; }
dns_name() { tailscale status --json | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'; }
need_running() { [[ "$(backend_state)" == "Running" ]] || die "Tailscale is not signed in on this host: sudo tailscale login"; }

case "${1:-status}" in
  enable)
    need_running
    curl -s -o /dev/null -m 3 "http://127.0.0.1:$port/health" ||
      die "nothing answers on 127.0.0.1:$port; start the stack first (scripts/up.sh)"
    log "publishing http://127.0.0.1:$port at https://$(dns_name) (if asked, open the link to enable Funnel)"
    # Stream output live: on a new tailnet Tailscale prints a link to enable HTTPS + Funnel and waits for it.
    out="$(mktemp)"
    trap 'rm -f "$out"' EXIT
    if ! tailscale funnel --bg --yes "http://127.0.0.1:$port" 2>&1 | tee "$out"; then
      if grep -qiE "access denied|permission|operator" "$out"; then
        die "this user can't manage Tailscale yet. Run once: sudo tailscale set --operator=\$USER"
      fi
      die "tailscale funnel failed (output above)"
    fi
    log "public base URL: https://$(dns_name)/v1"
    ;;
  disable)
    need_running
    tailscale funnel --https=443 off
    log "Funnel off"
    ;;
  status)
    need_running
    log "node: $(dns_name)"
    log "public base URL: https://$(dns_name)/v1"
    tailscale funnel status 2>&1 | sed 's/^/  /'
    ;;
  url)
    need_running
    printf 'https://%s/v1\n' "$(dns_name)"
    ;;
  *) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
