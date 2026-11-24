#!/usr/bin/env bash
# Download the pinned model revision into HF_HOME_DIR, owned by you (runs the container as your uid).
# Re-running is cheap: files already present are skipped.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_docker "$@"
load_env

mkdir -p "$HF_HOME_DIR"
log "downloading $MODEL_ID@$MODEL_REVISION into $HF_HOME_DIR (~20 GB)"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp -e HF_HOME=/hf -e MODEL_ID -e MODEL_REVISION \
  -v "$HF_HOME_DIR:/hf" \
  --entrypoint python3 "$VLLM_IMAGE" -c '
import os
from huggingface_hub import snapshot_download
print(snapshot_download(os.environ["MODEL_ID"], revision=os.environ["MODEL_REVISION"]))
'

snap="$(snapshot_dir)"
for f in config.json chat_template.jinja model-00001-of-00001.safetensors mtp.safetensors; do
  [[ -e "$snap/$f" ]] || die "download incomplete: $snap/$f missing"
done
log "ok: $(du -shL "$snap" | cut -f1) at $snap"
