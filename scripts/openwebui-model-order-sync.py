#!/usr/bin/env python3
#
# Synchronize OpenWebUI upstream auth config, model ordering, and provider logos.
#
import argparse
import functools
import json
import os
import re
import urllib.error
import urllib.request
from datetime import timedelta

from open_webui.internal.db import get_db
from open_webui.models.users import Users
from open_webui.utils.auth import create_token


PROVIDER_LOGOS: dict[str, str] = {
    "deepseek": "https://cdn.rayonlabs.ai/chutes/logos/deepseeknew.webp",
    "kimi": "https://cdn.rayonlabs.ai/chutes/logos/kimik2-icon.webp",
    "microsoft": "https://cdn.rayonlabs.ai/chutes/logos/phi.webp",
    "mistral": "https://cdn.rayonlabs.ai/chutes/logos/mistral.webp",
    "openai": "https://cdn.rayonlabs.ai/chutes/logos/openailogo.webp",
    "qwen": "https://cdn.rayonlabs.ai/chutes/logos/qwen.webp",
    "gemma": "https://cdn.rayonlabs.ai/chutes/logos/gemma.webp",
    "meta": "https://cdn.rayonlabs.ai/chutes/logos/metaai.webp",
    "zai": "https://cdn.rayonlabs.ai/chutes/logos/zai.webp",
}

CHUTES_LOGO_URL = "/static/chutes-logo.svg"
AUTO_MODEL_DESCRIPTION = "Best available model."
DEFAULT_IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE = (
    'You turn recent chat context into one high-quality prompt for image generation. '
    "Infer the user's intended subject, setting, composition, lighting, perspective, medium, "
    "materials, color palette, mood, and any explicit constraints from the conversation. "
    "If the request is brief, add sensible visual detail without changing the core idea. "
    "Stay faithful to what the user wants, do not invent named entities or unsafe details they did not request, "
    'and output strict JSON only: {"prompt":"..."}. '
    "Chat history: <chat_history>{{MESSAGES:END:8}}</chat_history>"
)

HF_AVATAR_RE = re.compile(
    r"https://cdn-avatars\.huggingface\.co/v1/production/uploads/[a-f0-9]+/[A-Za-z0-9_-]+\.\w+"
)
HF_AVATAR_CACHE_PATH = os.environ.get(
    "HF_AVATAR_CACHE", "/tmp/chutes-hf-avatar-cache.json"
)

_hf_cache: dict[str, str] | None = None


def _load_hf_cache() -> dict[str, str]:
    global _hf_cache
    if _hf_cache is not None:
        return _hf_cache
    try:
        with open(HF_AVATAR_CACHE_PATH, "r") as f:
            _hf_cache = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        _hf_cache = {}
    return _hf_cache


def _save_hf_cache(cache: dict[str, str]) -> None:
    try:
        with open(HF_AVATAR_CACHE_PATH, "w") as f:
            json.dump(cache, f)
    except OSError:
        pass


def fetch_hf_avatar(org: str) -> str:
    """Fetch the org avatar from HuggingFace. Returns URL or empty string."""
    cache = _load_hf_cache()
    if org in cache:
        return cache[org]

    try:
        req = urllib.request.Request(
            f"https://huggingface.co/{org}",
            headers={"User-Agent": "chutes-dropzone/1.0"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            html = resp.read().decode("utf-8", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError):
        cache[org] = ""
        _save_hf_cache(cache)
        return ""

    match = HF_AVATAR_RE.search(html)
    url = match.group(0) if match else ""
    cache[org] = url
    _save_hf_cache(cache)
    return url


def logo_url_for_model(model_id: str) -> str:
    """Return the provider logo URL for a model id, or the Chutes fallback."""
    value = model_id.lower()
    if "deepseek" in value:
        return PROVIDER_LOGOS["deepseek"]
    if "kimi" in value:
        return PROVIDER_LOGOS["kimi"]
    if "mistral" in value:
        return PROVIDER_LOGOS["mistral"]
    if "qwen" in value or "qwq" in value or "/wan" in value:
        return PROVIDER_LOGOS["qwen"]
    if "openai" in value or "gpt-oss" in value:
        return PROVIDER_LOGOS["openai"]
    if "microsoft" in value or "/phi" in value:
        return PROVIDER_LOGOS["microsoft"]
    if "gemma" in value:
        return PROVIDER_LOGOS["gemma"]
    if ("llama" in value or "meta" in value) and "nemotron" not in value:
        return PROVIDER_LOGOS["meta"]
    if "glm" in value or "zai-org" in value or "zai/" in value:
        return PROVIDER_LOGOS["zai"]
    if "/" in value:
        org = value.split("/", 1)[0]
        hf_avatar = fetch_hf_avatar(org)
        if hf_avatar:
            return hf_avatar
        return CHUTES_LOGO_URL
    return ""


TOKEN_RE = re.compile(r"[A-Za-z0-9.]+")
NUMBER_RE = re.compile(r"\d+(?:\.\d+)?")
ALPHA_PREFIX_RE = re.compile(r"^[A-Za-z]+")
ALPHA_RE = re.compile(r"[A-Za-z]+")
SIZE_SEGMENT_RE = re.compile(r"^(?:A)?\d+(?:\.\d+)?[KMB]$", re.IGNORECASE)
GENERIC_PREFIXES = {"a", "b", "m", "r", "v"}


def base_url() -> str:
    return os.environ.get("OPENWEBUI_SYNC_BASE_URL", "http://127.0.0.1:8080").rstrip("/")


def auto_model_refresh_interval_seconds() -> int:
    for env_name in ("OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL", "MODELS_CACHE_TTL"):
        raw = (os.environ.get(env_name) or "").strip()
        if not raw:
            continue
        try:
            value = int(raw)
        except ValueError:
            continue
        if value >= 0:
            return value
    return 300


def format_refresh_interval(seconds: int) -> str:
    if seconds <= 0:
        return "on demand"
    if seconds % 3600 == 0:
        amount = seconds // 3600
        unit = "hour"
    elif seconds % 60 == 0:
        amount = seconds // 60
        unit = "minute"
    else:
        amount = seconds
        unit = "second"
    suffix = "" if amount == 1 else "s"
    return f"{amount} {unit}{suffix}"


def friendly_auto_model_name(model_id: str) -> str:
    label = model_slug(model_id)
    label = label.split(":", 1)[0]
    label = re.sub(r"-TEE\b", "", label, flags=re.IGNORECASE)
    label = label.strip(" -")
    return label or model_id


def admin_email() -> str:
    return (
        os.environ.get("ADMIN_EMAIL")
        or os.environ.get("WEBUI_ADMIN_EMAIL")
        or os.environ.get("OPENWEBUI_ADMIN_EMAIL")
        or "admin@chutes.local"
    )


def lab_name(model_id: str) -> str:
    if "/" in model_id:
        return model_id.split("/", 1)[0]
    if ":" in model_id:
        return model_id.split(":", 1)[0]
    if "-" in model_id:
        return model_id.split("-", 1)[0]
    return model_id


def model_slug(model_id: str) -> str:
    if "/" in model_id:
        return model_id.split("/", 1)[1]
    if ":" in model_id:
        return model_id.split(":", 1)[1]
    return model_id


def is_tee_model(model_id: str) -> bool:
    upper_id = model_id.upper()
    return upper_id.endswith("-TEE") or "-TEE-" in upper_id


def parse_number(raw: str):
    if "." in raw:
        return float(raw)
    return int(raw.lstrip("0") or "0")


def compare_desc(left, right) -> int:
    for left_item, right_item in zip(left, right):
        if left_item == right_item:
            continue
        if isinstance(left_item, str) and isinstance(right_item, str):
            return -1 if left_item > right_item else 1
        if not isinstance(left_item, str) and not isinstance(right_item, str):
            return -1 if left_item > right_item else 1
        return -1 if not isinstance(left_item, str) else 1
    if len(left) != len(right):
        return -1 if len(left) > len(right) else 1
    return 0


@functools.lru_cache(maxsize=None)
def analyze_model(model_id: str) -> dict:
    slug = model_slug(model_id)
    family_parts = []
    release_markers = []
    version_markers = []
    fallback_tokens = []
    family_locked = False

    for segment in TOKEN_RE.findall(slug):
        if not segment:
            continue

        upper_segment = segment.upper()
        if upper_segment == "TEE":
            continue
        if SIZE_SEGMENT_RE.match(segment):
            fallback_tokens.extend(parse_number(raw) for raw in NUMBER_RE.findall(segment))
            continue

        prefix_match = ALPHA_PREFIX_RE.match(segment)
        prefix = prefix_match.group(0).lower() if prefix_match else ""
        if prefix and not family_locked:
            if not family_parts or prefix not in GENERIC_PREFIXES:
                family_parts.append(prefix)

        numeric_tokens = NUMBER_RE.findall(segment)
        if numeric_tokens:
            family_locked = True
            for raw in numeric_tokens:
                parsed = parse_number(raw)
                fallback_tokens.append(parsed)
                if raw.isdigit() and len(raw) >= 4:
                    release_markers.append(parsed)
                elif isinstance(parsed, int) and parsed >= 100:
                    release_markers.append(parsed)
                else:
                    version_markers.append(parsed)

            remainder = segment[prefix_match.end() :] if prefix_match else segment
            remainder = NUMBER_RE.sub(" ", remainder)
            fallback_tokens.extend(token.lower() for token in ALPHA_RE.findall(remainder))
            continue

        text_tokens = [token.lower() for token in ALPHA_RE.findall(segment) if token]
        if text_tokens:
            if not family_locked and not family_parts:
                family_parts.extend(text_tokens)
            fallback_tokens.extend(text_tokens)

    return {
        "model_id": model_id,
        "lab": lab_name(model_id).lower(),
        "tee_rank": 0 if is_tee_model(model_id) else 1,
        "family": tuple(family_parts) if family_parts else ("zzz",),
        "release_markers": tuple(release_markers),
        "version_markers": tuple(version_markers),
        "fallback_tokens": tuple(fallback_tokens) if fallback_tokens else (slug.lower(),),
    }


def compare_models(left: dict, right: dict) -> int:
    left_id = left.get("id") or left.get("name") or ""
    right_id = right.get("id") or right.get("name") or ""
    left_meta = analyze_model(left_id)
    right_meta = analyze_model(right_id)

    if left_meta["tee_rank"] != right_meta["tee_rank"]:
        return -1 if left_meta["tee_rank"] < right_meta["tee_rank"] else 1
    if left_meta["lab"] != right_meta["lab"]:
        return -1 if left_meta["lab"] < right_meta["lab"] else 1
    if bool(left_meta["release_markers"]) != bool(right_meta["release_markers"]):
        return -1 if left_meta["release_markers"] else 1

    for key in ("release_markers", "version_markers"):
        comparison = compare_desc(left_meta[key], right_meta[key])
        if comparison:
            return comparison

    if left_meta["family"] != right_meta["family"]:
        return -1 if left_meta["family"] < right_meta["family"] else 1

    comparison = compare_desc(left_meta["fallback_tokens"], right_meta["fallback_tokens"])
    if comparison:
        return comparison

    if left_id.lower() != right_id.lower():
        return -1 if left_id.lower() > right_id.lower() else 1
    return 0


def request_json(method: str, path: str, token: str, payload=None):
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
    }
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        f"{base_url()}{path}",
        data=data,
        headers=headers,
        method=method,
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def public_models_url() -> str:
    return os.environ.get("CHUTES_PUBLIC_MODELS_URL", "https://llm.chutes.ai/v1/models").rstrip("/")


def utilization_url() -> str:
    return os.environ.get(
        "CHUTES_UTILIZATION_URL", "https://api.chutes.ai/chutes/utilization"
    ).rstrip("/")


def fetch_utilization() -> list[dict]:
    request = urllib.request.Request(
        utilization_url(),
        headers={"Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError):
        return []
    return payload if isinstance(payload, list) else []


def rank_models_by_capacity(available_model_ids: set[str]) -> list[str]:
    """Rank models by available capacity from utilization data.

    Score = active_instance_count * (1 - utilization_5m)
    Highest score means most headroom to serve requests.
    """
    utilization = fetch_utilization()
    if not utilization:
        return []

    scored = []
    for entry in utilization:
        name = entry.get("name", "")
        if name not in available_model_ids:
            continue
        instances = entry.get("active_instance_count", 0)
        if instances <= 0:
            continue
        util_5m = entry.get("utilization_5m", 1.0)
        score = instances * (1.0 - util_5m)
        scored.append((score, name))

    scored.sort(reverse=True)
    return [name for _, name in scored]


def fetch_public_models() -> tuple[list[dict], bool]:
    request = urllib.request.Request(
        public_models_url(),
        headers={
            "Accept": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, ValueError):
        return [], False

    models = payload.get("data", []) if isinstance(payload, dict) else payload
    if not isinstance(models, list) or not models:
        return [], False

    collected_models = []
    seen_ids = set()
    for model in models:
        if not isinstance(model, dict):
            continue
        model_id = model.get("id") or model.get("name")
        if not model_id or model_id in seen_ids:
            continue
        seen_ids.add(model_id)
        collected_models.append(model)

    return collected_models, bool(collected_models)


def admin_token() -> str:
    with get_db() as db:
        admin_user = Users.get_user_by_email(admin_email(), db)

    if not admin_user or admin_user.role != "admin":
        raise SystemExit(f"could not locate OpenWebUI admin user for {admin_email()}")

    return create_token({"id": admin_user.id}, expires_delta=timedelta(minutes=10))


def admin_allowlist() -> list[str]:
    """Parse CHUTES_ADMIN_USERNAMES into a lowercase list of usernames."""
    raw = os.environ.get("CHUTES_ADMIN_USERNAMES", "")
    return [u.strip().lower() for u in raw.split(",") if u.strip()]


def desired_stt_engine_mode() -> str:
    raw = (
        os.environ.get("DROPZONE_AUDIO_STT_ENGINE")
        or os.environ.get("AUDIO_STT_ENGINE")
        or "local"
    ).strip().lower()
    if raw in {"local", "web", "openai"}:
        return raw
    if raw == "":
        return "local"
    return "local"


def desired_local_whisper_model() -> str:
    return (
        os.environ.get("DROPZONE_AUDIO_STT_LOCAL_MODEL")
        or os.environ.get("WHISPER_MODEL")
        or "base"
    ).strip() or "base"


def desired_image_generation_enabled() -> bool:
    return (os.environ.get("ENABLE_IMAGE_GENERATION") or "true").strip().lower() == "true"


def desired_image_prompt_generation_enabled() -> bool:
    return (
        os.environ.get("ENABLE_IMAGE_PROMPT_GENERATION") or "true"
    ).strip().lower() == "true"


def desired_image_generation_engine() -> str:
    return (os.environ.get("IMAGE_GENERATION_ENGINE") or "openai").strip() or "openai"


def desired_image_generation_model() -> str:
    return (
        os.environ.get("IMAGE_GENERATION_MODEL")
        or "chutes-auto-image"
    ).strip() or "chutes-auto-image"


def desired_task_model() -> str:
    return (os.environ.get("TASK_MODEL") or "").strip()


def desired_task_model_external() -> str:
    return (os.environ.get("TASK_MODEL_EXTERNAL") or "").strip()


def desired_image_prompt_generation_prompt_template() -> str:
    return (
        os.environ.get("IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE")
        or DEFAULT_IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE
    ).strip() or DEFAULT_IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE


def desired_images_openai_api_base_url() -> str:
    explicit = (os.environ.get("IMAGES_OPENAI_API_BASE_URL") or "").strip()
    if explicit:
        return explicit

    traffic_mode = (os.environ.get("CHUTES_TRAFFIC_MODE") or "direct").strip().lower()
    if traffic_mode == "e2ee-proxy":
        proxy = (os.environ.get("CHUTES_PROXY_INTERNAL_URL") or "").strip().rstrip("/")
        if proxy:
            return f"{proxy}/v1"

    return (
        os.environ.get("OPENWEBUI_API_BASE_URL")
        or "https://llm.chutes.ai/v1"
    ).strip()


def desired_images_openai_api_key() -> str:
    return (
        os.environ.get("IMAGES_OPENAI_API_KEY")
        or os.environ.get("OPENWEBUI_API_KEY")
        or ""
    ).strip()


def sync_audio_config(token: str) -> bool:
    """Keep OpenWebUI audio STT config aligned with the Dropzone deployment mode."""

    audio_config = request_json("GET", "/api/v1/audio/config", token)
    tts = audio_config.get("tts", {}) if isinstance(audio_config, dict) else {}
    stt = audio_config.get("stt", {}) if isinstance(audio_config, dict) else {}
    if not isinstance(tts, dict) or not isinstance(stt, dict):
        return False

    desired_mode = desired_stt_engine_mode()
    desired_engine = "" if desired_mode == "local" else desired_mode
    desired_whisper_model = desired_local_whisper_model()
    desired_remote_model = (os.environ.get("AUDIO_STT_MODEL") or "whisper-large-v3").strip()

    updated_stt = dict(stt)
    updated_stt["ENGINE"] = desired_engine
    updated_stt["WHISPER_MODEL"] = desired_whisper_model
    updated_stt["MODEL"] = desired_remote_model if desired_mode == "openai" else ""

    if (
        stt.get("ENGINE", "") == updated_stt["ENGINE"]
        and stt.get("WHISPER_MODEL", "") == updated_stt["WHISPER_MODEL"]
        and stt.get("MODEL", "") == updated_stt["MODEL"]
    ):
        return False

    request_json(
        "POST",
        "/api/v1/audio/config/update",
        token,
        {"tts": tts, "stt": updated_stt},
    )
    return True


def sync_image_config(token: str) -> bool:
    """Keep OpenWebUI image-generation config aligned with the Dropzone deployment mode."""

    image_config = request_json("GET", "/api/v1/images/config", token)
    if not isinstance(image_config, dict):
        return False

    updated = dict(image_config)
    updated["ENABLE_IMAGE_GENERATION"] = desired_image_generation_enabled()
    updated["ENABLE_IMAGE_PROMPT_GENERATION"] = desired_image_prompt_generation_enabled()
    updated["IMAGE_GENERATION_ENGINE"] = desired_image_generation_engine()
    updated["IMAGE_GENERATION_MODEL"] = desired_image_generation_model()

    desired_base_url = desired_images_openai_api_base_url()
    if desired_base_url:
        updated["IMAGES_OPENAI_API_BASE_URL"] = desired_base_url

    desired_api_key = desired_images_openai_api_key()
    if desired_api_key:
        updated["IMAGES_OPENAI_API_KEY"] = desired_api_key

    changed_keys = []
    for key in (
        "ENABLE_IMAGE_GENERATION",
        "ENABLE_IMAGE_PROMPT_GENERATION",
        "IMAGE_GENERATION_ENGINE",
        "IMAGE_GENERATION_MODEL",
        "IMAGES_OPENAI_API_BASE_URL",
        "IMAGES_OPENAI_API_KEY",
    ):
        if image_config.get(key) != updated.get(key):
            changed_keys.append(key)

    if not changed_keys:
        return False

    request_json("POST", "/api/v1/images/config/update", token, updated)
    return True


def sync_task_config(token: str) -> bool:
    """Keep OpenWebUI task config aligned so the selected chat model rewrites image prompts."""

    task_config = request_json("GET", "/api/v1/tasks/config", token)
    if not isinstance(task_config, dict):
        return False

    updated = dict(task_config)
    updated["TASK_MODEL"] = desired_task_model()
    updated["TASK_MODEL_EXTERNAL"] = desired_task_model_external()
    updated["IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE"] = (
        desired_image_prompt_generation_prompt_template()
    )

    changed_keys = []
    for key in (
        "TASK_MODEL",
        "TASK_MODEL_EXTERNAL",
        "IMAGE_PROMPT_GENERATION_PROMPT_TEMPLATE",
    ):
        current = task_config.get(key)
        if (current or "") != (updated.get(key) or ""):
            changed_keys.append(key)

    if not changed_keys:
        return False

    request_json("POST", "/api/v1/tasks/config/update", token, updated)
    return True


_userinfo_endpoint: str = ""


def _resolve_oidc_username(access_token: str) -> str:
    """Resolve the immutable OIDC username via the IDP userinfo endpoint.

    The userinfo username is authoritative — unlike user.name, which can be
    changed by the user through OpenWebUI's profile settings.
    """
    global _userinfo_endpoint

    if not _userinfo_endpoint:
        idp_base = os.environ.get(
            "CHUTES_IDP_BASE_URL", "https://api.chutes.ai"
        ).rstrip("/")
        try:
            oidc_req = urllib.request.Request(
                f"{idp_base}/.well-known/openid-configuration",
                headers={"Accept": "application/json"},
            )
            with urllib.request.urlopen(oidc_req, timeout=10) as resp:
                config = json.loads(resp.read().decode("utf-8"))
            _userinfo_endpoint = config.get(
                "userinfo_endpoint", f"{idp_base}/idp/userinfo"
            )
        except Exception:
            _userinfo_endpoint = f"{idp_base}/idp/userinfo"

    req = urllib.request.Request(
        _userinfo_endpoint,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        return data.get("username", "")
    except Exception:
        return ""


def sync_admin_roles(token: str) -> int:
    """Promote SSO users whose Chutes OIDC username is in CHUTES_ADMIN_USERNAMES.

    Identity is resolved from the IDP userinfo endpoint using each user's
    stored OAuth access token — NOT from user.name, which OpenWebUI lets
    users change via profile settings.
    """
    allowlist = admin_allowlist()
    if not allowlist:
        return 0

    from open_webui.models.oauth_sessions import OAuthSessions

    promoted = 0
    svc_email = admin_email().lower()

    with get_db() as db:
        result = Users.get_users(db=db)
        user_list = result.get("users", []) if isinstance(result, dict) else result

        for user in user_list:
            if not user:
                continue
            if user.email and user.email.lower() == svc_email:
                continue
            if user.role == "admin":
                continue

            session = OAuthSessions.get_session_by_provider_and_user_id(
                "oidc", user.id, db=db
            )
            if not session or not isinstance(session.token, dict):
                continue
            access_token = session.token.get("access_token", "")
            if not access_token:
                continue

            oidc_username = _resolve_oidc_username(access_token)
            if not oidc_username:
                continue
            if oidc_username.strip().lower() in allowlist:
                try:
                    request_json(
                        "POST",
                        f"/api/v1/users/{user.id}/update",
                        token,
                        {
                            "role": "admin",
                            "name": user.name,
                            "email": user.email,
                            "profile_image_url": user.profile_image_url or "",
                        },
                    )
                    promoted += 1
                    print(f"promoted {oidc_username} to admin")
                except Exception as exc:
                    print(f"warning: admin promotion failed for user {user.id}: {exc}")

    return promoted


def sync_runtime(configure_openai_auth: bool) -> tuple[int, list[str], int, bool]:
    token = admin_token()
    updates = []

    openai_config = request_json("GET", "/openai/config", token)
    api_urls = openai_config.get("OPENAI_API_BASE_URLS", [])
    desired_api_configs = {
        str(index): {"auth_type": "system_oauth"} for index in range(len(api_urls))
    }

    if configure_openai_auth and openai_config.get("OPENAI_API_CONFIGS") != desired_api_configs:
        openai_config["OPENAI_API_CONFIGS"] = desired_api_configs
        request_json("POST", "/openai/config/update", token, openai_config)
        updates.append("OPENAI_API_CONFIGS")

    if sync_audio_config(token):
        updates.append(f"AUDIO_STT({desired_stt_engine_mode()})")

    if sync_image_config(token):
        updates.append("IMAGE_GENERATION")

    if sync_task_config(token):
        updates.append("IMAGE_PROMPT_TASKS")

    models_payload = request_json("GET", "/api/models?refresh=true", token)
    models = models_payload.get("data", []) if isinstance(models_payload, dict) else []
    used_backend_fallback = False
    if not isinstance(models, list) or not models:
        models, used_backend_fallback = fetch_public_models()
    if not isinstance(models, list) or not models:
        raise SystemExit(
            "OpenWebUI model discovery returned no models after runtime configuration"
        )

    ordered_ids = ["chutes-auto"]
    seen_ids = {"chutes-auto"}
    for model in sorted(models, key=functools.cmp_to_key(compare_models)):
        model_id = model.get("id") or model.get("name")
        if model_id and model_id not in seen_ids:
            seen_ids.add(model_id)
            ordered_ids.append(model_id)

    models_config = request_json("GET", "/api/v1/configs/models", token)
    if ordered_ids and models_config.get("MODEL_ORDER_LIST") != ordered_ids:
        models_config["MODEL_ORDER_LIST"] = ordered_ids
        request_json("POST", "/api/v1/configs/models", token, models_config)
        updates.append("MODEL_ORDER_LIST")

    logo_count = sync_model_logos(token, ordered_ids)
    if logo_count:
        updates.append(f"MODEL_LOGOS({logo_count})")

    ranked = rank_models_by_capacity(set(ordered_ids))
    if ranked:
        auto_model_id = "chutes-auto"
        is_proxy = os.environ.get("CHUTES_TRAFFIC_MODE", "direct").strip().lower() == "e2ee-proxy"
        if is_proxy:
            auto_base = ranked[0]
            auto_models = ranked[:1]
        else:
            auto_base = ",".join(ranked[:5])
            auto_models = ranked[:5]

        auto_updated = sync_auto_model(token, auto_model_id, auto_base, auto_models)
        if auto_updated:
            updates.append(f"CHUTES_AUTO({ranked[0]}...)")

        if models_config.get("DEFAULT_MODELS") != auto_model_id:
            models_config["DEFAULT_MODELS"] = auto_model_id
            request_json("POST", "/api/v1/configs/models", token, models_config)
            updates.append("DEFAULT_MODELS(chutes-auto)")

    warmup_count = warmup_audio_chutes(token)
    if warmup_count:
        updates.append(f"AUDIO_WARMUP({warmup_count})")

    admin_count = sync_admin_roles(token)
    if admin_count:
        updates.append(f"ADMIN_PROMOTE({admin_count})")

    return len(api_urls), updates, len(ordered_ids), used_backend_fallback


def configured_audio_chute_names() -> list[str]:
    """Return the Chutes-hosted audio models that need warmup in this deployment."""

    names = []

    tts_engine = (os.environ.get("AUDIO_TTS_ENGINE") or "openai").strip().lower()
    if tts_engine == "openai":
        tts_model = (os.environ.get("AUDIO_TTS_MODEL") or "kokoro").split(",", 1)[0].strip()
        if tts_model:
            names.append(tts_model)

    stt_engine = desired_stt_engine_mode()
    if stt_engine == "openai":
        stt_model = (os.environ.get("AUDIO_STT_MODEL") or "whisper-large-v3").split(",", 1)[0].strip()
        if stt_model:
            names.append(stt_model)

    return list(dict.fromkeys(names))


def _get_chutes_oauth_token() -> str:
    """Get the admin's Chutes OAuth token from stored SSO sessions.

    The warmup API requires an OAuth token (API keys return 401).
    We reuse the admin's stored SSO session — no fingerprint or manual
    setup needed.  If nobody has logged in via SSO yet, returns empty
    and warmup is silently skipped (chutes cold-start on first request).
    """
    try:
        from open_webui.models.oauth_sessions import OAuthSessions

        with get_db() as db:
            result = Users.get_users(db=db)
            user_list = result.get("users", []) if isinstance(result, dict) else result
            for user in sorted(user_list, key=lambda u: 0 if u.role == "admin" else 1):
                session = OAuthSessions.get_session_by_provider_and_user_id(
                    "oidc", user.id, db=db
                )
                if session and isinstance(session.token, dict) and session.token.get("access_token"):
                    return session.token["access_token"]
    except Exception:
        pass
    return ""


def warmup_audio_chutes(token: str) -> int:
    """Warm up cold TTS/STT chutes so they're ready for users."""
    audio_chute_names = configured_audio_chute_names()
    if not audio_chute_names:
        return 0

    utilization = fetch_utilization()
    if not utilization:
        return 0

    active_by_name = {}
    for entry in utilization:
        active_by_name[entry.get("name", "")] = entry.get("active_instance_count", 0)

    cold = [name for name in audio_chute_names if active_by_name.get(name, 0) == 0]
    if not cold:
        return 0

    chutes_token = _get_chutes_oauth_token()
    if not chutes_token:
        return 0

    api = os.environ.get("CHUTES_IDP_BASE_URL", "https://api.chutes.ai").rstrip("/")
    warmed = 0
    for name in cold:
        req = urllib.request.Request(
            f"{api}/chutes/warmup/{name}",
            headers={"Authorization": f"Bearer {chutes_token}", "Accept": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp.read()
            warmed += 1
        except Exception:
            pass
    return warmed


def generate_composite_logo(model_ids: list[str]) -> str:
    """Generate a circular composite logo with provider icons in a ring.

    Returns a data:image/png;base64,... string, or empty string on failure.
    """
    import base64
    import io
    import math

    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return ""

    size = 256
    icon_size = 80
    count = min(len(model_ids), 5)
    if count == 0:
        return ""

    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    center = size / 2
    radius = (size - icon_size) / 2 * 0.62

    # Place icons in a ring, starting at top (-90°), clockwise
    positions = []
    for i in range(count):
        angle = -math.pi / 2 + (2 * math.pi * i / count)
        x = int(center + radius * math.cos(angle) - icon_size / 2)
        y = int(center + radius * math.sin(angle) - icon_size / 2)
        positions.append((x, y))

    # Load and place icons back-to-front so first icon (top) is on top
    for i in reversed(range(count)):
        model_id = model_ids[i]
        logo = logo_url_for_model(model_id)
        if not logo or logo == CHUTES_LOGO_URL:
            continue

        try:
            req = urllib.request.Request(logo, headers={"User-Agent": "chutes-dropzone/1.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                img_data = resp.read()
            icon = Image.open(io.BytesIO(img_data)).convert("RGBA")
            icon = icon.resize((icon_size, icon_size), Image.LANCZOS)

            # Circular mask
            mask = Image.new("L", (icon_size, icon_size), 0)
            ImageDraw.Draw(mask).ellipse((0, 0, icon_size, icon_size), fill=255)
            icon.putalpha(mask)

            # Dark ring border for separation
            border = 3
            ring_size = icon_size + border * 2
            ring = Image.new("RGBA", (ring_size, ring_size), (0, 0, 0, 0))
            ImageDraw.Draw(ring).ellipse((0, 0, ring_size, ring_size), fill=(20, 20, 24, 240))
            rx = positions[i][0] - border
            ry = positions[i][1] - border
            canvas.paste(ring, (rx, ry), ring)
            canvas.paste(icon, positions[i], icon)
        except Exception:
            continue

    # Clip entire canvas to circle
    final_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(final_mask).ellipse((0, 0, size, size), fill=255)
    canvas.putalpha(final_mask)

    buf = io.BytesIO()
    canvas.save(buf, format="PNG", optimize=True)
    encoded = base64.b64encode(buf.getvalue()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def sync_auto_model(
    token: str, model_id: str, base_model_id: str, ranked: list[str]
) -> bool:
    """Create or update the Chutes Auto model with composite logo."""
    import hashlib

    from open_webui.models.models import Models

    ranked_key = hashlib.sha256(",".join(ranked).encode()).hexdigest()[:16]
    name = "Chutes Auto"
    refresh_interval = format_refresh_interval(auto_model_refresh_interval_seconds())
    best_model_name = friendly_auto_model_name(ranked[0]) if ranked else ""
    description = (
        f"Now using {best_model_name}. Refreshes every {refresh_interval}."
        if best_model_name
        else AUTO_MODEL_DESCRIPTION
    )
    routing_models = list(ranked)
    routing_tooltip = ""
    if routing_models:
        tooltip_lines = [f"Updates every {refresh_interval}", "Models"]
        tooltip_lines.extend(f"- {model_name}" for model_name in routing_models)
        routing_tooltip = "\n".join(tooltip_lines)

    with get_db() as db:
        existing = Models.get_model_by_id(model_id, db)

    composite = generate_composite_logo(ranked)

    if existing:
        current_desc = ""
        current_routing_key = ""
        current_routing_tooltip = ""
        current_profile_image = ""
        current_base_model_id = getattr(existing, "base_model_id", "") or ""

        if existing.meta:
            current_desc = getattr(existing.meta, "description", "") or ""
            current_routing_key = getattr(existing.meta, "routing_key", "") or ""
            current_routing_tooltip = getattr(existing.meta, "routing_tooltip", "") or ""
            current_profile_image = getattr(existing.meta, "profile_image_url", "") or ""

        if (
            current_desc == description
            and current_routing_key == ranked_key
            and current_routing_tooltip == routing_tooltip
            and current_base_model_id == base_model_id
            and ((not composite) or current_profile_image == composite)
        ):
            return False

    meta = {
        "description": description,
        "routing_key": ranked_key,
        "routing_models": routing_models,
    }
    if routing_tooltip:
        meta["routing_tooltip"] = routing_tooltip
    if composite:
        meta["profile_image_url"] = composite

    if existing:
        try:
            request_json("POST", "/api/v1/models/model/update", token, {
                "id": model_id,
                "name": name,
                "base_model_id": base_model_id,
                "meta": meta,
                "params": existing.params.model_dump() if existing.params else {},
            })
            return True
        except Exception:
            return False
    else:
        try:
            request_json("POST", "/api/v1/models/create", token, {
                "id": model_id,
                "name": name,
                "base_model_id": base_model_id,
                "meta": meta,
                "params": {},
            })
            return True
        except Exception:
            return False


def sync_model_logos(token: str, model_ids: list[str]) -> int:
    """Create or update model override records so OpenWebUI shows provider logos."""
    from open_webui.models.models import Models

    synced = 0
    for model_id in model_ids:
        logo = logo_url_for_model(model_id)
        if not logo:
            continue

        with get_db() as db:
            existing = Models.get_model_by_id(model_id, db)

        if existing:
            current_url = ""
            if existing.meta and hasattr(existing.meta, "profile_image_url"):
                current_url = existing.meta.profile_image_url or ""
            if current_url == logo:
                continue
            try:
                request_json("POST", "/api/v1/models/model/update", token, {
                    "id": model_id,
                    "name": existing.name or model_id,
                    "meta": {"profile_image_url": logo},
                    "params": existing.params.model_dump() if existing.params else {},
                })
                synced += 1
            except Exception:
                pass
        else:
            try:
                request_json("POST", "/api/v1/models/create", token, {
                    "id": model_id,
                    "name": model_id,
                    "base_model_id": None,
                    "meta": {"profile_image_url": logo},
                    "params": {},
                })
                synced += 1
            except Exception:
                pass

    return synced


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--configure-openai-auth",
        action="store_true",
        help="also enforce system_oauth on every configured OpenAI-compatible backend",
    )
    parser.add_argument(
        "--quiet-no-change",
        action="store_true",
        help="suppress output when no runtime changes were required",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    backend_count, updates, model_count, used_backend_fallback = sync_runtime(
        args.configure_openai_auth
    )

    if updates or not args.quiet_no_change:
        if args.configure_openai_auth:
            print(
                f"configured OpenWebUI upstream auth for {backend_count} backend(s) via system_oauth"
            )
        if used_backend_fallback:
            print(
                "seeded OpenWebUI model order from the public llm.chutes.ai catalog because no OAuth-backed user session exists yet"
            )
        print(f"computed TEE-first newest-first provider ordering for {model_count} model(s)")
        if updates:
            print(f"updated runtime config: {', '.join(updates)}")
        else:
            print("runtime config already matched desired OpenWebUI settings")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
