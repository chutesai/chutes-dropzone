#!/usr/bin/env bash
#
# Post-startup OpenWebUI verification helper.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

compose() {
    local files="${CHUTES_COMPOSE_FILES:-$PROJECT_DIR/docker-compose.yml}"
    local file
    local old_ifs="$IFS"
    local -a args=()

    IFS=':' read -r -a compose_files <<< "$files"
    IFS="$old_ifs"

    for file in "${compose_files[@]}"; do
        if [[ "$file" != /* ]]; then
            file="$PROJECT_DIR/$file"
        fi
        args+=(-f "$file")
    done

    docker compose "${args[@]}" "$@"
}

wait_for_openwebui() {
    local attempts="${1:-60}"
    while [ "$attempts" -gt 0 ]; do
        if compose exec -T openwebui python -c \
            "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5).read()" \
            >/dev/null 2>&1; then
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 2
    done
    return 1
}

configure_openwebui_runtime() {
    # shellcheck disable=SC2016
    compose exec -T openwebui sh -lc \
        'cd /app/backend && PYTHONPATH="/app/backend${PYTHONPATH:+:${PYTHONPATH}}" python /opt/dropzone/openwebui-model-order-sync.py --configure-openai-auth'
}

promote_pending_oauth_users() {
    local promoted=""
    promoted="$(
        compose exec -T postgres psql \
            -U "${POSTGRES_OPENWEBUI_USER:-${POSTGRES_USER:-dropzone}}" \
            -d "${POSTGRES_OPENWEBUI_DB:-openwebui}" \
            -Atqc "WITH promoted AS (
                        UPDATE \"user\"
                           SET role = 'user'
                         WHERE role = 'pending'
                           AND oauth IS NOT NULL
                     RETURNING id
                    )
                    SELECT count(*) FROM promoted;" 2>/dev/null || true
    )"

    promoted="${promoted//[[:space:]]/}"
    if [ -z "$promoted" ]; then
        promoted="0"
    fi

    printf '%s' "$promoted"
}

assert_openwebui_env() {
    # shellcheck disable=SC2016
    compose exec -T openwebui sh -lc '
        case "${WEBUI_URL:-}" in
            https://*/chat) ;;
            *) exit 1 ;;
        esac
        case "${OPENID_REDIRECT_URI:-}" in
            https://*/oauth/oidc/callback|https://*/chat/oauth/oidc/callback) ;;
            *) exit 1 ;;
        esac
        test "${OAUTH_SCOPES:-}" = "openid profile chutes:read chutes:invoke" &&
        test "${OAUTH_USERNAME_CLAIM:-}" = "username" &&
        test "${ENABLE_PERSISTENT_CONFIG:-}" = "false" &&
        test "${ENABLE_OAUTH_PERSISTENT_CONFIG:-}" = "false" &&
        test "${ENABLE_OAUTH_SIGNUP:-}" = "true" &&
        test "${DEFAULT_USER_ROLE:-}" = "user" &&
        test "${BYPASS_MODEL_ACCESS_CONTROL:-}" = "true" &&
        test "${ENABLE_OAUTH_EMAIL_FALLBACK:-}" = "true" &&
        test "${ENABLE_LOGIN_FORM:-}" = "false" &&
        test "${ENABLE_PASSWORD_AUTH:-}" = "false" &&
        test "${ENABLE_OLLAMA_API:-}" = "false" &&
        test "${ENABLE_EVALUATION_ARENA_MODELS:-}" = "false" &&
        test "${MODELS_CACHE_TTL:-}" = "300"
    '
}

assert_openwebui_runtime_config() {
    compose exec -T openwebui python - <<'PY'
import json
import os
import urllib.request
from datetime import timedelta

from open_webui.internal.db import get_db
from open_webui.models.users import Users
from open_webui.utils.auth import create_token


def request_json(path: str, token: str):
    request = urllib.request.Request(
        f"http://127.0.0.1:8080{path}",
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


admin_email = (
    os.environ.get("ADMIN_EMAIL")
    or os.environ.get("WEBUI_ADMIN_EMAIL")
    or os.environ.get("OPENWEBUI_ADMIN_EMAIL")
    or "admin@chutes.local"
)

with get_db() as db:
    admin_user = Users.get_user_by_email(admin_email, db)

if not admin_user or admin_user.role != "admin":
    raise SystemExit(f"could not locate OpenWebUI admin user for {admin_email}")

token = create_token({"id": admin_user.id}, expires_delta=timedelta(minutes=10))

openai_config = request_json("/openai/config", token)
api_urls = openai_config.get("OPENAI_API_BASE_URLS", [])
api_configs = openai_config.get("OPENAI_API_CONFIGS", {})

if not isinstance(api_configs, dict) or len(api_configs) != len(api_urls):
    raise SystemExit("OPENAI_API_CONFIGS is not populated for each backend")

for index in range(len(api_urls)):
    entry = api_configs.get(str(index), {})
    if entry.get("auth_type") != "system_oauth":
        raise SystemExit(f"backend {index} is not configured for system_oauth")

models_config = request_json("/api/v1/configs/models", token)
model_order = models_config.get("MODEL_ORDER_LIST")

if not isinstance(model_order, list) or len(model_order) == 0:
    raise SystemExit("MODEL_ORDER_LIST is empty")
PY
}

validate_openwebui_model_backend() {
    if [ "${SKIP_CHUTES_MODEL_VALIDATION:-false}" = "true" ]; then
        echo "  Skipping OpenWebUI model backend validation"
        return 0
    fi

    local validation_output=""
    local strict_tee_proxy_mode="false"

    if [ "${CHUTES_TRAFFIC_MODE:-direct}" = "e2ee-proxy" ] && [ "${ALLOW_NON_CONFIDENTIAL:-false}" != "true" ]; then
        strict_tee_proxy_mode="true"
    fi

    if ! validation_output="$(
        compose exec -T -e DROPZONE_STRICT_TEE_PROXY_MODE="$strict_tee_proxy_mode" openwebui python - <<'PY' 2>&1
import json
import os
import sys
import urllib.error
import urllib.request

urls = [url.strip() for url in os.environ.get("OPENAI_API_BASE_URLS", "").split(";") if url.strip()]
keys = [key.strip() for key in os.environ.get("OPENAI_API_KEYS", "").split(";")]

if not urls:
    print("no OpenAI-compatible model backend URL is configured")
    raise SystemExit(1)

for index, url in enumerate(urls):
    key = keys[index] if index < len(keys) else ""
    headers = {"Accept": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"

    request = urllib.request.Request(f"{url.rstrip('/')}/models", headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            response_headers = response.headers
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace").strip()
        print(f"{url}/models returned HTTP {exc.code}")
        if body:
            print(body[:400])
        if key:
            print("the configured OpenWebUI API key was rejected; leave OPENWEBUI_API_KEY empty for public Chutes endpoints")
        raise SystemExit(1)
    except Exception as exc:
        print(f"{url}/models request failed: {exc}")
        raise SystemExit(1)

    data = payload.get("data", []) if isinstance(payload, dict) else []
    if not isinstance(data, list) or len(data) == 0:
        print(f"{url}/models returned no models")
        raise SystemExit(1)

    strict_tee_proxy_mode = os.environ.get("DROPZONE_STRICT_TEE_PROXY_MODE", "false") == "true"
    if strict_tee_proxy_mode:
        proxy_header = response_headers.get("X-Dropzone-Proxy", "")
        tee_header = response_headers.get("X-Dropzone-Model-Catalog", "")
        if proxy_header != "e2ee-proxy":
            print(f"{url}/models did not return the expected proxy header")
            raise SystemExit(1)
        if tee_header != "tee-only":
            print(f"{url}/models did not advertise tee-only filtering")
            raise SystemExit(1)
        if any(model.get("confidential_compute") is not True for model in data):
            print(f"{url}/models returned a non-TEE model while strict tee-only proxy mode is enabled")
            raise SystemExit(1)

    print(f"{url}/models returned {len(data)} models")
PY
    )"; then
        echo "  ERROR: OpenWebUI model backend validation failed" >&2
        while IFS= read -r line; do
            [ -n "$line" ] && echo "    $line" >&2
        done <<< "$validation_output"
        echo "  Check OPENWEBUI_API_BASE_URL and OPENWEBUI_API_KEY in the deploy environment." >&2
        exit 1
    fi

    while IFS= read -r line; do
        [ -n "$line" ] && echo "  $line"
    done <<< "$validation_output"
}

landing_page_links() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path

html = Path(sys.argv[1]).read_text(encoding="utf-8")
required = ["/chat/", "/n8n/"]
missing = [item for item in required if item not in html]
if missing:
    raise SystemExit(f"missing landing links: {', '.join(missing)}")
PY
}

echo "  Waiting for OpenWebUI to be healthy ..."
if ! wait_for_openwebui 60; then
    echo "  ERROR: OpenWebUI did not become healthy" >&2
    exit 1
fi
echo "  OpenWebUI is healthy"

promoted_users="$(promote_pending_oauth_users)"
if [ "$promoted_users" -gt 0 ] 2>/dev/null; then
    echo "  Promoted ${promoted_users} pending OpenWebUI OAuth user(s) to role=user"
fi

runtime_output="$(configure_openwebui_runtime)"
while IFS= read -r line; do
    [ -n "$line" ] && echo "  $line"
done <<< "$runtime_output"

if ! assert_openwebui_env >/dev/null 2>&1; then
    echo "  ERROR: OpenWebUI runtime env does not match the /chat SSO-only configuration" >&2
    exit 1
fi
echo "  OpenWebUI runtime env is pinned to /chat and SSO-only mode"

if ! assert_openwebui_runtime_config >/dev/null 2>&1; then
    echo "  ERROR: OpenWebUI runtime config is missing system_oauth or model ordering" >&2
    exit 1
fi
echo "  OpenWebUI runtime config uses system_oauth and a seeded model order"

validate_openwebui_model_backend

# shellcheck disable=SC2016
if ! compose exec -T openwebui-order-sync sh -lc '
    test "${OPENWEBUI_SYNC_BASE_URL:-}" = "http://openwebui:8080" &&
    test "${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-}" = "300"
' >/dev/null 2>&1; then
    echo "  ERROR: OpenWebUI background model-order sync worker is missing the expected configuration" >&2
    exit 1
fi
echo "  OpenWebUI background model-order sync is configured for 5-minute refreshes"

if ! landing_page_links "$PROJECT_DIR/landing/index.html" >/dev/null 2>&1; then
    echo "  ERROR: landing page is missing the /chat or /n8n launcher links" >&2
    exit 1
fi
echo "  Landing page launcher links are present"
