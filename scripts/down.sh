#!/usr/bin/env bash
# Stop and remove the server container. It will not come back on reboot until scripts/up.sh runs again.
# Model weights and the compile cache are kept.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_docker "$@"
load_env
compose down
log "stopped"
