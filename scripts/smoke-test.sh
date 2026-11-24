#!/usr/bin/env bash
# Run scripts/smoke_test.py through the proxy with the local "ops" client key.
# Extra args pass through, e.g. scripts/smoke-test.sh --effort none
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_env
INKLING_API_KEY="$("$REPO_ROOT/scripts/keys.sh" show ops)" || die "no 'ops' client key; run scripts/up.sh first"
export INKLING_API_KEY
exec python3 -I "$REPO_ROOT/scripts/smoke_test.py" --base-url "$(local_base_url)" --model "$SERVED_MODEL_NAME" "$@"
