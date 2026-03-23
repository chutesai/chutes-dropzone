#!/usr/bin/env bash
#
# Periodically reseed OpenWebUI runtime model ordering so new Chutes models
# adopt the desired TEE-first newest-first order without a redeploy.
#
set -euo pipefail

SYNC_BASE_URL="${OPENWEBUI_SYNC_BASE_URL:-http://127.0.0.1:8080}"
SYNC_INTERVAL="${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-300}"
SYNC_SCRIPT="${OPENWEBUI_MODEL_ORDER_SYNC_SCRIPT:-/opt/dropzone/openwebui-model-order-sync.py}"
APP_DIR="${OPENWEBUI_APP_DIR:-/app/backend}"

export PYTHONPATH="${APP_DIR}${PYTHONPATH:+:${PYTHONPATH}}"

wait_for_openwebui() {
    local attempts="${1:-60}"
    while [ "$attempts" -gt 0 ]; do
        if OPENWEBUI_SYNC_BASE_URL="$SYNC_BASE_URL" python - <<'PY' >/dev/null 2>&1
import os
import urllib.request

urllib.request.urlopen(os.environ["OPENWEBUI_SYNC_BASE_URL"].rstrip("/") + "/", timeout=5).read()
PY
        then
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 2
    done
    return 1
}

case "$SYNC_INTERVAL" in
    ''|*[!0-9]*)
        echo "openwebui-order-sync: OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL must be a non-negative integer" >&2
        exit 1
        ;;
esac

if [ "$SYNC_INTERVAL" -eq 0 ]; then
    echo "openwebui-order-sync: disabled (interval 0)"
    exec sleep infinity
fi

echo "openwebui-order-sync: starting with ${SYNC_INTERVAL}s interval"

if ! wait_for_openwebui 120; then
    echo "openwebui-order-sync: OpenWebUI was not healthy before the first sync; continuing with background retries" >&2
fi

while true; do
    if wait_for_openwebui 30; then
        if ! (
            cd "$APP_DIR" &&
            OPENWEBUI_SYNC_BASE_URL="$SYNC_BASE_URL" \
                python "$SYNC_SCRIPT" --configure-openai-auth --quiet-no-change
        ); then
            echo "openwebui-order-sync: sync failed" >&2
        fi
    else
        echo "openwebui-order-sync: OpenWebUI health check failed; retrying after ${SYNC_INTERVAL}s" >&2
    fi
    sleep "$SYNC_INTERVAL"
done
