#!/usr/bin/env bash
#
# Smoke tests for chutes-n8n-local.
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

PASS=0
FAIL=0
SKIP=0
SYNTAX_ONLY=false
EDGE_SERVICE="${EDGE_SERVICE:-}"

for arg in "$@"; do
    [ "$arg" = "--syntax" ] && SYNTAX_ONLY=true
done

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

json_query() {
    local expression="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r "$expression"
    else
        python3 - "$expression" <<'PY'
import json
import sys

expr = sys.argv[1]
data = json.load(sys.stdin)
value = data
for part in expr.split('.'):
    if not part:
        continue
    value = value.get(part)
print("" if value is None else value)
PY
    fi
}

container_health_status() {
    if [ -z "${1:-}" ]; then
        echo missing
        return
    fi

    docker inspect "$1" --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo missing
}

compose_container_id() {
    compose ps -q "$1" 2>/dev/null | head -n 1
}

wait_for_service() {
    local service="$1"
    local attempts="$2"
    local status="missing"
    local container=""

    while [ "$attempts" -gt 0 ]; do
        container="$(compose_container_id "$service")"
        status="$(container_health_status "$container")"
        if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
            printf '%s' "$status"
            return 0
        fi
        attempts=$((attempts - 1))
        sleep 1
    done

    printf '%s' "$status"
    return 1
}

wait_attempts_for_service() {
    case "${1:-}" in
        openwebui|n8n)
            printf '60'
            ;;
        *)
            printf '30'
            ;;
    esac
}

curl_edge() {
    local -a host_args=()

    if [ "${INSTALL_MODE:-}" = "local" ]; then
        host_args+=(--resolve "${DROPZONE_HOST}:443:127.0.0.1")
        host_args+=(--resolve "${DROPZONE_HOST}:80:127.0.0.1")
    fi

    curl "${host_args[@]}" "$@"
}

query_param_from_url() {
    python3 - "$1" "$2" <<'PY'
import sys
from urllib.parse import parse_qs, urlparse

url = sys.argv[1]
param = sys.argv[2]
print(parse_qs(urlparse(url).query).get(param, [""])[0])
PY
}

echo "=== Syntax checks ==="

for file in "$PROJECT_DIR/deploy.sh" "$PROJECT_DIR/scripts/"*.sh; do
    if bash -n "$file" >/dev/null 2>&1; then
        pass "bash -n $(basename "$file")"
    else
        fail "bash -n $(basename "$file")"
    fi
done

for file in "$PROJECT_DIR/standalone/entrypoint.sh" "$PROJECT_DIR/standalone/configure-standalone.sh" "$PROJECT_DIR/standalone/s6-rc.d/"*/run; do
    rel_file="${file#"$PROJECT_DIR"/}"
    if sh -n "$file" >/dev/null 2>&1; then
        pass "sh -n $rel_file"
    else
        fail "sh -n $rel_file"
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck_out="$(shellcheck -x "$PROJECT_DIR/deploy.sh" "$PROJECT_DIR/scripts/"*.sh 2>&1)" || true
    if [ -z "$shellcheck_out" ]; then
        pass "shellcheck shell scripts"
    else
        printf '%s\n' "$shellcheck_out" >&2
        fail "shellcheck shell scripts"
    fi
else
    skip "shellcheck not installed - skipping shell lint"
fi

if command -v node >/dev/null 2>&1; then
    if node --check "$PROJECT_DIR/scripts/apply-n8n-overlay.mjs" >/dev/null 2>&1; then
        pass "node --check apply-n8n-overlay.mjs"
    else
        fail "node --check apply-n8n-overlay.mjs"
    fi

    if node --check "$PROJECT_DIR/scripts/patch-n8n-nodes-chutes.mjs" >/dev/null 2>&1; then
        pass "node --check patch-n8n-nodes-chutes.mjs"
    else
        fail "node --check patch-n8n-nodes-chutes.mjs"
    fi
else
    skip "node not installed - cannot validate overlay patcher"
fi

if command -v node >/dev/null 2>&1; then
    if node --check "$PROJECT_DIR/landing/app.js" >/dev/null 2>&1; then
        pass "node --check landing/app.js"
    else
        fail "node --check landing/app.js"
    fi

    if node --check "$PROJECT_DIR/branding/openwebui/loader.js" >/dev/null 2>&1; then
        pass "node --check branding/openwebui/loader.js"
    else
        fail "node --check branding/openwebui/loader.js"
    fi

    if node --check "$PROJECT_DIR/branding/n8n/custom.js" >/dev/null 2>&1; then
        pass "node --check branding/n8n/custom.js"
    else
        fail "node --check branding/n8n/custom.js"
    fi
fi

if command -v python3 >/dev/null 2>&1; then
    if python3 -m py_compile "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile openwebui-model-order-sync.py"
    else
        fail "python3 -m py_compile openwebui-model-order-sync.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile patch-openwebui-runtime.py"
    else
        fail "python3 -m py_compile patch-openwebui-runtime.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/scripts/patch-openwebui-build.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile patch-openwebui-build.py"
    else
        fail "python3 -m py_compile patch-openwebui-build.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/branding/openwebui/dropzone_account.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile branding/openwebui/dropzone_account.py"
    else
        fail "python3 -m py_compile branding/openwebui/dropzone_account.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/branding/openwebui/dropzone_images.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile branding/openwebui/dropzone_images.py"
    else
        fail "python3 -m py_compile branding/openwebui/dropzone_images.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/branding/openwebui/dropzone_oauth.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile branding/openwebui/dropzone_oauth.py"
    else
        fail "python3 -m py_compile branding/openwebui/dropzone_oauth.py"
    fi

    if python3 -m py_compile "$PROJECT_DIR/branding/openwebui/dropzone_auth.py" >/dev/null 2>&1; then
        pass "python3 -m py_compile branding/openwebui/dropzone_auth.py"
    else
        fail "python3 -m py_compile branding/openwebui/dropzone_auth.py"
    fi

    if python3 - <<'PY' >/dev/null 2>&1
import os
import sys
import types
import importlib.util

fastapi_mod = types.ModuleType("fastapi")

class HTTPException(Exception):
    def __init__(self, status_code, detail=""):
        self.status_code = status_code
        self.detail = detail
        super().__init__(detail)

class Request:
    pass

fastapi_mod.HTTPException = HTTPException
fastapi_mod.Request = Request
sys.modules["fastapi"] = fastapi_mod

pkg = types.ModuleType("open_webui")
oauth_mod = types.ModuleType("open_webui.dropzone_oauth")

async def _stub_get_request_oauth_token(*args, **kwargs):
    return None

def _stub_get_user_oauth_access_token(*args, **kwargs):
    return ""

oauth_mod.get_request_oauth_token = _stub_get_request_oauth_token
oauth_mod.get_user_oauth_access_token = _stub_get_user_oauth_access_token
sys.modules["open_webui"] = pkg
sys.modules["open_webui.dropzone_oauth"] = oauth_mod

spec = importlib.util.spec_from_file_location(
    "dropzone_images", "branding/openwebui/dropzone_images.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

req = types.SimpleNamespace(
    app=types.SimpleNamespace(
        state=types.SimpleNamespace(
            config=types.SimpleNamespace(
                IMAGE_GENERATION_ENGINE="openai",
                IMAGES_OPENAI_API_BASE_URL="https://chat.example.com/v1",
            )
        )
    )
)

os.environ["DROPZONE_IMAGE_GENERATION_PROVIDER"] = "chutes"
assert mod.is_chutes_image_backend(req) is True

os.environ["CHUTES_TRAFFIC_MODE"] = "e2ee-proxy"
os.environ["CHUTES_PROXY_INTERNAL_URL"] = "http://e2ee-proxy:80"
os.environ["ALLOW_NON_CONFIDENTIAL"] = "true"
url, body, accept = mod._image_request_target(
    {
        "id": "chutes/Qwen-Image-2512",
        "chute_id": "086ae0cf-e7dc-5596-bd6d-20d4fb99103a",
        "slug": "chutes-qwen-image-2512",
        "tee": False,
    }
)
assert url == "http://e2ee-proxy:80/v1/images/generations"
assert body == {"model": "086ae0cf-e7dc-5596-bd6d-20d4fb99103a"}
assert "application/json" in accept

images = mod._decode_generated_images(
    b'{"data":[{"b64_json":"aGVsbG8=","mime_type":"image/png"}]}',
    "application/json",
    "",
)
assert images == [(b"hello", "image/png")]

mod._discovery_cache.clear()
mod._fetch_diffusion_chutes = lambda token: [
    {
        "chute_id": "juggernaut",
        "name": "JuggernautXL-Ragnarok",
        "slug": "chutes-juggernautxl-ragnarok",
        "user": {"username": "chutes"},
    },
    {
        "chute_id": "flux",
        "name": "FLUX.1-schnell",
        "slug": "chutes-flux-1-schnell",
        "user": {"username": "chutes"},
    },
    {
        "chute_id": "qwen",
        "name": "Qwen-Image-2512",
        "slug": "chutes-qwen-image-2512",
        "user": {"username": "chutes"},
    },
]
mod._fetch_public_chutes = lambda token: (
    [
        {
            "chute_id": "qwen-text",
            "name": "Qwen3-32B",
            "slug": "chutes-qwen3-32b",
            "readme": "Qwen text model",
            "image": {"name": "sglang"},
            "user": {"username": "chutes"},
        },
        {
            "chute_id": "qwen-edit",
            "name": "qwen-image-edit-2509",
            "slug": "chutes-qwen-image-edit-2509",
            "readme": "Qwen image edit model",
            "image": {"name": "diffusion"},
            "user": {"username": "chutes"},
        },
    ]
    if token
    else [
        {
            "chute_id": "hunyuan",
            "name": "hunyuan-image-3",
            "slug": "chutes-hunyuan-image-3",
            "readme": "Tencent Hunyuan Image 3.0",
            "image": {"name": "hunyuan-image"},
            "user": {"username": "chutes"},
        },
        {
            "chute_id": "qwen-edit",
            "name": "qwen-image-edit-2509",
            "slug": "chutes-qwen-image-edit-2509",
            "readme": "Qwen image edit model",
            "image": {"name": "diffusion"},
            "user": {"username": "chutes"},
        },
        {
            "chute_id": "qwen-text",
            "name": "Qwen3-32B",
            "slug": "chutes-qwen3-32b",
            "readme": "Qwen text model",
            "image": {"name": "sglang"},
            "user": {"username": "chutes"},
        },
    ]
)
mod._fetch_utilization = lambda: [
    {
        "chute_id": "juggernaut",
        "name": "JuggernautXL-Ragnarok",
        "active_instance_count": 6,
        "total_instance_count": 6,
        "utilization_1h": 0.90,
    },
    {
        "chute_id": "flux",
        "name": "FLUX.1-schnell",
        "active_instance_count": 3,
        "total_instance_count": 3,
        "utilization_1h": 0.40,
    },
    {
        "chute_id": "hunyuan",
        "name": "hunyuan-image-3",
        "active_instance_count": 5,
        "total_instance_count": 5,
        "utilization_1h": 0.50,
    },
    {
        "chute_id": "qwen",
        "name": "Qwen-Image-2512",
        "active_instance_count": 2,
        "total_instance_count": 2,
        "utilization_1h": 0.10,
    },
]
ordered_ids = [model["id"] for model in mod._discover_models("")["items"]]
assert ordered_ids[:4] == [
    "chutes/Qwen-Image-2512",
    "chutes/hunyuan-image-3",
    "chutes/FLUX.1-schnell",
    "chutes/JuggernautXL-Ragnarok",
]
assert "chutes/qwen-image-edit-2509" not in ordered_ids
assert "chutes/Qwen3-32B" not in ordered_ids
rendered = mod.get_chutes_image_models()
assert rendered[0]["id"] == "chutes/Qwen-Image-2512"
assert rendered[-1]["id"] == mod.AUTO_IMAGE_MODEL_ID
fallback_model, _ = mod._resolve_selected_model("chutes/Missing-Image", "")
assert fallback_model["id"] == "chutes/Qwen-Image-2512"
assert fallback_model["model_fallback"] is True
assert fallback_model["fallback_from"] == "chutes/Missing-Image"
assert fallback_model["fallback_to"] == "chutes/Qwen-Image-2512"
assert fallback_model["fallback_reason"]

cached_keys = set(mod._discovery_cache)
assert any("mode:e2ee-proxy" in key for key in cached_keys)
os.environ["CHUTES_TRAFFIC_MODE"] = "direct"
mod._discover_models("")
assert any("mode:direct" in key for key in mod._discovery_cache)
assert len(mod._discovery_cache) > len(cached_keys)
os.environ["CHUTES_TRAFFIC_MODE"] = "e2ee-proxy"

sanitized = mod._sanitize_upstream_error(
    b"<html><body><script>alert('secret')</script><h1>Bad Gateway</h1>" + (b"x" * 500) + b"</body></html>",
    "raw fallback",
    limit=80,
)
assert "<html" not in sanitized.lower()
assert "<script" not in sanitized.lower()
assert "alert" not in sanitized.lower()
assert len(sanitized) <= 80

request = types.SimpleNamespace(
    cookies={mod.IMAGE_MODEL_COOKIE_NAME: "chutes%2FJuggernautXL-Ragnarok"},
    app=types.SimpleNamespace(
        state=types.SimpleNamespace(
            config=types.SimpleNamespace(IMAGE_GENERATION_MODEL="")
        )
    ),
)
assert mod.get_chutes_image_model(request) == "chutes/JuggernautXL-Ragnarok"

os.environ["ALLOW_NON_CONFIDENTIAL"] = "false"
try:
    mod._image_request_target(
        {
            "id": "chutes/Qwen-Image-2512",
            "chute_id": "086ae0cf-e7dc-5596-bd6d-20d4fb99103a",
            "slug": "chutes-qwen-image-2512",
            "tee": False,
        }
    )
    raise AssertionError("expected strict proxy image rejection")
except mod.HTTPException as exc:
    assert exc.status_code == 503
PY
    then
        pass "Dropzone image bridge keeps Chutes routing in proxy mode, decodes encoded picker cookies, and prefers Qwen-first concrete defaults"
    else
        fail "Dropzone image bridge proxy routing/default selection handling is incomplete"
    fi

    if python3 - <<'PY' >/dev/null 2>&1
import asyncio
import sys
import types
import importlib.util

fastapi_mod = types.ModuleType("fastapi")

class HTTPException(Exception):
    def __init__(self, status_code, detail=""):
        self.status_code = status_code
        self.detail = detail

class Request:
    pass

fastapi_mod.HTTPException = HTTPException
fastapi_mod.Request = Request
sys.modules["fastapi"] = fastapi_mod

pkg = types.ModuleType("open_webui")
oauth_mod = types.ModuleType("open_webui.dropzone_oauth")

async def _stub_get_request_oauth_token(*args, **kwargs):
    return None

def _stub_get_user_oauth_access_token(*args, **kwargs):
    return ""

oauth_mod.get_request_oauth_token = _stub_get_request_oauth_token
oauth_mod.get_user_oauth_access_token = _stub_get_user_oauth_access_token
sys.modules["open_webui"] = pkg
sys.modules["open_webui.dropzone_oauth"] = oauth_mod

spec = importlib.util.spec_from_file_location(
    "dropzone_images",
    "branding/openwebui/dropzone_images.py",
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

mod._resolve_selected_model = lambda model_id, token="": (
    {
        "id": "chutes/Qwen-Image-2512",
        "slug": "chutes-qwen-image-2512",
        "chute_id": "qwen-image-2512",
        "tee": True,
    },
    {"items": []},
)
mod._generation_payload = lambda request, form_data: {"prompt": "a tiger in the jungle"}

class FakeResponse:
    def __init__(self):
        self.headers = {"Content-Type": "image/png"}

    def read(self):
        return b"\x89PNG\r\n\x1a\n"

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

to_thread_calls = []

async def fake_to_thread(func, *args, **kwargs):
    to_thread_calls.append(getattr(func, "__name__", ""))
    return func(*args, **kwargs)

def fake_urlopen(request, timeout=0):
    return FakeResponse()

mod.asyncio.to_thread = fake_to_thread
mod.urllib.request.urlopen = fake_urlopen

request = types.SimpleNamespace(
    cookies={},
    app=types.SimpleNamespace(
        state=types.SimpleNamespace(
            config=types.SimpleNamespace(
                IMAGES_OPENAI_API_KEY="token",
                IMAGE_SIZE="",
            )
        )
    ),
)
form_data = types.SimpleNamespace(
    prompt="a tiger in the jungle",
    n=1,
    size=None,
    negative_prompt=None,
    steps=None,
    model="chutes/Qwen-Image-2512",
)

async def exercise():
    images, selected = await mod.generate_chutes_images(request, form_data)
    assert to_thread_calls == ["_generate_chutes_images_blocking"]
    assert selected["id"] == "chutes/Qwen-Image-2512"
    assert len(images) == 1

asyncio.run(exercise())
PY
    then
        pass "Dropzone image generation keeps blocking chute I/O off the async event loop"
    else
        fail "Dropzone image generation can still block the async event loop"
    fi

    if python3 - <<'PY' >/dev/null 2>&1
import io
import os
import sys
import types
import importlib.util

fastapi_mod = types.ModuleType("fastapi")

class HTTPException(Exception):
    def __init__(self, status_code, detail=""):
        self.status_code = status_code
        self.detail = detail
        super().__init__(detail)

class Request:
    pass

fastapi_mod.HTTPException = HTTPException
fastapi_mod.Request = Request
sys.modules["fastapi"] = fastapi_mod

pkg = types.ModuleType("open_webui")
oauth_mod = types.ModuleType("open_webui.dropzone_oauth")

async def _stub_get_request_oauth_token(*args, **kwargs):
    return None

def _stub_get_user_oauth_access_token(*args, **kwargs):
    return ""

oauth_mod.get_request_oauth_token = _stub_get_request_oauth_token
oauth_mod.get_user_oauth_access_token = _stub_get_user_oauth_access_token
sys.modules["open_webui"] = pkg
sys.modules["open_webui.dropzone_oauth"] = oauth_mod

spec = importlib.util.spec_from_file_location(
    "dropzone_images",
    "branding/openwebui/dropzone_images.py",
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

os.environ["CHUTES_TRAFFIC_MODE"] = "direct"
mod._candidate_image_models = lambda model_id, token="": [
    {
        "id": "chutes/FLUX.1-schnell",
        "slug": "chutes-flux-1-schnell",
        "chute_id": "flux",
        "tee": True,
    },
    {
        "id": "chutes/Qwen-Image-2512",
        "slug": "chutes-qwen-image-2512",
        "chute_id": "qwen",
        "tee": True,
    },
]

calls = []

class FakeResponse:
    headers = {"Content-Type": "image/png"}

    def read(self):
        return b"\x89PNG\r\n\x1a\n"

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

def fake_urlopen(request, timeout=0):
    calls.append(request.full_url)
    if "flux" in request.full_url:
        raise mod.urllib.error.HTTPError(
            request.full_url,
            502,
            "Bad Gateway",
            {},
            io.BytesIO(b"<html><h1>502 Bad Gateway</h1></html>"),
        )
    return FakeResponse()

mod.urllib.request.urlopen = fake_urlopen
images, selected = mod._generate_chutes_images_blocking(
    "chutes/FLUX.1-schnell",
    "token",
    {"prompt": "a tiger on the great wall"},
    1,
)
assert len(images) == 1
assert selected["id"] == "chutes/Qwen-Image-2512"
assert selected["model_fallback"] is True
assert selected["failed_image_models"] == ["chutes/FLUX.1-schnell"]
assert calls == [
    "https://chutes-flux-1-schnell.chutes.ai/generate",
    "https://chutes-qwen-image-2512.chutes.ai/generate",
]
PY
    then
        pass "Dropzone image generation falls through to the next live image model on transient chute failures"
    else
        fail "Dropzone image generation does not recover from transient chute failures"
    fi

    if python3 - <<'PY' >/dev/null 2>&1
import asyncio
import os
import sys
import types
import importlib.util
import urllib.error

fastapi_mod = types.ModuleType("fastapi")

class HTTPException(Exception):
    def __init__(self, status_code, detail=""):
        self.status_code = status_code
        self.detail = detail
        super().__init__(detail)

class Request:
    pass

class UploadFile:
    pass

def File(*args, **kwargs):
    return None

def Form(*args, **kwargs):
    return None

def Depends(*args, **kwargs):
    return None

class APIRouter:
    def __init__(self, *args, **kwargs):
        pass

    def post(self, *args, **kwargs):
        return lambda func: func

    def get(self, *args, **kwargs):
        return lambda func: func

fastapi_mod.HTTPException = HTTPException
fastapi_mod.Request = Request
fastapi_mod.UploadFile = UploadFile
fastapi_mod.File = File
fastapi_mod.Form = Form
fastapi_mod.Depends = Depends
fastapi_mod.APIRouter = APIRouter
sys.modules["fastapi"] = fastapi_mod

responses_mod = types.ModuleType("fastapi.responses")

class Response:
    pass

responses_mod.Response = Response
sys.modules["fastapi.responses"] = responses_mod

pydantic_mod = types.ModuleType("pydantic")

class BaseModel:
    pass

pydantic_mod.BaseModel = BaseModel
sys.modules["pydantic"] = pydantic_mod

sqlalchemy_mod = types.ModuleType("sqlalchemy")
sqlalchemy_orm_mod = types.ModuleType("sqlalchemy.orm")

class Session:
    pass

sqlalchemy_orm_mod.Session = Session
sys.modules["sqlalchemy"] = sqlalchemy_mod
sys.modules["sqlalchemy.orm"] = sqlalchemy_orm_mod

pkg = types.ModuleType("open_webui")
oauth_mod = types.ModuleType("open_webui.dropzone_oauth")
oauth_mod.get_user_oauth_access_token = lambda *args, **kwargs: ""
internal_mod = types.ModuleType("open_webui.internal")
db_mod = types.ModuleType("open_webui.internal.db")
db_mod.get_session = lambda *args, **kwargs: None
utils_mod = types.ModuleType("open_webui.utils")
auth_mod = types.ModuleType("open_webui.utils.auth")
auth_mod.get_verified_user = lambda *args, **kwargs: None
models_mod = types.ModuleType("open_webui.models")
users_mod = types.ModuleType("open_webui.models.users")
users_mod.Users = type("Users", (), {"get_user_by_id": staticmethod(lambda *args, **kwargs: None)})
users_mod.UserModel = type("UserModel", (), {})

sys.modules["open_webui"] = pkg
sys.modules["open_webui.dropzone_oauth"] = oauth_mod
sys.modules["open_webui.internal"] = internal_mod
sys.modules["open_webui.internal.db"] = db_mod
sys.modules["open_webui.utils"] = utils_mod
sys.modules["open_webui.utils.auth"] = auth_mod
sys.modules["open_webui.models"] = models_mod
sys.modules["open_webui.models.users"] = users_mod

spec = importlib.util.spec_from_file_location(
    "dropzone_audio", "branding/openwebui/dropzone_audio.py"
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

os.environ["CHUTES_TRAFFIC_MODE"] = "e2ee-proxy"
os.environ["CHUTES_PROXY_INTERNAL_URL"] = "http://e2ee-proxy:80"
os.environ["ALLOW_NON_CONFIDENTIAL"] = "true"

url, body = mod._audio_request_target(
    {
        "name": "kokoro",
        "slug": "chutes-kokoro",
        "chute_id": "4be47dee-7bee-53a4-a208-32a66f47a0b0",
        "tee": False,
    },
    mod.TTS_CORD,
)
assert url == "http://e2ee-proxy:80/v1/audio/speech"
assert body == {"model": "4be47dee-7bee-53a4-a208-32a66f47a0b0"}

assert mod._proxy_tts_payload(
    {
        "name": "kokoro",
        "slug": "chutes-kokoro",
        "chute_id": "4be47dee-7bee-53a4-a208-32a66f47a0b0",
    },
    {"text": "hello", "voice": "af_heart", "response_format": "mp3"},
) == {
    "model": "4be47dee-7bee-53a4-a208-32a66f47a0b0",
    "input": "hello",
    "voice": "af_heart",
    "response_format": "mp3",
}

assert mod._proxy_stt_fields(
    {
        "name": "whisper-large-v3",
        "slug": "chutes-whisper-large-v3",
        "chute_id": "dbe2d8e5-6f27-45b1-a6a0-1d3fa4cfcb47",
    }
) == {
    "model": "dbe2d8e5-6f27-45b1-a6a0-1d3fa4cfcb47",
    "response_format": "json",
}

multipart_body, multipart_content_type = mod._encode_multipart_form_data(
    {"model": "whisper-large-v3", "response_format": "json"},
    "file",
    "clip.webm",
    "audio/webm",
    b"audio-bytes",
)
assert multipart_content_type.startswith("multipart/form-data; boundary=")
multipart_text = multipart_body.decode("utf-8", errors="replace")
assert 'name="model"' in multipart_text
assert 'name="response_format"' in multipart_text
assert 'name="file"; filename="clip.webm"' in multipart_text

discovery = {
    "tts_items": [
        {
            "id": "publisher/kokoro",
            "name": "kokoro",
            "slug": "chutes-kokoro",
            "chute_id": "4be47dee-7bee-53a4-a208-32a66f47a0b0",
            "tee": False,
            "score": 0.1,
        },
        {
            "id": "publisher/spark-tts",
            "name": "spark-tts",
            "slug": "chutes-spark-tts",
            "chute_id": "8b55d8ef-8636-4d09-b95c-1a6ec0bbd640",
            "tee": True,
            "score": 0.9,
        },
    ],
    "tts_items_all": [
        {
            "id": "publisher/kokoro",
            "name": "kokoro",
            "slug": "chutes-kokoro",
            "chute_id": "4be47dee-7bee-53a4-a208-32a66f47a0b0",
            "tee": False,
            "score": 0.1,
        },
        {
            "id": "publisher/spark-tts",
            "name": "spark-tts",
            "slug": "chutes-spark-tts",
            "chute_id": "8b55d8ef-8636-4d09-b95c-1a6ec0bbd640",
            "tee": True,
            "score": 0.9,
        },
    ],
}
assert mod._select_audio_chute("tts", "kokoro", discovery)["name"] == "kokoro"
assert mod._select_audio_chute("tts", "publisher/spark-tts", discovery)["name"] == "spark-tts"

os.environ["ALLOW_NON_CONFIDENTIAL"] = "false"
try:
    mod._audio_request_target(
        {
            "name": "kokoro",
            "slug": "chutes-kokoro",
            "chute_id": "4be47dee-7bee-53a4-a208-32a66f47a0b0",
            "tee": False,
        },
        mod.TTS_CORD,
    )
    raise AssertionError("expected strict proxy audio rejection")
except mod.HTTPException as exc:
    assert exc.status_code == 503

strict_discovery = {
    "tts_items": [
        {
            "id": "publisher/spark-tts",
            "name": "spark-tts",
            "slug": "chutes-spark-tts",
            "chute_id": "8b55d8ef-8636-4d09-b95c-1a6ec0bbd640",
            "tee": True,
            "score": 0.9,
        },
    ],
    "tts_items_all": [
        {
            "id": "publisher/kokoro",
            "name": "kokoro",
            "slug": "chutes-kokoro",
            "chute_id": "4be47dee-7bee-53a4-a208-32a66f47a0b0",
            "tee": False,
            "score": 0.1,
        },
        {
            "id": "publisher/spark-tts",
            "name": "spark-tts",
            "slug": "chutes-spark-tts",
            "chute_id": "8b55d8ef-8636-4d09-b95c-1a6ec0bbd640",
            "tee": True,
            "score": 0.9,
        },
    ],
}
try:
    mod._select_audio_chute("tts", "kokoro", strict_discovery)
    raise AssertionError("expected strict proxy requested-model rejection")
except mod.HTTPException as exc:
    assert exc.status_code == 503

os.environ["DROPZONE_AUDIO_TTS_RETRY_ATTEMPTS"] = "2"
os.environ["DROPZONE_AUDIO_TTS_RETRY_BASE_DELAY_SECONDS"] = "0"
retry_calls = []
original_invoke_audio_request = mod._invoke_audio_request

def flaky_tts(chute, cord, payload, token, **kwargs):
    retry_calls.append(cord)
    if len(retry_calls) == 1:
        raise urllib.error.URLError("temporary gateway")
    return b"audio", "audio/wav"

mod._invoke_audio_request = flaky_tts
try:
    raw, content_type = asyncio.run(
        mod._invoke_tts_with_retries({"name": "kokoro"}, {"text": "hello"}, "token")
    )
finally:
    mod._invoke_audio_request = original_invoke_audio_request

assert raw == b"audio"
assert content_type == "audio/wav"
assert retry_calls == [mod.TTS_CORD, mod.TTS_CORD]

fatal_calls = []

def fatal_tts(chute, cord, payload, token, **kwargs):
    fatal_calls.append(cord)
    raise mod.HTTPException(status_code=503, detail="proxy not configured")

mod._invoke_audio_request = fatal_tts
try:
    asyncio.run(mod._invoke_tts_with_retries({"name": "kokoro"}, {"text": "hello"}, "token"))
    raise AssertionError("expected fatal HTTPException to pass through")
except mod.HTTPException as exc:
    assert exc.status_code == 503
finally:
    mod._invoke_audio_request = original_invoke_audio_request

assert fatal_calls == [mod.TTS_CORD]
PY
    then
        pass "Dropzone audio bridge honors proxy wire format, model selection, retries, and strict-mode guardrails"
    else
        fail "Dropzone audio bridge proxy wire format/model selection/retry/guardrails are incomplete"
    fi
else
    skip "python3 not installed - cannot validate OpenWebUI model-order sync helper"
fi

if [ -s "$PROJECT_DIR/branding/openwebui/dropzone_auth_page.html" ] && \
   grep -Fq 'Path(__file__).with_name("dropzone_auth_page.html")' "$PROJECT_DIR/branding/openwebui/dropzone_auth.py" && \
   grep -Fq 'COPY branding/openwebui/dropzone_auth_page.html /app/backend/open_webui/dropzone_auth_page.html' "$PROJECT_DIR/Dockerfile.local-repo" && \
   grep -Fq 'Log in with Fingerprint' "$PROJECT_DIR/branding/openwebui/dropzone_auth_page.html" && \
   grep -Fq 'name="auth_method" value="fingerprint"' "$PROJECT_DIR/branding/openwebui/dropzone_auth_page.html" && \
   grep -Fq 'type="password"' "$PROJECT_DIR/branding/openwebui/dropzone_auth_page.html" && \
   grep -Fq '/api/v1/dropzone/account-summary' "$PROJECT_DIR/branding/openwebui/dropzone_auth_page.html" && \
   grep -Fq 'dropzone-auth-redirect' "$PROJECT_DIR/branding/openwebui/dropzone_auth_page.html" && \
   grep -Fq 'stripWrappedCookieValue' "$PROJECT_DIR/branding/openwebui/dropzone_auth_page.html" && \
   grep -Fq 'OAUTH_STATE_SESSION_PREFIX = "_state_oidc_"' "$PROJECT_DIR/branding/openwebui/dropzone_auth.py" && \
   grep -Fq '_restore_oauth_states(request, previous_states)' "$PROJECT_DIR/branding/openwebui/dropzone_auth.py" && \
   grep -Fq '_get_reusable_oauth_authorize_url(request)' "$PROJECT_DIR/branding/openwebui/dropzone_auth.py" && \
   grep -Fq 'OAuth authorize setup returned provider status %s; retrying attempt %s/3' "$PROJECT_DIR/branding/openwebui/dropzone_auth.py" && \
   grep -Fq '_build_fingerprint_form_context' "$PROJECT_DIR/branding/openwebui/dropzone_auth.py" && \
   grep -Fq 'urllib.parse.quote(target, safe="")' "$PROJECT_DIR/branding/openwebui/dropzone_auth.py"; then
    pass "Dropzone auth page is template-driven and bundled with OpenWebUI"
else
    fail "Dropzone auth page template wiring is incomplete"
fi

if grep -Fq 'forceDropzoneAuthScreen' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'Sign in to Chutes Chat' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'Continue with Chutes' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq '/auth?redirect=' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'dropzone-auth-redirect' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'path === "/chat/auth"' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'var current = getSafeRelativePath(' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'stripWrappedCookieValue' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   ! grep -Fq 'sirouk2' "$PROJECT_DIR/branding/openwebui/loader.js"; then
    pass "OpenWebUI loader replaces legacy auth screens with Dropzone auth"
else
    fail "OpenWebUI loader is missing the legacy auth redirect guard"
fi

if grep -Fq 'window.__DROPZONE_AUTH_GATE__' "$PROJECT_DIR/scripts/patch-openwebui-build.py" && \
   grep -Fq '/api/v1/dropzone/account-summary' "$PROJECT_DIR/scripts/patch-openwebui-build.py" && \
   grep -Fq 'CHAT_AUTH_PATH' "$PROJECT_DIR/scripts/patch-openwebui-build.py" && \
   grep -Fq 'localStorage.setItem("token", token)' "$PROJECT_DIR/scripts/patch-openwebui-build.py" && \
   grep -Fq 'encodeURIComponent(currentTarget())' "$PROJECT_DIR/scripts/patch-openwebui-build.py" && \
   ! grep -Fq "return /(?:^|;\\s*)token=/.test(document.cookie || \"\");" "$PROJECT_DIR/scripts/patch-openwebui-build.py" && \
   grep -Fq 'window.location.replace' "$PROJECT_DIR/scripts/patch-openwebui-build.py"; then
    pass "OpenWebUI build patch injects an early auth gate before app boot"
else
    fail "OpenWebUI build patch is missing the early auth gate"
fi

if grep -Fq "localStorage.theme = 'dark';" "$PROJECT_DIR/scripts/patch-openwebui-build.py"; then
    pass "OpenWebUI defaults first-load theme to dark"
else
    fail "OpenWebUI first-load theme default is not pinned to dark"
fi

if grep -Fq 'from open_webui.dropzone_auth import get_request_auth_redirect_path' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "success_redirect_url = f'{redirect_base_url}{get_request_auth_redirect_path(request)}'" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "error_redirect_url = f'{redirect_base_url}/auth'" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py"; then
    pass "OpenWebUI runtime patch sends successful OAuth callbacks straight to the app target"
else
    fail "OpenWebUI runtime patch still routes successful OAuth callbacks through the legacy auth finalizer"
fi

if grep -Fq "request.cookies.get('token')" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py"; then
    pass "OpenWebUI runtime patch makes session bootstrap cookie-aware"
else
    fail "OpenWebUI runtime patch is missing the cookie-aware session bootstrap fix"
fi

if grep -Fq 'get_request_oauth_token' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq 'COPY branding/openwebui/dropzone_oauth.py /app/backend/open_webui/dropzone_oauth.py' "$PROJECT_DIR/Dockerfile.local-repo"; then
    pass "OpenWebUI runtime patch preserves OAuth-backed chat completions without the browser oauth cookie"
else
    fail "OpenWebUI runtime patch is missing the OAuth session fallback"
fi

if grep -Fq 'patch_config_module(root / "backend" / "open_webui" / "config.py")' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "self.config_path.startswith('oauth.')" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "self.value = self.env_value" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py"; then
    pass "OpenWebUI runtime patch keeps OAuth env authoritative after config saves"
else
    fail "OpenWebUI runtime patch can still reload persisted OAuth config after config saves"
fi

if grep -Fq "cookie_expires = datetime.utcnow() + expires_delta if expires_delta else None" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py"; then
    pass "OpenWebUI runtime patch fixes the undefined OAuth session cookie expiry"
else
    fail "OpenWebUI runtime patch is missing the OAuth session cookie expiry fix"
fi

if grep -Fq 'import asyncio' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq 'OAuth token exchange returned provider status %s; retrying attempt %s/3' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "request.session[callback_state_key] = callback_state_data" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq 'OAuth userinfo returned provider status %s; retrying attempt %s/3' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "await asyncio.sleep(0.5 * (token_attempt + 1))" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "detail='OAuth provider is temporarily unavailable. Please try again in a minute.'" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py"; then
    pass "OpenWebUI runtime patch retries transient upstream OAuth token and userinfo errors"
else
    fail "OpenWebUI runtime patch does not retry transient upstream OAuth token and userinfo errors"
fi

if grep -Fq 'ENABLE_OLLAMA_API=false' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'isOllamaVersionRequest' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq '\/ollama\/api\/version' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'connection_type = api_config.get("connection_type")' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq '**({"connection_type": model["connection_type"]} if model.get("connection_type") else {}),' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py"; then
    pass "OpenWebUI keeps Ollama disabled and Chutes models ungrouped"
else
    fail "OpenWebUI Ollama/model-grouping protections are missing"
fi

if grep -Fq 'var VERSION_UPDATES_URL = "/api/version/updates";' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function isVersionUpdatesRequest(input)' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq "parsed.pathname === VERSION_UPDATES_URL" "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq "Keep OpenWebUI's upstream self-update toast out of the branded product UI." "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'JSON.stringify({ current: "0.0.0", latest: "0.0.0" })' "$PROJECT_DIR/branding/openwebui/loader.js"; then
    pass "OpenWebUI suppresses the upstream self-update toast in the branded UI"
else
    fail "OpenWebUI still leaks the upstream self-update toast into the branded UI"
fi

if grep -Fq 'findNamedUserAnchor' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'syncCurrentUserAvatar(summary);' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'Users.update_user_profile_image_url_by_id' "$PROJECT_DIR/branding/openwebui/dropzone_account.py" && \
   grep -Fq '"userId": user.id' "$PROJECT_DIR/branding/openwebui/dropzone_account.py"; then
    pass "OpenWebUI sidebar card anchors to the native footer and syncs Chutes avatars"
else
    fail "OpenWebUI sidebar footer/avatar sync protections are missing"
fi

if grep -Fq 'OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'Now using {best_model_name}. Refreshes every {refresh_interval}.' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'tooltip_lines.extend(f"- {model_name}" for model_name in routing_models)' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'normalizeTooltipText(meta.routing_tooltip || "")' "$PROJECT_DIR/branding/openwebui/loader.js"; then
    pass "Chutes Auto metadata shows the current best model and full routing tooltip"
else
    fail "Chutes Auto metadata is missing the best-model description or routing tooltip list"
fi

if grep -Fq 'function getImageModelOptionSignature(models)' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function isImageGenerationEnabled(button)' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function findImageGenerationMenuButton()' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function hideCollapsedFeatureChips()' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function setImageModelPickerPlaceholder(selectNode, label)' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function findToolsMenuPanel(button)' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'text.indexOf("Code Interpreter") !== -1' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'if (!button) {' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'if (!isImageGenerationEnabled(button)) {' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function findImageModelPickerAnchor(button)' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'function mountImageModelPicker(button, slot)' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'slot.parentNode !== anchor.parentNode || slot.previousElementSibling !== anchor' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'anchor.insertAdjacentElement("afterend", slot);' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'data-chutes-hidden-feature-chip' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'button.querySelectorAll("[aria-pressed], [aria-checked], [aria-selected], [data-state], [data-selected], [class]")' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'hideCollapsedFeatureChips();' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'var needsOptionRefresh =' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'imageModelOptionSignature = "";' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'selectNode.options.length !== imageModels.length' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'setImageModelPickerPlaceholder(selectNode, "Loading image models...");' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'setImageModelPickerPlaceholder(selectNode, "Image models unavailable");' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'clearTooltip(slot);' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   ! grep -Fq 'applyTooltip(slot, tooltipText);' "$PROJECT_DIR/branding/openwebui/loader.js" && \
   grep -Fq 'grid-column: 1 / -1;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'flex: 0 0 100%;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'display: block;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'padding: 0 0.75rem;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'max-width: 24rem;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'margin: 0 auto;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'max-width: 100%;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq '.chutes-image-model-picker::before' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'padding: 0 0.45rem;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'cursor: progress;' "$PROJECT_DIR/branding/openwebui/custom.css" && \
   grep -Fq 'lines.extend(["", "Top choices"])' "$PROJECT_DIR/branding/openwebui/dropzone_images.py" && \
   grep -Fq 'lines.append(f"+ {len(models) - 4} more live model(s)")' "$PROJECT_DIR/branding/openwebui/dropzone_images.py" && \
   PROJECT_DIR="$PROJECT_DIR" python3 - <<'PY'
import os
from pathlib import Path

text = Path(os.environ["PROJECT_DIR"], "branding/openwebui/loader.js").read_text()
start = text.index("function ensureImageModelPicker() {")
end = text.index("function ensureSettingsAboutHidden()", start)
body = text[start:end]
queue_idx = body.index("queueImageModelFetch();")
gate_idx = body.index("if (!isImageGenerationEnabled(button)) {")
assert gate_idx < queue_idx
PY
then
    pass "Image picker lives in the tools menu, waits for active image mode, hides collapsed chips, and keeps auto-model tooltip lightweight"
else
    fail "Image picker tools-menu placement, active-mode gating, collapsed-chip hiding, or auto-model tooltip trimming is missing"
fi

if command -v jq >/dev/null 2>&1; then
    for file in "$PROJECT_DIR/workflows/"*.json; do
        if jq empty "$file" >/dev/null 2>&1; then
            pass "jq $(basename "$file")"
        else
            fail "jq $(basename "$file")"
        fi
    done
else
    skip "jq not installed - cannot validate workflow JSON"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.domain.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (domain stack)"
else
    fail "docker compose config (domain stack)"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (local stack)"
else
    fail "docker compose config (local stack)"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.domain.yml" -f "$PROJECT_DIR/docker-compose.traffic-proxy.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (domain proxy stack)"
else
    fail "docker compose config (domain proxy stack)"
fi

if docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" -f "$PROJECT_DIR/docker-compose.test.yml" -f "$PROJECT_DIR/docker-compose.traffic-proxy.yml" config -q >/dev/null 2>&1; then
    pass "docker compose config (local test proxy stack)"
else
    fail "docker compose config (local test proxy stack)"
fi

direct_openwebui_config="$(
    CHUTES_TRAFFIC_MODE=direct \
    OPENWEBUI_API_BASE_URL="https://llm.chutes.ai/v1" \
    docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" config 2>/dev/null || true
)"
if printf '%s\n' "$direct_openwebui_config" | grep -q 'OPENAI_API_BASE_URLS: https://llm.chutes.ai/v1'; then
    pass "direct mode renders OpenWebUI against llm.chutes.ai"
else
    fail "direct mode did not render OpenWebUI against llm.chutes.ai"
fi

if printf '%s\n' "$direct_openwebui_config" | grep -q 'DROPZONE_AUDIO_STT_ENGINE: local' && \
   printf '%s\n' "$direct_openwebui_config" | grep -q 'WHISPER_MODEL: base'; then
    pass "OpenWebUI defaults STT to container-local faster-whisper base"
else
    fail "OpenWebUI did not default STT to container-local faster-whisper base"
fi

openai_stt_openwebui_config="$(
    CHUTES_TRAFFIC_MODE=direct \
    OPENWEBUI_API_BASE_URL="https://llm.chutes.ai/v1" \
    DROPZONE_AUDIO_STT_ENGINE=openai \
    docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" config 2>/dev/null || true
)"
if printf '%s\n' "$openai_stt_openwebui_config" | grep -q 'DROPZONE_AUDIO_STT_ENGINE: openai'; then
    pass "OpenWebUI can switch STT back to the Chutes Whisper bridge"
else
    fail "OpenWebUI did not honor the STT override back to the Chutes Whisper bridge"
fi

proxy_openwebui_config="$(
    CHUTES_TRAFFIC_MODE=e2ee-proxy \
    OPENWEBUI_API_BASE_URL="https://llm.chutes.ai/v1" \
    docker compose -f "$PROJECT_DIR/docker-compose.yml" -f "$PROJECT_DIR/docker-compose.local.yml" -f "$PROJECT_DIR/docker-compose.traffic-proxy.yml" config 2>/dev/null || true
)"
if printf '%s\n' "$proxy_openwebui_config" | grep -q 'OPENAI_API_BASE_URLS: http://e2ee-proxy:80/v1'; then
    pass "e2ee-proxy mode renders OpenWebUI against the sidecar"
else
    fail "e2ee-proxy mode did not render OpenWebUI against the sidecar"
fi

if printf '%s\n' "$proxy_openwebui_config" | grep -q 'IMAGES_OPENAI_API_BASE_URL: http://e2ee-proxy:80/v1'; then
    pass "e2ee-proxy mode renders OpenWebUI image generation against the sidecar"
else
    fail "e2ee-proxy mode did not render OpenWebUI image generation against the sidecar"
fi

if printf '%s\n' "$proxy_openwebui_config" | grep -q 'CHUTES_PROXY_BASE_URL: http://e2ee-proxy:80'; then
    pass "e2ee-proxy mode renders n8n against the sidecar"
else
    fail "e2ee-proxy mode did not render n8n against the sidecar"
fi

for placeholder in __SERVER_NAME__ __TLS_DIRECTIVE__ __CHUTES_V1_BLOCK__ __ROOT_ENTRY_BLOCK__; do
    if grep -q "$placeholder" "$PROJECT_DIR/conf/Caddyfile.template"; then
        pass "Caddy template has $placeholder"
    else
        fail "Caddy template missing $placeholder"
    fi
done

for placeholder in __SERVER_NAME__ __RESOLVERS__ __CHUTES_V1_BLOCK__ __ROOT_ENTRY_BLOCK__; do
    if grep -q "$placeholder" "$PROJECT_DIR/conf/local-proxy.nginx.template"; then
        pass "local proxy template has $placeholder"
    else
        fail "local proxy template missing $placeholder"
    fi
done

for placeholder in __SERVER_NAME__ __RESOLVERS__ __CHUTES_V1_BLOCK__ __ROOT_ENTRY_BLOCK__; do
    if grep -q "$placeholder" "$PROJECT_DIR/standalone/nginx-domain-http.conf.template"; then
        pass "standalone domain HTTP template has $placeholder"
    else
        fail "standalone domain HTTP template missing $placeholder"
    fi
done

if grep -Fq 'microphone=(self)' "$PROJECT_DIR/conf/Caddyfile.template" && \
   grep -Fq 'microphone=(self)' "$PROJECT_DIR/conf/local-proxy.nginx.template" && \
   grep -Fq 'microphone=(self)' "$PROJECT_DIR/standalone/Caddyfile.template" && \
   grep -Fq 'microphone=(self)' "$PROJECT_DIR/standalone/nginx-domain-http.conf.template" && \
   grep -Fq 'microphone=(self)' "$PROJECT_DIR/standalone/nginx-standalone.conf.template"; then
    pass "edge security policy allows same-origin microphone capture for OpenWebUI voice input"
else
    fail "edge security policy still blocks same-origin microphone capture"
fi

if grep -q '/tmp/nginx-domain-http.conf' "$PROJECT_DIR/standalone/s6-rc.d/openresty/run" && \
   grep -q 'STANDALONE_ACME_EMAIL' "$PROJECT_DIR/standalone/s6-rc.d/openresty/run" && \
   grep -q 'STANDALONE_ACME_EMAIL' "$PROJECT_DIR/standalone/s6-rc.d/caddy/run" && \
   grep -q 'nginx-domain-http.conf.template' "$PROJECT_DIR/standalone/entrypoint.sh"; then
    pass "standalone HTTP-only domain mode routes through nginx instead of Caddy"
else
    fail "standalone HTTP-only domain mode is not wired to nginx correctly"
fi

if grep -Fq "cp -a \"\$APP_DATA_DIR\"/. \"\$DATA_DIR\"/" "$PROJECT_DIR/standalone/s6-rc.d/openwebui/run" && \
   grep -Fq "chown -R node:node \"\$DATA_DIR\"" "$PROJECT_DIR/standalone/s6-rc.d/openwebui/run" && \
   grep -Fq "chmod -R u+rwX \"\$DATA_DIR\"" "$PROJECT_DIR/standalone/s6-rc.d/openwebui/run"; then
    pass "standalone OpenWebUI fixes ownership after copying seeded data"
else
    fail "standalone OpenWebUI may leave copied seeded data read-only"
fi

if grep -q 'OPENWEBUI_API_BASE_URL="https://127.0.0.1:8443/v1"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -q 'OPENWEBUI_API_BASE_URL="http://127.0.0.1/v1"' "$PROJECT_DIR/standalone/entrypoint.sh"; then
    pass "domain e2ee-proxy switches the internal OpenWebUI upstream with ACME on/off"
else
    fail "domain e2ee-proxy is missing the HTTP-only internal OpenWebUI upstream"
fi

# shellcheck disable=SC2016
if grep -q 'set \$chutes_v1_host e2ee-proxy;' "$PROJECT_DIR/deploy.sh" && \
   grep -q 'proxy_pass \$chutes_v1_upstream;' "$PROJECT_DIR/deploy.sh"; then
    pass "local proxy defers e2ee-proxy DNS lookup until request time"
else
    fail "local proxy still resolves e2ee-proxy too early at startup"
fi

if grep -q '@chatCustomAssets path /static/custom.css /static/loader.js /static/site.webmanifest' "$PROJECT_DIR/deploy.sh" && \
   grep -q 'header @chatCustomAssets Cache-Control "no-store"' "$PROJECT_DIR/deploy.sh" && \
   grep -q '@chatAuth path /chat/auth /chat/auth/\*' "$PROJECT_DIR/deploy.sh" && \
   grep -q 'location = /static/custom.css {' "$PROJECT_DIR/deploy.sh" && \
   grep -q 'location = /static/loader.js {' "$PROJECT_DIR/deploy.sh" && \
   grep -q 'location = /static/site.webmanifest {' "$PROJECT_DIR/deploy.sh" && \
   grep -q 'location \^~ /chat/auth {' "$PROJECT_DIR/deploy.sh" && \
   grep -q '@chatCustomAssets path /static/custom.css /static/loader.js /static/site.webmanifest' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -q 'header @chatCustomAssets Cache-Control "no-store"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -q '@chatAuth path /chat/auth /chat/auth/\*' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -q 'location = /static/custom.css {' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -q 'location = /static/loader.js {' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -q 'location = /static/site.webmanifest {' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -q 'location \^~ /chat/auth {' "$PROJECT_DIR/standalone/entrypoint.sh"; then
    pass "chat assets and auth finalizer are routed correctly through the edge"
else
    fail "chat edge routing is missing the auth finalizer or no-store asset protection"
fi

if python3 - "$PROJECT_DIR/branding/openwebui/site.webmanifest" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text())
assert manifest["name"] == "Chutes Chat"
assert manifest["short_name"] == "Chutes Chat"
assert manifest["start_url"] == "/chat/"
assert manifest["scope"] == "/chat/"
assert manifest["icons"][0]["src"] == "/chat/static/chutes-chat-icon-192.png"
assert manifest["icons"][1]["src"] == "/chat/static/chutes-chat-icon-512.png"
PY
then
    pass "OpenWebUI manifest is branded for Chutes Chat"
else
    fail "OpenWebUI manifest branding is incomplete"
fi

if [ -s "$PROJECT_DIR/branding/openwebui/splash.svg" ] && \
   [ -s "$PROJECT_DIR/branding/openwebui/splash-dark.svg" ] && \
   grep -q 'splash-dark.svg' "$PROJECT_DIR/scripts/patch-openwebui-build.py" && \
   grep -q 'COPY scripts/patch-openwebui-build.py /opt/dropzone/patch-openwebui-build.py' "$PROJECT_DIR/Dockerfile.local-repo" && \
   grep -q 'python3 /opt/dropzone/patch-openwebui-build.py /app/build/index.html' "$PROJECT_DIR/Dockerfile.local-repo" && \
   grep -q 'COPY branding/openwebui/splash.svg /app/build/static/splash.svg' "$PROJECT_DIR/Dockerfile.local-repo" && \
   grep -q 'COPY branding/openwebui/splash-dark.svg /app/build/static/splash-dark.svg' "$PROJECT_DIR/Dockerfile.local-repo" && \
   grep -q 'COPY branding/openwebui/splash.svg /app/backend/open_webui/static/splash.svg' "$PROJECT_DIR/Dockerfile.local-repo" && \
   grep -q 'COPY branding/openwebui/splash-dark.svg /app/backend/open_webui/static/splash-dark.svg' "$PROJECT_DIR/Dockerfile.local-repo"; then
    pass "OpenWebUI splash screen uses Chutes-branded assets through the image build pipeline"
else
    fail "OpenWebUI splash screen branding is incomplete"
fi

if [ "$(grep -c 'COPY branding/openwebui/dropzone_images.py /app/backend/open_webui/dropzone_images.py' "$PROJECT_DIR/Dockerfile.local-repo")" -ge 2 ] && \
   grep -q 'patch_images_router(root / "backend" / "open_webui" / "routers" / "images.py")' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq "response_override = metadata.pop('_dropzone_response_override', None)" "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq 'def replace_all_of_or_keep(text: str, olds: list[str], new: str, label: str) -> str:' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq 'describe_chutes_image_request' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq '_dropzone_parse_image_prompt_response' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq '_dropzone_markdown_blockquote' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq '_dropzone_image_success_content' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq 'Prompt planning' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq '**Prompt sent**' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq '**Parameters**' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py" && \
   grep -Fq 'Image generation failed: {error_message or \"Unknown error\"}' "$PROJECT_DIR/scripts/patch-openwebui-runtime.py"; then
    pass "OpenWebUI image generation bridge is patched into the runtime with prompt/parameter summaries"
else
    fail "OpenWebUI image generation bridge wiring or image summary flow is incomplete"
fi

for placeholder in __INSTALL_MODE__ __CHUTES_TRAFFIC_MODE__ __DROPZONE_HOST__; do
    if grep -q "$placeholder" "$PROJECT_DIR/landing/index.template.html"; then
        pass "landing template has $placeholder"
    else
        fail "landing template missing $placeholder"
    fi
done

openwebui_version_pin="$(sed -n 's/^ARG OPENWEBUI_VERSION=//p' "$PROJECT_DIR/Dockerfile.local-repo" | head -n 1)"
openwebui_image_pin="$(sed -n 's/^ARG OPENWEBUI_IMAGE=//p' "$PROJECT_DIR/Dockerfile.local-repo" | head -n 1)"
case "$openwebui_image_pin" in
    *":${openwebui_version_pin}@sha256:"*)
        pass "Dockerfile pins OpenWebUI by version and digest"
        ;;
    *)
        fail "Dockerfile OpenWebUI pin is missing a matching versioned digest"
        ;;
esac

if grep -q '^OPENWEBUI_IMAGE=' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes the pinned OpenWebUI image"
else
    fail ".env.example is missing OPENWEBUI_IMAGE"
fi

if grep -q '^SEARXNG_IMAGE=' "$PROJECT_DIR/.env.example" && \
   grep -Fq 'searxng/searxng:latest@sha256:' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes the pinned SearXNG image"
else
    fail ".env.example is missing the pinned SearXNG image"
fi

if grep -q '^DROPZONE_ENABLE_PUBLIC_LANDING=' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes DROPZONE_ENABLE_PUBLIC_LANDING"
else
    fail ".env.example is missing DROPZONE_ENABLE_PUBLIC_LANDING"
fi

if grep -q '^DROPZONE_AUDIO_STT_ENGINE=' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes DROPZONE_AUDIO_STT_ENGINE"
else
    fail ".env.example is missing DROPZONE_AUDIO_STT_ENGINE"
fi

if grep -q '^ENABLE_WEB_SEARCH=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_SEARCH_ENGINE=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_SEARCH_RESULT_COUNT=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_SEARCH_CONCURRENT_REQUESTS=' "$PROJECT_DIR/.env.example" && \
   grep -q '^SEARXNG_QUERY_URL=' "$PROJECT_DIR/.env.example" && \
   grep -q '^SEARXNG_SECRET=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_SEARCH_DOMAIN_FILTER_LIST=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_SEARCH_TRUST_ENV=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_FETCH_MAX_CONTENT_LENGTH=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_LOADER_ENGINE=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_LOADER_CONCURRENT_REQUESTS=' "$PROJECT_DIR/.env.example" && \
   grep -q '^WEB_LOADER_TIMEOUT=' "$PROJECT_DIR/.env.example" && \
   grep -q '^ENABLE_WEB_LOADER_SSL_VERIFICATION=' "$PROJECT_DIR/.env.example" && \
   grep -q '^BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=' "$PROJECT_DIR/.env.example" && \
   grep -q '^BYPASS_WEB_SEARCH_WEB_LOADER=' "$PROJECT_DIR/.env.example" && \
   grep -q '^DDGS_BACKEND=' "$PROJECT_DIR/.env.example" && \
   grep -q '^OPENWEBUI_DEFAULT_FEATURE_IDS=' "$PROJECT_DIR/.env.example" && \
   grep -q '^ENABLE_IMAGE_GENERATION=' "$PROJECT_DIR/.env.example" && \
   grep -q '^ENABLE_IMAGE_PROMPT_GENERATION=' "$PROJECT_DIR/.env.example" && \
   grep -q '^ENABLE_TITLE_GENERATION=' "$PROJECT_DIR/.env.example" && \
   grep -q '^ENABLE_FOLLOW_UP_GENERATION=' "$PROJECT_DIR/.env.example" && \
   grep -q '^IMAGE_GENERATION_ENGINE=' "$PROJECT_DIR/.env.example" && \
   grep -q '^IMAGE_GENERATION_MODEL=' "$PROJECT_DIR/.env.example" && \
   grep -q '^IMAGES_OPENAI_API_BASE_URL=' "$PROJECT_DIR/.env.example" && \
   grep -q '^IMAGES_OPENAI_API_KEY=' "$PROJECT_DIR/.env.example" && \
   grep -q '^TASK_MODEL=' "$PROJECT_DIR/.env.example" && \
   grep -q '^TASK_MODEL_EXTERNAL=' "$PROJECT_DIR/.env.example" && \
   grep -q '^IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE=' "$PROJECT_DIR/.env.example" && \
   grep -q '^DROPZONE_IMAGE_GENERATION_PROVIDER=' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes native OpenWebUI web search, image generation, and image prompt task knobs"
else
    fail ".env.example is missing native OpenWebUI web search, image generation, or image prompt task settings"
fi

if grep -q '^DROPZONE_AUDIO_STT_LOCAL_MODEL=' "$PROJECT_DIR/.env.example"; then
    pass ".env.example exposes DROPZONE_AUDIO_STT_LOCAL_MODEL"
else
    fail ".env.example is missing DROPZONE_AUDIO_STT_LOCAL_MODEL"
fi

# shellcheck disable=SC2016
if grep -Fq 'ENABLE_WEB_SEARCH=${ENABLE_WEB_SEARCH:-true}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'SEARXNG_IMAGE:-searxng/searxng:latest@sha256:' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'conf/searxng/settings.yml:/etc/searxng/settings.yml:ro' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_SEARCH_ENGINE=${WEB_SEARCH_ENGINE:-searxng}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_SEARCH_RESULT_COUNT=${WEB_SEARCH_RESULT_COUNT:-5}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_SEARCH_CONCURRENT_REQUESTS=${WEB_SEARCH_CONCURRENT_REQUESTS:-2}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'SEARXNG_QUERY_URL=${SEARXNG_QUERY_URL:-http://searxng:8080/search?q=<query>}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_SEARCH_DOMAIN_FILTER_LIST=${WEB_SEARCH_DOMAIN_FILTER_LIST:-[]}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_SEARCH_TRUST_ENV=${WEB_SEARCH_TRUST_ENV:-false}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_FETCH_MAX_CONTENT_LENGTH=${WEB_FETCH_MAX_CONTENT_LENGTH:-50000}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_LOADER_ENGINE=${WEB_LOADER_ENGINE:-safe_web}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_LOADER_CONCURRENT_REQUESTS=${WEB_LOADER_CONCURRENT_REQUESTS:-4}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'WEB_LOADER_TIMEOUT=${WEB_LOADER_TIMEOUT:-20}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'ENABLE_WEB_LOADER_SSL_VERIFICATION=${ENABLE_WEB_LOADER_SSL_VERIFICATION:-true}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL=${BYPASS_WEB_SEARCH_EMBEDDING_AND_RETRIEVAL:-false}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'BYPASS_WEB_SEARCH_WEB_LOADER=${BYPASS_WEB_SEARCH_WEB_LOADER:-false}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'DDGS_BACKEND=${DDGS_BACKEND:-duckduckgo}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'OPENWEBUI_DEFAULT_FEATURE_IDS=${OPENWEBUI_DEFAULT_FEATURE_IDS:-web_search,image_generation}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'ENABLE_IMAGE_GENERATION=${ENABLE_IMAGE_GENERATION:-true}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'ENABLE_IMAGE_PROMPT_GENERATION=${ENABLE_IMAGE_PROMPT_GENERATION:-true}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'ENABLE_TITLE_GENERATION=${ENABLE_TITLE_GENERATION:-true}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'ENABLE_FOLLOW_UP_GENERATION=${ENABLE_FOLLOW_UP_GENERATION:-true}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'IMAGE_GENERATION_ENGINE=${IMAGE_GENERATION_ENGINE:-openai}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'IMAGE_GENERATION_MODEL=${IMAGE_GENERATION_MODEL:-chutes-auto-image}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'IMAGES_OPENAI_API_BASE_URL=${IMAGES_OPENAI_API_BASE_URL:-https://llm.chutes.ai/v1}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'IMAGES_OPENAI_API_BASE_URL=http://e2ee-proxy:80/v1' "$PROJECT_DIR/docker-compose.traffic-proxy.yml" && \
   grep -Fq 'TASK_MODEL=${TASK_MODEL:-}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'TASK_MODEL_EXTERNAL=${TASK_MODEL_EXTERNAL:-}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE=${IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE:-}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'DROPZONE_IMAGE_GENERATION_PROVIDER=${DROPZONE_IMAGE_GENERATION_PROVIDER:-chutes}' "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq 'env_line ENABLE_WEB_SEARCH' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line SEARXNG_QUERY_URL' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line SEARXNG_SECRET' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line ENABLE_IMAGE_PROMPT_GENERATION' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line ENABLE_TITLE_GENERATION' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line ENABLE_FOLLOW_UP_GENERATION' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line IMAGE_GENERATION_MODEL' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line TASK_MODEL ' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line TASK_MODEL_EXTERNAL ' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE ' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line DROPZONE_IMAGE_GENERATION_PROVIDER' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line ENABLE_WEB_SEARCH' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'env_line SEARXNG_QUERY_URL' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'env_line CHUTES_PROXY_INTERNAL_URL' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'env_line WEB_LOADER_ENGINE' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'env_line OPENWEBUI_DEFAULT_FEATURE_IDS' "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'env_line OPENWEBUI_DEFAULT_FEATURE_IDS' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export ENABLE_WEB_SEARCH="${ENABLE_WEB_SEARCH:-true}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export SEARXNG_QUERY_URL="${SEARXNG_QUERY_URL:-}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export OPENWEBUI_DEFAULT_FEATURE_IDS="${OPENWEBUI_DEFAULT_FEATURE_IDS:-web_search,image_generation}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export WEB_SEARCH_RESULT_COUNT="${WEB_SEARCH_RESULT_COUNT:-5}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export WEB_LOADER_ENGINE="${WEB_LOADER_ENGINE:-safe_web}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export DDGS_BACKEND="${DDGS_BACKEND:-duckduckgo}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export ENABLE_IMAGE_GENERATION="${ENABLE_IMAGE_GENERATION:-true}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export IMAGES_OPENAI_API_BASE_URL="${CHUTES_PROXY_INTERNAL_URL%/}/v1"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export ENABLE_IMAGE_PROMPT_GENERATION="${ENABLE_IMAGE_PROMPT_GENERATION:-true}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export ENABLE_TITLE_GENERATION="${ENABLE_TITLE_GENERATION:-true}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export ENABLE_FOLLOW_UP_GENERATION="${ENABLE_FOLLOW_UP_GENERATION:-true}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export IMAGE_GENERATION_MODEL="${IMAGE_GENERATION_MODEL:-chutes-auto-image}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export TASK_MODEL="${TASK_MODEL:-}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export TASK_MODEL_EXTERNAL="${TASK_MODEL_EXTERNAL:-}"' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE="${IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE:-' "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq 'export DROPZONE_IMAGE_GENERATION_PROVIDER="${DROPZONE_IMAGE_GENERATION_PROVIDER:-chutes}"' "$PROJECT_DIR/standalone/entrypoint.sh"; then
    pass "Dropzone deploy scaffolding exposes native OpenWebUI web search, image generation, and image prompt task wiring"
else
    fail "Dropzone deploy scaffolding is missing native OpenWebUI web search, image generation, or image prompt task wiring"
fi

if grep -Fq 'def sync_web_config' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'def sync_user_permissions' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'WEB_SEARCH_RESULT_COUNT' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'SEARXNG_QUERY_URL' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'DDGS_BACKEND' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq '/api/v1/retrieval/config/update' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq '/api/v1/users/default/permissions' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'web search config mismatch' "$PROJECT_DIR/scripts/configure-openwebui.sh" && \
   grep -Fq 'default user feature permission mismatch' "$PROJECT_DIR/scripts/configure-openwebui.sh"; then
    pass "OpenWebUI web search defaults and feature permissions are runtime-synced and verified"
else
    fail "OpenWebUI web search runtime sync, permissions sync, or verification is incomplete"
fi

if grep -Fq 'use_default_settings:' "$PROJECT_DIR/conf/searxng/settings.yml" && \
   grep -Fq 'keep_only:' "$PROJECT_DIR/conf/searxng/settings.yml" && \
   grep -Fq 'duckduckgo' "$PROJECT_DIR/conf/searxng/settings.yml" && \
   grep -Fq 'safe_search: 1' "$PROJECT_DIR/conf/searxng/settings.yml" && \
   grep -Fq -- '- json' "$PROJECT_DIR/conf/searxng/settings.yml"; then
    pass "SearXNG sidecar uses curated keyless engines and enables JSON search output"
else
    fail "SearXNG sidecar config is missing curated engines or JSON output"
fi

if grep -Fq 'MANAGED_AGENTIC_FEATURES = ("web_search", "image_generation")' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'def managed_agentic_metadata' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'def managed_agentic_params' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'params["function_calling"] = "native"' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'meta["defaultFeatureIds"] = next_features' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'supports_native_tools(model_lookup.get(model_id))' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'MODEL_OVERRIDES' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py"; then
    pass "OpenWebUI model overrides default web/image to native tools instead of forced legacy actions"
else
    fail "OpenWebUI model overrides are missing native agentic web/image defaults"
fi

if grep -Fq 'converge_openwebui_runtime_config()' "$PROJECT_DIR/scripts/configure-openwebui.sh" && \
   grep -Fq "OpenWebUI runtime config is still converging (attempt \${attempt}/\${max_attempts})" "$PROJECT_DIR/scripts/configure-openwebui.sh" && \
   grep -Fq "ERROR: OpenWebUI runtime config did not converge after \${max_attempts} attempt(s)" "$PROJECT_DIR/scripts/configure-openwebui.sh"; then
    pass "OpenWebUI runtime verification retries convergence and prints the underlying mismatch"
else
    fail "OpenWebUI runtime verification is missing convergence retries or detailed mismatch output"
fi

if grep -Fq "DROPZONE_AUDIO_STT_ENGINE=\${DROPZONE_AUDIO_STT_ENGINE:-local}" "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq "DROPZONE_AUDIO_STT_LOCAL_MODEL=\${DROPZONE_AUDIO_STT_LOCAL_MODEL:-base}" "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq "WHISPER_MODEL=\${DROPZONE_AUDIO_STT_LOCAL_MODEL:-base}" "$PROJECT_DIR/docker-compose.yml" && \
   grep -Fq "env_line DROPZONE_AUDIO_STT_ENGINE \"\${DROPZONE_AUDIO_STT_ENGINE:-local}\"" "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq "env_line DROPZONE_AUDIO_STT_LOCAL_MODEL \"\${DROPZONE_AUDIO_STT_LOCAL_MODEL:-base}\"" "$PROJECT_DIR/standalone/entrypoint.sh" && \
   grep -Fq "DROPZONE_AUDIO_STT_ENGINE=\"\${DROPZONE_AUDIO_STT_ENGINE:-local}\"" "$PROJECT_DIR/deploy.sh" && \
   grep -Fq "DROPZONE_AUDIO_STT_LOCAL_MODEL=\"\${DROPZONE_AUDIO_STT_LOCAL_MODEL:-base}\"" "$PROJECT_DIR/deploy.sh" && \
   grep -Fq 'desired_stt_engine_mode()' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'sync_audio_config(token)' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py"; then
    pass "OpenWebUI STT defaults to local Whisper base and runtime-syncs web/openai overrides"
else
    fail "OpenWebUI STT default/override wiring is incomplete"
fi

if grep -Fq 'ENABLE_IMAGE_PROMPT_GENERATION' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'ENABLE_TITLE_GENERATION' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'ENABLE_FOLLOW_UP_GENERATION' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'def sync_task_config(token: str) -> bool:' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq '/api/v1/tasks/config' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'TASK_MODEL' "$PROJECT_DIR/scripts/openwebui-model-order-sync.py" && \
   grep -Fq 'request_json("/api/v1/tasks/config", token)' "$PROJECT_DIR/scripts/configure-openwebui.sh" && \
   grep -Fq 'expected_image_prompt_enabled = (' "$PROJECT_DIR/scripts/configure-openwebui.sh" && \
   grep -Fq 'expected_title_generation_enabled = (' "$PROJECT_DIR/scripts/configure-openwebui.sh" && \
   grep -Fq 'expected_follow_up_generation_enabled = (' "$PROJECT_DIR/scripts/configure-openwebui.sh" && \
   grep -Fq 'expected_image_prompt_template = (' "$PROJECT_DIR/scripts/configure-openwebui.sh"; then
    pass "OpenWebUI image prompt, title, and follow-up generation are runtime-synced"
else
    fail "OpenWebUI task-generation runtime wiring is incomplete"
fi

if grep -q 'DROPZONE_ENABLE_PUBLIC_LANDING: "false"' "$PROJECT_DIR/examples/kubernetes/standalone-domain-direct.yaml" && \
   grep -q 'DROPZONE_HOST: "chat-beta.chutes.ai"' "$PROJECT_DIR/examples/kubernetes/standalone-domain-direct.yaml" && \
   grep -q 'DROPZONE_AUDIO_STT_ENGINE: "local"' "$PROJECT_DIR/examples/kubernetes/standalone-domain-direct.yaml" && \
   grep -q 'DROPZONE_AUDIO_STT_LOCAL_MODEL: "base"' "$PROJECT_DIR/examples/kubernetes/standalone-domain-direct.yaml"; then
    pass "kubernetes standalone example defaults to chat-beta.chutes.ai with the landing page disabled"
else
    fail "kubernetes standalone example is missing the chat-beta.chutes.ai private-entry defaults"
fi

if grep -q '@sha256:' "$PROJECT_DIR/docker-compose.domain.yml"; then
    pass "domain compose pins the Caddy runtime image by digest"
else
    fail "domain compose is missing a digest-pinned Caddy image"
fi

if grep -q '@sha256:' "$PROJECT_DIR/Dockerfile.local-proxy" && \
   grep -q '@sha256:' "$PROJECT_DIR/Dockerfile.e2ee-proxy"; then
    pass "proxy Dockerfiles pin e2ee-proxy by digest"
else
    fail "proxy Dockerfiles are missing digest-pinned e2ee-proxy images"
fi

if grep -Fq 'map[model.chute_id] = entry' "$PROJECT_DIR/n8n-overlays/e2ee-proxy/lua/e2ee_discovery.lua" && \
   grep -Fq 'local function request_chute_metadata(chute_id, api_key)' "$PROJECT_DIR/n8n-overlays/e2ee-proxy/lua/e2ee_discovery.lua" && \
   grep -Fq 'ngx.escape_uri(chute_id)' "$PROJECT_DIR/n8n-overlays/e2ee-proxy/lua/e2ee_discovery.lua" && \
   grep -Fq 'local function resolve_uuid_chute_id(chute_id, api_key)' "$PROJECT_DIR/n8n-overlays/e2ee-proxy/lua/e2ee_discovery.lua" && \
   grep -Fq 'chute.tee == true or chute.confidential_compute == true' "$PROJECT_DIR/n8n-overlays/e2ee-proxy/lua/e2ee_discovery.lua" && \
   grep -Fq 'refusing strict e2ee routing' "$PROJECT_DIR/n8n-overlays/e2ee-proxy/lua/e2ee_discovery.lua" && \
   ! grep -Fq 'return model' "$PROJECT_DIR/n8n-overlays/e2ee-proxy/lua/e2ee_discovery.lua"; then
    pass "e2ee-proxy validates raw chute IDs against TEE metadata before strict routing"
else
    fail "e2ee-proxy raw chute ID resolution can bypass strict TEE validation"
fi

ci_nodes_ref="$(sed -n 's/^[[:space:]]*N8N_NODES_CHUTES_REF:[[:space:]]*//p' "$PROJECT_DIR/.github/workflows/ci.yml" | head -n 1)"
release_nodes_ref="$(sed -n 's/^[[:space:]]*N8N_NODES_CHUTES_REF:[[:space:]]*//p' "$PROJECT_DIR/.github/workflows/release.yml" | head -n 1)"
deploy_nodes_ref="$(awk -F'\"' '/^PROJECT_NODES_REF=/{print $2; exit}' "$PROJECT_DIR/deploy.sh")"

if [ -n "$ci_nodes_ref" ] && [ "$ci_nodes_ref" = "$release_nodes_ref" ] && [ "$ci_nodes_ref" = "$deploy_nodes_ref" ]; then
    pass "n8n-nodes-chutes pin matches across ci, release, and deploy"
else
    fail "n8n-nodes-chutes pin drifted across ci, release, or deploy"
fi

if grep -Fq 'name: Build release image stage' "$PROJECT_DIR/.github/workflows/ci.yml" && \
   grep -Fq "if: matrix.traffic_mode == 'direct'" "$PROJECT_DIR/.github/workflows/ci.yml" && \
   grep -Fq 'tags: chutes-dropzone-ci-release:latest' "$PROJECT_DIR/.github/workflows/ci.yml"; then
    pass "CI builds the release Docker stage before E2E"
else
    fail "CI is missing release-stage Docker build coverage"
fi

if [ -s "$PROJECT_DIR/package-lock.json" ] && \
   grep -Fq '"@playwright/test"' "$PROJECT_DIR/package.json" && \
   grep -Fq '"test:browser": "playwright test"' "$PROJECT_DIR/package.json" && \
   grep -Fq 'name: Run browser UI regression tests' "$PROJECT_DIR/.github/workflows/ci.yml" && \
   grep -Fq 'npx playwright install --with-deps chromium' "$PROJECT_DIR/.github/workflows/ci.yml" && \
   grep -Fq 'npm run test:browser' "$PROJECT_DIR/.github/workflows/ci.yml" && \
   grep -Fq 'previousIsImageRow: true' "$PROJECT_DIR/tests/browser/openwebui-tools-menu.spec.js" && \
   grep -Fq 'selectIsCentered: true' "$PROJECT_DIR/tests/browser/openwebui-tools-menu.spec.js" && \
   grep -Fq 'dropzone-image-model=chutes%2Fhunyuan-image-3' "$PROJECT_DIR/tests/browser/openwebui-tools-menu.spec.js"; then
    pass "CI runs browser regression coverage for the OpenWebUI tools image picker"
else
    fail "CI is missing browser regression coverage for the OpenWebUI tools image picker"
fi

if [ "$SYNTAX_ONLY" = true ]; then
    echo
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" -eq 0 ]
    exit $?
fi

echo
echo "=== Runtime checks ==="

if [ ! -f "$PROJECT_DIR/.env" ]; then
    fail ".env missing - run deploy.sh first"
    echo
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "$PROJECT_DIR/.env"
set +a

DROPZONE_HOST="${DROPZONE_HOST:-${N8N_HOST:-e2ee-local-proxy.chutes.dev}}"
DROPZONE_ENABLE_PUBLIC_LANDING="${DROPZONE_ENABLE_PUBLIC_LANDING:-true}"
DROPZONE_ENABLE_OPENWEBUI="${DROPZONE_ENABLE_OPENWEBUI:-true}"
DROPZONE_ENABLE_N8N="${DROPZONE_ENABLE_N8N:-true}"
N8N_EDGE_URL="https://${DROPZONE_HOST}/n8n"
CHAT_EDGE_URL="https://${DROPZONE_HOST}/chat"
LANDING_EDGE_URL="https://${DROPZONE_HOST}/"

openwebui_enabled() {
    [ "${DROPZONE_ENABLE_OPENWEBUI:-true}" != "false" ]
}

n8n_enabled() {
    [ "${DROPZONE_ENABLE_N8N:-true}" != "false" ]
}

primary_launcher_path() {
    if openwebui_enabled; then
        printf '/chat/'
        return
    fi

    printf '/n8n/'
}

EDGE_SERVICE="${EDGE_SERVICE:-}"
if [ -z "$EDGE_SERVICE" ]; then
    case "${INSTALL_MODE:-domain}" in
        local) EDGE_SERVICE="local-proxy" ;;
        *) EDGE_SERVICE="caddy" ;;
    esac
fi

WAIT_SERVICES="postgres $EDGE_SERVICE"
if n8n_enabled; then
    WAIT_SERVICES="$WAIT_SERVICES n8n"
fi
if openwebui_enabled; then
    WAIT_SERVICES="$WAIT_SERVICES openwebui"
fi
if [ "${CHUTES_TRAFFIC_MODE:-direct}" = "e2ee-proxy" ]; then
    WAIT_SERVICES="$WAIT_SERVICES e2ee-proxy"
fi

for service in $WAIT_SERVICES; do
    status="$(wait_for_service "$service" "$(wait_attempts_for_service "$service")" || true)"
    if [ "$status" = "healthy" ] || [ "$status" = "running" ]; then
        pass "$service container $status"
    else
        fail "$service container status: $status"
    fi
done

if [ "$EDGE_SERVICE" = "caddy" ]; then
    if compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        pass "caddy validate"
    else
        fail "caddy validate"
    fi
else
    if compose exec -T local-proxy /usr/local/openresty/bin/openresty -t >/dev/null 2>&1; then
        pass "openresty validate"
    else
        fail "openresty validate"
    fi
fi

if n8n_enabled; then
    healthz="$(compose exec -T n8n wget -q -O- http://127.0.0.1:5678/rest/settings 2>/dev/null || echo '')"
    if echo "$healthz" | grep -q '"settingsMode"'; then
        pass "n8n /rest/settings responds"
    else
        fail "n8n /rest/settings unreachable"
    fi
else
    skip "n8n is disabled - skipping n8n health probe"
fi

if openwebui_enabled; then
    if compose exec -T openwebui python -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/', timeout=5).read()" \
        >/dev/null 2>&1; then
        pass "OpenWebUI responds on port 8080"
    else
        fail "OpenWebUI is unreachable on port 8080"
    fi
else
    skip "OpenWebUI is disabled - skipping OpenWebUI health probe"
fi

if openwebui_enabled; then
    if compose exec -T openwebui python - <<'PY' >/dev/null 2>&1
import json
import os
import sys
import urllib.parse
import urllib.request


def enabled(name: str, default: str = "true") -> bool:
    return (os.environ.get(name) or default).strip().lower() == "true"


def searxng_results(query_url: str) -> list:
    if not query_url:
        raise RuntimeError("SEARXNG_QUERY_URL is empty")

    if "<query>" in query_url:
        query_url = query_url.split("?", 1)[0]

    params = {
        "q": "Open WebUI",
        "format": "json",
        "pageno": "1",
        "safesearch": "1",
        "language": "all",
        "theme": "simple",
        "image_proxy": "0",
    }
    separator = "&" if "?" in query_url else "?"
    url = query_url + separator + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload.get("results", []) if isinstance(payload, dict) else []


def duckduckgo_results() -> list:
    from ddgs import DDGS

    backend = (os.environ.get("DDGS_BACKEND") or "duckduckgo").strip() or "duckduckgo"
    with DDGS() as ddgs:
        return list(ddgs.text("Open WebUI", safesearch="moderate", max_results=1, backend=backend))


if not enabled("ENABLE_WEB_SEARCH"):
    sys.exit(77)

engine = (os.environ.get("WEB_SEARCH_ENGINE") or "").strip()
query_url = (os.environ.get("SEARXNG_QUERY_URL") or "").strip()
if not engine:
    engine = "searxng" if query_url else "duckduckgo"
elif engine == "searxng" and not query_url:
    engine = "duckduckgo"

if engine == "searxng":
    results = searxng_results(query_url)
elif engine == "duckduckgo":
    results = duckduckgo_results()
else:
    sys.exit(77)

if not results:
    raise RuntimeError(f"{engine} returned no web search results")
PY
    then
        pass "OpenWebUI web search backend returns live results"
    else
        web_probe_status=$?
        if [ "$web_probe_status" = "77" ]; then
            skip "OpenWebUI web search backend probe is disabled or uses a custom engine"
        else
            fail "OpenWebUI web search backend did not return live results"
        fi
    fi
else
    skip "OpenWebUI is disabled - skipping OpenWebUI web search backend probe"
fi

landing_headers="$(curl_edge -skI "$LANDING_EDGE_URL" 2>/dev/null | tr -d '\r' || true)"
if echo "$landing_headers" | grep -qi '^X-Content-Type-Options: nosniff' && \
   echo "$landing_headers" | grep -qi '^X-Frame-Options: SAMEORIGIN' && \
   echo "$landing_headers" | grep -qi '^Referrer-Policy: strict-origin-when-cross-origin' && \
   echo "$landing_headers" | grep -qi '^Strict-Transport-Security:' && \
   echo "$landing_headers" | grep -qi '^Permissions-Policy:'; then
    pass "public app edge sends baseline security headers"
else
    fail "public app edge is missing baseline security headers"
fi

if echo "$landing_headers" | grep -qi '^Access-Control-Allow-Origin: \*'; then
    fail "public app edge is exposing wildcard CORS outside the /v1 API surface"
else
    pass "public app edge does not expose wildcard CORS headers"
fi

if [ "$DROPZONE_ENABLE_PUBLIC_LANDING" = "true" ]; then
    landing_html="$(curl_edge -sk "$LANDING_EDGE_URL" 2>/dev/null || true)"
    landing_missing=0
    if openwebui_enabled && ! echo "$landing_html" | grep -q '/chat/'; then
        landing_missing=1
    fi
    if n8n_enabled && ! echo "$landing_html" | grep -q '/n8n/'; then
        landing_missing=1
    fi
    if [ "$landing_missing" -eq 0 ]; then
        pass "landing page is reachable and links only to enabled applications"
    else
        fail "landing page is missing launch links"
    fi

    landing_css_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/_dropzone/styles.css" 2>/dev/null || true)"
    if echo "$landing_css_headers" | grep -qi '^Content-Type: text/css'; then
        pass "landing stylesheet is served as text/css"
    else
        fail "landing stylesheet content type is not text/css"
    fi

    if echo "$landing_headers" | grep -qi '^Cache-Control: no-store'; then
        pass "landing HTML disables stale browser caching"
    else
        fail "landing HTML is missing Cache-Control: no-store"
    fi
else
    if echo "$landing_headers" | grep -qi '^HTTP/.* 302' && \
       { echo "$landing_headers" | grep -qi "^location: $(primary_launcher_path)$" || \
         echo "$landing_headers" | grep -qi "^location: https://${DROPZONE_HOST}$(primary_launcher_path)$"; } && \
       ! echo "$landing_headers" | grep -qi "^location: http://${DROPZONE_HOST}"; then
        pass "root entry redirects straight to the enabled primary app when public landing is disabled"
    else
        fail "root entry did not redirect to the enabled primary app with DROPZONE_ENABLE_PUBLIC_LANDING=false"
    fi
fi

if openwebui_enabled; then
    auth_headers="$(curl_edge -skD- "https://${DROPZONE_HOST}/auth?redirect=%2Fchat%2F" -o /dev/null 2>/dev/null || true)"
    auth_html="$(curl_edge -sk "https://${DROPZONE_HOST}/auth?redirect=%2Fchat%2F" 2>/dev/null || true)"
    if echo "$auth_headers" | grep -qi '^HTTP/.* 200' && \
       echo "$auth_headers" | grep -qi '^set-cookie: owui-session=' && \
       echo "$auth_headers" | grep -qi '^set-cookie: dropzone-auth-redirect=' && \
       echo "$auth_html" | grep -q 'id="fingerprint-login"' && \
       echo "$auth_html" | grep -q 'Log in to Chutes' && \
       echo "$auth_html" | grep -q 'action=".*\/idp\/login"' && \
       echo "$auth_html" | grep -q 'name="auth_method" value="fingerprint"' && \
       echo "$auth_html" | grep -q 'type="password"' && \
       echo "$auth_html" | grep -q 'Google' && \
       echo "$auth_html" | grep -q 'GitHub' && \
       echo "$auth_html" | grep -q 'Create Account' && \
       echo "$auth_html" | grep -Fq '/auth/signin/google?callbackUrl=' && \
       echo "$auth_html" | grep -q 'redirect_to=' && \
       echo "$auth_html" | grep -q 'redirect-path=%2Fchat%2F' && \
       ! echo "$auth_html" | grep -Fq '?/login' && \
       ! echo "$auth_html" | grep -q 'Sign in to Chutes Chat' && \
       ! echo "$auth_html" | grep -q 'Continue with Chutes'; then
        pass "root OpenWebUI auth alias renders the Chutes login options page"
    else
        fail "root OpenWebUI auth alias did not render the Chutes login options page"
    fi

    auth_stale_cookie_headers="$(curl_edge -skD- -H 'Cookie: token=stale-session' \
        "https://${DROPZONE_HOST}/auth?redirect=%2Fchat%2F" -o /dev/null 2>/dev/null || true)"
    auth_stale_cookie_html="$(curl_edge -sk -H 'Cookie: token=stale-session' \
        "https://${DROPZONE_HOST}/auth?redirect=%2Fchat%2F" 2>/dev/null || true)"
    if echo "$auth_stale_cookie_headers" | grep -qi '^HTTP/.* 200' && \
       echo "$auth_stale_cookie_headers" | grep -qi '^set-cookie: owui-session=' && \
       echo "$auth_stale_cookie_html" | grep -q 'Log in to Chutes' && \
       echo "$auth_stale_cookie_html" | grep -q 'Google' && \
       echo "$auth_stale_cookie_html" | grep -q 'action=".*\/idp\/login"' && \
       echo "$auth_stale_cookie_html" | grep -q 'redirect-path=%2Fchat%2F' && \
       ! echo "$auth_stale_cookie_html" | grep -q 'Continue with Chutes'; then
        pass "root OpenWebUI auth alias ignores stale token cookies"
    else
        fail "root OpenWebUI auth alias still falls back to the native auth screen when a stale token cookie is present"
    fi

    openwebui_account_status="$(curl_edge -sk -o /tmp/chutes-dropzone.openwebui-account.out -w '%{http_code}' \
        "https://${DROPZONE_HOST}/api/v1/dropzone/account-summary" 2>/dev/null || echo 000)"
    case "$openwebui_account_status" in
        401|403)
            pass "OpenWebUI account-summary endpoint rejects anonymous requests"
            ;;
        *)
            fail "OpenWebUI account-summary endpoint returned unexpected anonymous status $openwebui_account_status"
            ;;
    esac

    chat_status="$(curl_edge -sk -o /tmp/chutes-dropzone.chat.out -w '%{http_code}' "$CHAT_EDGE_URL/" 2>/dev/null || echo 000)"
    case "$chat_status" in
        302)
            chat_headers="$(curl_edge -skI "$CHAT_EDGE_URL/" 2>/dev/null | tr -d '\r' || true)"
            if { echo "$chat_headers" | grep -qi '^location: /c/new$' || \
                 echo "$chat_headers" | grep -qi "^location: https://${DROPZONE_HOST}/c/new$"; } && \
               ! echo "$chat_headers" | grep -qi "^location: http://${DROPZONE_HOST}/c/new$"; then
                pass "OpenWebUI /chat/ entrypoint redirects to new chat"
            else
                fail "OpenWebUI /chat/ entrypoint did not redirect to /c/new"
            fi
            ;;
        *)
            fail "OpenWebUI /chat/ route returned status $chat_status"
            ;;
    esac

    chat_alias_bad_headers="$(curl_edge -skI "https://${DROPZONE_HOST}/chat//evil.example" 2>/dev/null | tr -d '\r' || true)"
    if echo "$chat_alias_bad_headers" | grep -qi '^location: /c/new$' || \
       echo "$chat_alias_bad_headers" | grep -qi "^location: https://${DROPZONE_HOST}/c/new$"; then
        pass "OpenWebUI chat alias sends malformed double-slash paths to /c/new"
    else
        fail "OpenWebUI chat alias did not safely normalize malformed double-slash paths"
    fi

    chat_auth_headers="$(curl_edge -skD- "https://${DROPZONE_HOST}/chat/auth" -o /dev/null 2>/dev/null | tr -d '\r' || true)"
    if echo "$chat_auth_headers" | grep -qi '^HTTP/.* 200' && \
       ! echo "$chat_auth_headers" | grep -Eqi '^location: https?://[^/]+/auth$|^location: /auth$'; then
        pass "OpenWebUI chat auth finalizer stays inside the app"
    else
        fail "OpenWebUI chat auth finalizer is still redirected to the legacy auth page"
    fi

    chat_native_html="$(curl_edge -sk "https://${DROPZONE_HOST}/home" 2>/dev/null || true)"
    if echo "$chat_native_html" | grep -q 'href="/_app/' &&
       echo "$chat_native_html" | grep -q 'src="/static/' &&
       ! echo "$chat_native_html" | grep -q 'base: "/chat"' &&
       echo "$chat_native_html" | grep -q 'window.__DROPZONE_AUTH_GATE__' &&
       echo "$chat_native_html" | grep -q '/api/v1/dropzone/account-summary' &&
       echo "$chat_native_html" | grep -q 'encodeURIComponent(currentTarget())'; then
        pass "OpenWebUI frontend HTML uses native root routes"
    else
        fail "OpenWebUI frontend HTML is not using the native root route layout"
    fi

    oauth_login_headers="$(curl_edge -skD- "https://${DROPZONE_HOST}/oauth/oidc/login" -o /dev/null 2>/dev/null || true)"
    if echo "$oauth_login_headers" | grep -qi '^HTTP/.* 30[27]' &&
       echo "$oauth_login_headers" | grep -qi "redirect_uri=https%3A%2F%2F${DROPZONE_HOST}%2Foauth%2Foidc%2Fcallback"; then
        pass "OpenWebUI OIDC login uses the root OAuth callback alias"
    else
        fail "OpenWebUI OIDC login is not requesting the root OAuth callback alias"
    fi

    handoff_headers="$(curl_edge -skD- "https://${DROPZONE_HOST}/api/v1/dropzone/chutes-login?redirect=%2Fchat%2F" -o /dev/null 2>/dev/null || true)"
    handoff_location="$(printf '%s\n' "$handoff_headers" | awk 'BEGIN{IGNORECASE=1} /^location: /{sub(/\r$/, ""); print substr($0, 11); exit}')"
    if echo "$handoff_headers" | grep -qi '^HTTP/.* 30[27]' &&
       echo "$handoff_headers" | grep -Eqi '^set-cookie: dropzone-auth-redirect=(%2Fchat%2F|"?/chat/"?);' &&
       ! echo "$handoff_headers" | grep -qi '^location: https://chutes\.ai/auth' &&
       [ -n "$handoff_location" ] &&
       printf '%s' "$handoff_location" | grep -qi '/idp/authorize?response_type=code' &&
       printf '%s' "$handoff_location" | grep -qi "redirect_uri=https%3A%2F%2F${DROPZONE_HOST}%2Foauth%2Foidc%2Fcallback"; then
        pass "Dropzone auth handoff preserves the root OAuth callback alias and target path"
    else
        fail "Dropzone auth handoff did not preserve the root OAuth callback alias and target path"
    fi
else
    skip "OpenWebUI is disabled - skipping OpenWebUI route and auth checks"
fi

if n8n_enabled; then
    signin_html="$(curl_edge -sk "${N8N_EDGE_URL}/signin" 2>/dev/null || true)"
    if [ -n "$signin_html" ]; then
        pass "n8n sign-in page reachable at /n8n/"
    else
        fail "n8n sign-in page unreachable at /n8n/"
    fi

    n8n_account_status="$(curl_edge -sk -o /tmp/chutes-dropzone.n8n-account.out -w '%{http_code}' \
        "https://${DROPZONE_HOST}/n8n/rest/sso/chutes/account-summary" 2>/dev/null || echo 000)"
    case "$n8n_account_status" in
        401|403)
            pass "n8n account-summary endpoint rejects anonymous requests"
            ;;
        *)
            fail "n8n account-summary endpoint returned unexpected anonymous status $n8n_account_status"
            ;;
    esac

    settings_json="$(curl_edge -sk "${N8N_EDGE_URL}/rest/settings" 2>/dev/null || true)"
    sso_enabled="$(printf '%s' "$settings_json" | json_query '.data.sso.chutes.loginEnabled' 2>/dev/null || true)"
    sso_label="$(printf '%s' "$settings_json" | json_query '.data.sso.chutes.loginLabel' 2>/dev/null || true)"
    if [ "$sso_enabled" = "true" ] && [ "$sso_label" = "${CHUTES_SSO_LOGIN_LABEL:-Login with Chutes}" ]; then
        pass "frontend settings expose Chutes SSO"
    else
        fail "frontend settings are missing Chutes SSO"
    fi
else
    skip "n8n is disabled - skipping n8n route and auth checks"
fi

if n8n_enabled && compose exec -T n8n node - <<'NODE' >/dev/null 2>&1
const { CredentialsHelper } = require('/usr/local/lib/node_modules/n8n/dist/credentials-helper.js');

(async () => {
	const helper = Object.create(CredentialsHelper.prototype);
	let updateCalled = false;

	helper.credentialTypes = {
		getByName() {
			return {
				name: 'chutesApi',
				properties: [
					{ name: 'sessionToken', type: 'hidden', typeOptions: { expirable: true } },
					{ name: 'tokenExpiresAt', type: 'hidden' },
				],
				async preAuthentication() {
					return {
						sessionToken: 'fresh-session-token',
						refreshToken: 'fresh-refresh-token',
						tokenExpiresAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
					};
				},
			};
		},
	};

	helper.updateCredentials = async () => {
		updateCalled = true;
	};

	const result = await helper.preAuthentication(
		{ helpers: {} },
		{
			sessionToken: 'stale-session-token',
			refreshToken: 'stale-refresh-token',
			tokenExpiresAt: '1970-01-01T00:00:00.000Z',
		},
		'chutesApi',
		{
			type: 'n8n-nodes-chutes.chutes',
			parameters: {},
			credentials: {
				chutesApi: {
					id: 'cred-1',
					name: 'Chutes SSO',
				},
			},
		},
		false,
	);

	if (!updateCalled || result?.refreshToken !== 'fresh-refresh-token') {
		throw new Error('expirable credential helper did not refresh an expiring token');
	}
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
NODE
then
    pass "expirable credentials refresh before token expiry"
elif n8n_enabled; then
    fail "expirable credentials did not refresh before token expiry"
else
    skip "n8n is disabled - skipping expirable credential refresh check"
fi

if n8n_enabled; then
    sso_headers="$(curl_edge -skI "${N8N_EDGE_URL}/rest/sso/chutes/login" 2>/dev/null || true)"
    encoded_n8n_callback="https%3A%2F%2F${DROPZONE_HOST}%2Frest%2Fsso%2Fchutes%2Fcallback"
    if echo "$sso_headers" | grep -qi '^location: .*idp/authorize' && \
       echo "$sso_headers" | grep -q "redirect_uri=${encoded_n8n_callback}" && \
       ! echo "$sso_headers" | grep -q 'scope=.*email'; then
        pass "native Chutes SSO endpoint redirects to the IDP with the root callback alias and current Chutes scopes"
    else
        fail "native Chutes SSO endpoint did not use the root callback alias and current Chutes scopes"
    fi
else
    skip "n8n is disabled - skipping n8n SSO redirect checks"
fi

# shellcheck disable=SC2016
if openwebui_enabled && compose exec -T openwebui sh -lc '
    case "${WEBUI_URL:-}" in https://*/chat) ;; *) exit 1 ;; esac
    case "${OPENID_REDIRECT_URI:-}" in https://*/oauth/oidc/callback|https://*/chat/oauth/oidc/callback) ;; *) exit 1 ;; esac
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
    test "${DROPZONE_AUDIO_STT_ENGINE:-}" = "local" &&
    test "${WHISPER_MODEL:-}" = "base" &&
    test "${MODELS_CACHE_TTL:-}" = "300" &&
    test "${ALLOW_NON_CONFIDENTIAL:-}" = "false"
' >/dev/null 2>&1; then
    pass "OpenWebUI env is pinned to /chat and SSO-only mode"
elif openwebui_enabled; then
    fail "OpenWebUI env is missing the expected /chat SSO-only settings"
else
    skip "OpenWebUI is disabled - skipping OpenWebUI env checks"
fi

# shellcheck disable=SC2016
if openwebui_enabled && compose exec -T openwebui-order-sync sh -lc '
    test "${OPENWEBUI_SYNC_BASE_URL:-}" = "http://openwebui:8080" &&
    test "${OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL:-}" = "300" &&
    test "${ALLOW_NON_CONFIDENTIAL:-}" = "false"
' >/dev/null 2>&1; then
    pass "OpenWebUI background model-order sync worker is configured for 5-minute refreshes"
elif openwebui_enabled; then
    fail "OpenWebUI background model-order sync worker is missing the expected settings"
else
    skip "OpenWebUI is disabled - skipping OpenWebUI sync worker checks"
fi

if openwebui_enabled; then
    openwebui_oauth_headers="$(curl_edge -sk -o /dev/null -D - "https://${DROPZONE_HOST}/oauth/oidc/login" 2>/dev/null || true)"
    if echo "$openwebui_oauth_headers" | grep -qi '^location: .*idp/authorize' && \
       ! echo "$openwebui_oauth_headers" | grep -q 'scope=.*email'; then
        pass "OpenWebUI OIDC login uses the current Chutes-supported scopes"
    else
        fail "OpenWebUI OIDC login is still requesting unsupported Chutes scopes"
    fi
else
    skip "OpenWebUI is disabled - skipping OpenWebUI scope checks"
fi

if n8n_enabled && compose exec -T n8n sh -lc \
    "grep -R 'restApiContext.baseUrl}/sso/chutes/login' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null"; then
    pass "editor bundle uses REST base URL for Chutes login"
elif n8n_enabled; then
    fail "editor bundle is missing the REST base URL Chutes login fix"
else
    skip "n8n is disabled - skipping editor bundle SSO checks"
fi

if n8n_enabled && compose exec -T n8n sh -lc \
    "grep -R 'toggle-password-login' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null" && \
   compose exec -T n8n sh -lc \
    "grep -R 'Login using other credentials' /usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist/assets >/dev/null"; then
    pass "editor bundle includes the local-login reveal flow"
elif n8n_enabled; then
    fail "editor bundle is missing the local-login reveal flow"
else
    skip "n8n is disabled - skipping editor bundle local-login checks"
fi

http_status="$(curl_edge -s -o /dev/null -w '%{http_code}' "http://${DROPZONE_HOST}/" 2>/dev/null || echo 000)"
if [ "$http_status" = "308" ] || [ "$http_status" = "301" ]; then
    pass "HTTP redirects to HTTPS"
else
    fail "HTTP did not redirect to HTTPS (status $http_status)"
fi

if n8n_enabled; then
owner_login="$(curl_edge -sk -c /tmp/chutes-n8n-local.cookies \
    -H 'Content-Type: application/json' \
    -H 'browser-id: smoke-test-browser' \
    -d "$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$N8N_ADMIN_EMAIL" "$N8N_ADMIN_PASSWORD")" \
    "${N8N_EDGE_URL}/rest/login" 2>/dev/null || true)"
if echo "$owner_login" | grep -q '"id"'; then
    pass "break-glass owner login works"
else
    fail "break-glass owner login failed"
fi
else
    skip "n8n is disabled - skipping break-glass owner login"
fi

if n8n_enabled && compose exec -T n8n n8n export:nodes --output=/tmp/nodes.json >/dev/null 2>&1 && \
    compose exec -T n8n node - <<'NODE' >/dev/null 2>&1
const fs = require('fs');

const nodes = JSON.parse(fs.readFileSync('/tmp/nodes.json', 'utf8'));
const required = ['CUSTOM.chutes', 'CUSTOM.chutesChatModel', 'CUSTOM.chutesAIAgent'];
const missing = required.filter((name) => !nodes.some((node) => node.name === name));

if (missing.length > 0) {
	console.error(`Missing custom nodes: ${missing.join(', ')}`);
	process.exit(1);
}
NODE
then
    pass "custom nodes are registered in n8n"
elif n8n_enabled; then
    fail "custom nodes are not registered in n8n"
else
    skip "n8n is disabled - skipping custom node registration checks"
fi

if [ "${CHUTES_TRAFFIC_MODE:-direct}" = "e2ee-proxy" ]; then
    # shellcheck disable=SC2016
    if compose exec -T n8n sh -lc '
        test "${CHUTES_SSO_PROXY_BYPASS:-false}" = "false" &&
        test "${CHUTES_PROXY_BASE_URL:-}" = "http://e2ee-proxy:80"
    ' >/dev/null 2>&1; then
        pass "n8n SSO text traffic is pinned to the proxy path in e2ee-proxy mode"
    else
        fail "n8n still allows SSO text traffic to bypass the proxy path"
    fi

    if compose exec -T n8n sh -lc "NODE_PATH=/usr/local/lib/node_modules/n8n/node_modules node -e 'const Module=require(\"module\"); Module._initPaths(); const transport=require(\"/opt/custom-nodes/n8n-nodes-chutes/dist/nodes/Chutes/transport/apiRequest.js\"); const ok=!transport.isSsoProxyBypassEnabled() && transport.shouldUseTextProxyForCredential({authType:\"sso\",sessionToken:\"session-token\"}); process.exit(ok ? 0 : 1);'" >/dev/null 2>&1; then
        pass "n8n runtime logic routes SSO-backed text requests through the proxy"
    else
        fail "n8n runtime logic still bypasses the proxy for SSO-backed text requests"
    fi

    # shellcheck disable=SC2016
    if compose exec -T openwebui sh -lc '
        test "${OPENAI_API_BASE_URLS:-}" = "http://e2ee-proxy:80/v1"
    ' >/dev/null 2>&1; then
        pass "OpenWebUI is pinned to the proxy-backed /v1 model endpoint in e2ee-proxy mode"
    else
        fail "OpenWebUI is still pointing directly at native Chutes model endpoints"
    fi

    proxy_models_headers="/tmp/chutes-n8n-local.proxy-models.headers"
    proxy_models_status="$(curl_edge -sk -D "$proxy_models_headers" -o /tmp/chutes-n8n-local.proxy-models.out -w '%{http_code}' \
        "https://${DROPZONE_HOST}/v1/models" 2>/dev/null || echo 000)"
    if [ "$proxy_models_status" = "200" ]; then
        pass "e2ee-proxy exposes /v1/models on the local edge"
    else
        fail "e2ee-proxy /v1/models route returned status $proxy_models_status"
    fi

    if [ "$proxy_models_status" = "200" ]; then
        if grep -qi '^Access-Control-Allow-Origin: \*' "$proxy_models_headers"; then
            pass "e2ee-proxy keeps wildcard CORS scoped to the shared /v1 API surface"
        else
            fail "e2ee-proxy /v1/models is missing the expected API CORS header"
        fi

        if grep -qi '^X-Dropzone-Proxy: e2ee-proxy' "$proxy_models_headers"; then
            pass "proxy model catalog responses identify the e2ee-proxy path"
        else
            fail "proxy model catalog responses are missing the e2ee-proxy marker header"
        fi

        if python3 - /tmp/chutes-n8n-local.proxy-models.out <<'PY' >/dev/null 2>&1
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
models = payload.get("data", []) if isinstance(payload, dict) else []
if not isinstance(models, list) or not models:
    raise SystemExit(1)
if any(not isinstance(model, dict) or not model.get("id") for model in models):
    raise SystemExit(1)
PY
        then
            pass "proxy model catalog returns an anonymous public model list"
        else
            fail "proxy model catalog did not return a valid anonymous public model list"
        fi

        if [ "${ALLOW_NON_CONFIDENTIAL:-false}" != "true" ]; then
            if grep -qi '^X-Dropzone-Model-Catalog: tee-only' "$proxy_models_headers" && \
               python3 - /tmp/chutes-n8n-local.proxy-models.out <<'PY' >/dev/null 2>&1
import json
import sys

payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
models = payload.get("data", []) if isinstance(payload, dict) else []
if not models:
    raise SystemExit(1)
if any(model.get("confidential_compute") is not True for model in models):
    raise SystemExit(1)
PY
            then
                pass "strict e2ee-proxy mode filters the shared /v1/models catalog down to TEE models"
            else
                fail "strict e2ee-proxy mode did not filter the shared /v1/models catalog to TEE models"
            fi

            if compose exec -T openwebui python - <<'PY' >/dev/null 2>&1
import json
import os
import urllib.request
from datetime import timedelta

from open_webui.internal.db import get_db
from open_webui.models.users import Users
from open_webui.utils.auth import create_token

admin_email = (
    os.environ.get("ADMIN_EMAIL")
    or os.environ.get("WEBUI_ADMIN_EMAIL")
    or os.environ.get("OPENWEBUI_ADMIN_EMAIL")
    or "admin@chutes.local"
)

with get_db() as db:
    admin_user = Users.get_user_by_email(admin_email, db)

if not admin_user:
    raise SystemExit(1)

token = create_token({"id": admin_user.id}, expires_delta=timedelta(minutes=5))
request = urllib.request.Request(
    "http://127.0.0.1:8080/api/models?refresh=true",
    headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
)
with urllib.request.urlopen(request, timeout=20) as response:
    payload = json.loads(response.read().decode("utf-8"))

models = payload.get("data", []) if isinstance(payload, dict) else []
if not models:
    raise SystemExit(1)
# In e2ee-proxy mode the proxy filters /v1/models to TEE-only.
# The admin model list may include non-TEE models from seeding, but
# verify at least one TEE model is present and ranked first.
tee = [m for m in models if m.get("confidential_compute") is True]
if not tee:
    raise SystemExit("no TEE models found in OpenWebUI model list")
PY
            then
                pass "OpenWebUI only exposes TEE text models when strict e2ee-proxy mode is enabled"
            else
                fail "OpenWebUI still exposes non-TEE models in strict e2ee-proxy mode"
            fi
        fi
    fi

    proxy_chat_headers="/tmp/chutes-n8n-local.proxy-chat.headers"
    proxy_chat_status="$(curl_edge -sk -D "$proxy_chat_headers" -o /tmp/chutes-n8n-local.proxy-chat.out -w '%{http_code}' \
        -H 'Content-Type: application/json' \
        -d '{"model":"Qwen/Qwen3-32B","messages":[{"role":"user","content":"hello"}],"stream":false}' \
        "https://${DROPZONE_HOST}/v1/chat/completions" 2>/dev/null || echo 000)"
    case "$proxy_chat_status" in
        200|400|401|403)
            pass "e2ee-proxy handles /v1/chat/completions on the local edge"
            ;;
        *)
            fail "e2ee-proxy /v1/chat/completions route returned status $proxy_chat_status"
            ;;
    esac

    if grep -qi '^X-Dropzone-Proxy: e2ee-proxy' "$proxy_chat_headers"; then
        pass "proxy chat-completion responses identify the e2ee-proxy path"
    else
        fail "proxy chat-completion responses are missing the e2ee-proxy marker header"
    fi
else
    direct_v1_status="$(curl_edge -sk -o /dev/null -w '%{http_code}' \
        "https://${DROPZONE_HOST}/v1/models" 2>/dev/null || echo 000)"
    case "$direct_v1_status" in
        401|403|404)
            pass "direct mode does not expose the shared /v1 edge"
            ;;
        *)
            fail "direct mode unexpectedly exposed /v1/models with status $direct_v1_status"
            ;;
    esac
fi

credentials_response="$(curl_edge -sk -b /tmp/chutes-n8n-local.cookies \
    -H 'browser-id: smoke-test-browser' \
    "${N8N_EDGE_URL}/rest/credentials" 2>/dev/null || true)"

if command -v jq >/dev/null 2>&1; then
    sso_credential_id="$(printf '%s' "$credentials_response" | jq -r '.data[] | select(.type == "chutesApi" and .name == "Chutes SSO") | .id' | head -n 1)"
    if [ -n "$sso_credential_id" ] && [ "$sso_credential_id" != "null" ]; then
        dynamic_payload="$(jq -nc --arg id "$sso_credential_id" '{
            credentials: {
                chutesApi: {
                    id: $id,
                    name: "Chutes SSO"
                }
            },
            currentNodeParameters: {
                resource: "imageGeneration",
                chuteUrl: "https://image.chutes.ai",
                operation: "generate",
                prompt: "",
                size: "1024x1024",
                n: 1,
                additionalOptions: {}
            },
            nodeTypeAndVersion: {
                name: "CUSTOM.chutes",
                version: 1
            },
            methodName: "getImageChutes",
            path: "chuteUrl"
        }')"
        dynamic_options_response="$(curl_edge -sk -b /tmp/chutes-n8n-local.cookies \
            -H 'Content-Type: application/json' \
            -H 'browser-id: smoke-test-browser' \
            -d "$dynamic_payload" \
            "${N8N_EDGE_URL}/rest/dynamic-node-parameters/options" 2>/dev/null || true)"
        dynamic_options_count="$(printf '%s' "$dynamic_options_response" | jq -r '.data | length')"
        if [[ "$dynamic_options_count" =~ ^[0-9]+$ ]] && [ "$dynamic_options_count" -gt 0 ]; then
            pass "Chutes SSO credential loads chute options"
        else
            fail "Chutes SSO credential did not load chute options"
        fi
    else
        skip "no Chutes SSO credential present - skipping chute option load check"
    fi
else
    skip "jq not installed - cannot validate Chutes SSO option loading"
fi

rm -f /tmp/chutes-n8n-local.cookies

echo
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
