#!/usr/bin/env bash
# Run scripts/bench.py through the proxy with the local "ops" client key. Results go to results/.
# Extra args pass through, e.g. scripts/bench.sh --concurrency 1,8,32 --workload code --label dspark
# Keep the top concurrency at or below PROXY_MAX_CONCURRENT_PER_KEY, or the proxy answers 429.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
INKLING_API_KEY="$("$REPO_ROOT/scripts/keys.sh" show ops)" || die "no 'ops' client key; run scripts/up.sh first"
export INKLING_API_KEY
exec python3 -I "$REPO_ROOT/scripts/bench.py" --base-url "$(local_base_url)" --model "$SERVED_MODEL_NAME" "$@"
