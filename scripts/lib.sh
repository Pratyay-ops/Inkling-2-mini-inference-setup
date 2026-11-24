# Shared helpers, sourced by the other scripts. Not executable on its own.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Re-exec the calling script under `sg docker` when the user is in the docker group but this
# login session predates that (common on code-tunnel/SSH sessions started before `usermod -aG`).
# Usage: ensure_docker "$@"   (pass the script's own arguments)
ensure_docker() {
  docker info >/dev/null 2>&1 && return 0
  local me
  me="$(id -un)"
  if [[ -z "${INKLING_UNDER_SG:-}" ]] && getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$me"; then
    export INKLING_UNDER_SG=1
    exec sg docker -c "$(printf '%q ' "$0" "$@")"
  fi
  die "cannot reach the Docker daemon as $me. Run: sudo usermod -aG docker $me, then log in again"
}

# Load .env into the environment (it is also what compose interpolates).
load_env() {
  [[ -f "$ENV_FILE" ]] || die "$ENV_FILE not found. Run scripts/up.sh once, or: cp .env.example .env"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

compose() {
  local profiles=()
  case "${PUBLIC_ACCESS:-none}" in
    none) ;;
    tailscale-funnel) profiles=(--profile funnel) ;;
    *) die "PUBLIC_ACCESS must be none or tailscale-funnel, got '${PUBLIC_ACCESS}'" ;;
  esac
  docker compose --project-directory "$REPO_ROOT" --env-file "$ENV_FILE" "${profiles[@]}" "$@"
}

# URL the host can use to reach the API (0.0.0.0 is not connectable).
local_base_url() {
  local host="${BIND_ADDRESS:-127.0.0.1}"
  [[ "$host" == "0.0.0.0" ]] && host=127.0.0.1
  printf 'http://%s:%s' "$host" "${PORT:-8000}"
}

snapshot_dir() {
  printf '%s/hub/models--%s/snapshots/%s' "$HF_HOME_DIR" "${MODEL_ID//\//--}" "$MODEL_REVISION"
}
