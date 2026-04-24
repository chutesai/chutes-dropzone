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

if [ "${DROPZONE_ENABLE_OPENWEBUI:-true}" = "false" ]; then
    echo "  OpenWebUI is disabled; skipping OpenWebUI verification"
    exit 0
fi

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

converge_openwebui_runtime_config() {
    local attempt=1
    local max_attempts="${1:-5}"
    local runtime_output=""
    local runtime_config_output=""

    while [ "$attempt" -le "$max_attempts" ]; do
        runtime_output="$(configure_openwebui_runtime)"
        while IFS= read -r line; do
            [ -n "$line" ] && echo "  $line"
        done <<< "$runtime_output"

        if runtime_config_output="$(assert_openwebui_runtime_config 2>&1)"; then
            echo "  OpenWebUI runtime config uses system_oauth and a seeded model order"
            return 0
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "  OpenWebUI runtime config is still converging (attempt ${attempt}/${max_attempts})"
            while IFS= read -r line; do
                [ -n "$line" ] && echo "    $line"
            done <<< "$runtime_config_output"
            sleep 2
        else
            echo "  ERROR: OpenWebUI runtime config did not converge after ${max_attempts} attempt(s)" >&2
            while IFS= read -r line; do
                [ -n "$line" ] && echo "    $line" >&2
            done <<< "$runtime_config_output"
            return 1
        fi

        attempt=$((attempt + 1))
    done

    return 1
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


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def env_int(name: str, default: int | None) -> int | None:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw.strip())
    except ValueError:
        return default


def env_list(name: str, default: list[str] | None = None) -> list[str]:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return list(default or [])
    raw = raw.strip()
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, list):
            return [str(item).strip() for item in parsed if str(item).strip()]
    except json.JSONDecodeError:
        pass
    return [item.strip() for item in raw.split(",") if item.strip()]


def expected_web_config() -> dict:
    web_search_engine = (os.environ.get("WEB_SEARCH_ENGINE") or "").strip()
    searxng_query_url = (os.environ.get("SEARXNG_QUERY_URL") or "").strip()
    if not web_search_engine:
        web_search_engine = "searxng" if searxng_query_url else "duckduckgo"

    return {
        "ENABLE_WEB_SEARCH": env_bool("ENABLE_WEB_SEARCH", True),
        "WEB_SEARCH_ENGINE": web_search_engine,
        "WEB_SEARCH_RESULT_COUNT": env_int("WEB_SEARCH_RESULT_COUNT", 5),
        "WEB_SEARCH_CONCURRENT_REQUESTS": env_int("WEB_SEARCH_CONCURRENT_REQUESTS", 2),
        "SEARXNG_QUERY_URL": searxng_query_url,
        "WEB_SEARCH_DOMAIN_FILTER_LIST": env_list("WEB_SEARCH_DOMAIN_FILTER_LIST", []),
        "WEB_SEARCH_TRUST_ENV": env_bool("WEB_SEARCH_TRUST_ENV", False),
        "WEB_FETCH_MAX_CONTENT_LENGTH": env_int("WEB_FETCH_MAX_CONTENT_LENGTH", 50000),
        "WEB_LOADER_ENGINE": (os.environ.get("WEB_LOADER_ENGINE") or "safe_web").strip() or "safe_web",
        "WEB_LOADER_CONCURRENT_REQUESTS": env_int("WEB_LOADER_CONCURRENT_REQUESTS", 4),
        "WEB_LOADER_TIMEOUT": (os.environ.get("WEB_LOADER_TIMEOUT") or "20").strip() or "20",
        "ENABLE_WEB_LOADER_SSL_VERIFICATION": env_bool("ENABLE_WEB_LOADER_SSL_VERIFICATION", True),
        "BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL": env_bool(
            "BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL", False
        ),
        "BYPASS_WEB_SEARCH_WEB_LOADER": env_bool("BYPASS_WEB_SEARCH_WEB_LOADER", False),
        "DDGS_BACKEND": (os.environ.get("DDGS_BACKEND") or "duckduckgo").strip() or "duckduckgo",
    }


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

retrieval_config = request_json("/api/v1/retrieval/config", token)
web_config = retrieval_config.get("web", {}) if isinstance(retrieval_config, dict) else {}
if not isinstance(web_config, dict):
    raise SystemExit("web search config is unavailable")

for key, expected in expected_web_config().items():
    current = web_config.get(key)
    if isinstance(expected, list):
        current = current if isinstance(current, list) else []
    if current != expected:
        raise SystemExit(
            f"web search config mismatch for {key}: expected {expected!r} got {current!r}"
        )

audio_config = request_json("/api/v1/audio/config", token)
stt_config = audio_config.get("stt", {}) if isinstance(audio_config, dict) else {}
desired_mode = (os.environ.get("DROPZONE_AUDIO_STT_ENGINE") or "local").strip().lower()
if desired_mode not in {"local", "web", "openai"}:
    desired_mode = "local"

expected_engine = "" if desired_mode == "local" else desired_mode
expected_whisper_model = (
    os.environ.get("DROPZONE_AUDIO_STT_LOCAL_MODEL")
    or os.environ.get("WHISPER_MODEL")
    or "base"
).strip() or "base"

if stt_config.get("ENGINE", "") != expected_engine:
    raise SystemExit(
        f"audio STT engine mismatch: expected {expected_engine or 'local'} got {stt_config.get('ENGINE', '') or 'local'}"
    )

if stt_config.get("WHISPER_MODEL", "") != expected_whisper_model:
    raise SystemExit(
        f"audio Whisper model mismatch: expected {expected_whisper_model} got {stt_config.get('WHISPER_MODEL', '')}"
    )

if desired_mode == "openai":
    expected_remote_model = (os.environ.get("AUDIO_STT_MODEL") or "whisper-large-v3").strip()
    if stt_config.get("MODEL", "") != expected_remote_model:
        raise SystemExit(
            f"audio remote STT model mismatch: expected {expected_remote_model} got {stt_config.get('MODEL', '')}"
        )

default_image_prompt_template = (
    'You turn recent chat context and the selected image model into one high-quality image request. '
    "A system note in the chat history may tell you which image model is selected and which parameters are already set. "
    "Infer the user's intended subject, setting, composition, lighting, perspective, medium, materials, color palette, "
    "mood, and any explicit constraints from the conversation. If the request is brief, add sensible visual detail "
    "without changing the core idea. Stay faithful to what the user wants, do not invent named entities or unsafe "
    "details they did not request. You may optionally suggest a negative prompt, image size, and step count when that "
    "would materially improve the result; otherwise omit them. Prefer conservative step counts for fast FLUX or schnell "
    'style models unless the user explicitly asks for a slower, higher-detail render. Output strict JSON only using '
    'only keys you are setting: {"prompt":"...","negative_prompt":"...","size":"1024x1024","steps":6,"rationale":"..."}. '
    "Chat history: <chat_history>{{MESSAGES:END:8}}</chat_history>"
)

image_config = request_json("/api/v1/images/config", token)
if not isinstance(image_config, dict):
    raise SystemExit("image generation config is unavailable")

expected_image_enabled = (os.environ.get("ENABLE_IMAGE_GENERATION") or "true").strip().lower() == "true"
expected_image_prompt_enabled = (
    os.environ.get("ENABLE_IMAGE_PROMPT_GENERATION") or "true"
).strip().lower() == "true"
expected_image_engine = (os.environ.get("IMAGE_GENERATION_ENGINE") or "openai").strip() or "openai"
expected_image_model = (
    os.environ.get("IMAGE_GENERATION_MODEL") or "chutes-auto-image"
).strip() or "chutes-auto-image"
expected_image_base_url = (os.environ.get("IMAGES_OPENAI_API_BASE_URL") or "").strip()
if not expected_image_base_url:
    traffic_mode = (os.environ.get("CHUTES_TRAFFIC_MODE") or "direct").strip().lower()
    if traffic_mode == "e2ee-proxy":
        proxy = (os.environ.get("CHUTES_PROXY_INTERNAL_URL") or "").strip().rstrip("/")
        if proxy:
            expected_image_base_url = f"{proxy}/v1"
if not expected_image_base_url:
    expected_image_base_url = (
        os.environ.get("OPENWEBUI_API_BASE_URL")
        or "https://llm.chutes.ai/v1"
    ).strip()

if bool(image_config.get("ENABLE_IMAGE_GENERATION")) != expected_image_enabled:
    raise SystemExit(
        f"image generation enabled mismatch: expected {expected_image_enabled} got {bool(image_config.get('ENABLE_IMAGE_GENERATION'))}"
    )

if bool(image_config.get("ENABLE_IMAGE_PROMPT_GENERATION")) != expected_image_prompt_enabled:
    raise SystemExit(
        f"image prompt generation mismatch: expected {expected_image_prompt_enabled} got {bool(image_config.get('ENABLE_IMAGE_PROMPT_GENERATION'))}"
    )

if image_config.get("IMAGE_GENERATION_ENGINE", "") != expected_image_engine:
    raise SystemExit(
        f"image generation engine mismatch: expected {expected_image_engine} got {image_config.get('IMAGE_GENERATION_ENGINE', '')}"
    )

if image_config.get("IMAGE_GENERATION_MODEL", "") != expected_image_model:
    raise SystemExit(
        f"image generation model mismatch: expected {expected_image_model} got {image_config.get('IMAGE_GENERATION_MODEL', '')}"
    )

if expected_image_base_url and image_config.get("IMAGES_OPENAI_API_BASE_URL", "") != expected_image_base_url:
    raise SystemExit(
        f"image generation base URL mismatch: expected {expected_image_base_url} got {image_config.get('IMAGES_OPENAI_API_BASE_URL', '')}"
    )

task_config = request_json("/api/v1/tasks/config", token)
if not isinstance(task_config, dict):
    raise SystemExit("task config is unavailable")

expected_task_model = (os.environ.get("TASK_MODEL") or "").strip()
expected_task_model_external = (os.environ.get("TASK_MODEL_EXTERNAL") or "").strip()
expected_title_generation_enabled = (
    os.environ.get("ENABLE_TITLE_GENERATION") or "true"
).strip().lower() == "true"
expected_follow_up_generation_enabled = (
    os.environ.get("ENABLE_FOLLOW_UP_GENERATION") or "true"
).strip().lower() == "true"
expected_image_prompt_template = (
    os.environ.get("IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE")
    or default_image_prompt_template
).strip() or default_image_prompt_template

if (task_config.get("TASK_MODEL") or "") != expected_task_model:
    raise SystemExit(
        f"task model mismatch: expected {expected_task_model or '<selected chat model>'} got {(task_config.get('TASK_MODEL') or '') or '<selected chat model>'}"
    )

if (task_config.get("TASK_MODEL_EXTERNAL") or "") != expected_task_model_external:
    raise SystemExit(
        f"external task model mismatch: expected {expected_task_model_external or '<selected chat model>'} got {(task_config.get('TASK_MODEL_EXTERNAL') or '') or '<selected chat model>'}"
    )

if bool(task_config.get("ENABLE_TITLE_GENERATION")) != expected_title_generation_enabled:
    raise SystemExit(
        f"title generation mismatch: expected {expected_title_generation_enabled} got {bool(task_config.get('ENABLE_TITLE_GENERATION'))}"
    )

if bool(task_config.get("ENABLE_FOLLOW_UP_GENERATION")) != expected_follow_up_generation_enabled:
    raise SystemExit(
        f"follow-up generation mismatch: expected {expected_follow_up_generation_enabled} got {bool(task_config.get('ENABLE_FOLLOW_UP_GENERATION'))}"
    )

if (task_config.get("IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE") or "") != expected_image_prompt_template:
    raise SystemExit("image prompt template mismatch")
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
    python3 - "$1" "${DROPZONE_ENABLE_N8N:-true}" <<'PY'
import sys
from pathlib import Path

html = Path(sys.argv[1]).read_text(encoding="utf-8")
n8n_enabled = sys.argv[2].lower() not in {"false", "0", "no"}
required = ["/chat/"]
if n8n_enabled:
    required.append("/n8n/")
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

if ! assert_openwebui_env >/dev/null 2>&1; then
    echo "  ERROR: OpenWebUI runtime env does not match the /chat SSO-only configuration" >&2
    exit 1
fi
echo "  OpenWebUI runtime env is pinned to /chat and SSO-only mode"

if ! converge_openwebui_runtime_config 5; then
    exit 1
fi

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
    if [ "${DROPZONE_ENABLE_N8N:-true}" = "false" ]; then
        echo "  ERROR: landing page is missing the /chat launcher link" >&2
    else
        echo "  ERROR: landing page is missing the /chat or /n8n launcher links" >&2
    fi
    exit 1
fi
echo "  Landing page launcher links are present"
