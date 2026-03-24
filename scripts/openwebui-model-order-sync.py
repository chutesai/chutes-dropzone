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
        is_proxy = any("e2ee-proxy" in u for u in api_urls)
        if is_proxy:
            auto_base = ranked[0]
        else:
            auto_base = ",".join(ranked[:5])

        auto_updated = sync_auto_model(token, auto_model_id, auto_base, ranked[:5])
        if auto_updated:
            updates.append(f"CHUTES_AUTO({ranked[0]}...)")

        if models_config.get("DEFAULT_MODELS") != auto_model_id:
            models_config["DEFAULT_MODELS"] = auto_model_id
            request_json("POST", "/api/v1/configs/models", token, models_config)
            updates.append("DEFAULT_MODELS(chutes-auto)")

    warmup_count = warmup_audio_chutes(token)
    if warmup_count:
        updates.append(f"AUDIO_WARMUP({warmup_count})")

    return len(api_urls), updates, len(ordered_ids), used_backend_fallback


AUDIO_CHUTE_NAMES = [
    "kokoro",
    "whisper-large-v3",
]


def _get_chutes_oauth_token() -> str:
    """Get any user's Chutes OAuth token from stored SSO sessions."""
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
    utilization = fetch_utilization()
    if not utilization:
        return 0

    active_by_name = {}
    for entry in utilization:
        active_by_name[entry.get("name", "")] = entry.get("active_instance_count", 0)

    cold = [name for name in AUDIO_CHUTE_NAMES if active_by_name.get(name, 0) == 0]
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
    short_names = ", ".join(m.split("/", 1)[-1] for m in ranked)
    description = f"Best available model, updated every 5 minutes. Routing: {short_names}"

    with get_db() as db:
        existing = Models.get_model_by_id(model_id, db)

    current_key = ""
    if existing:
        current_desc = ""
        if existing.meta and hasattr(existing.meta, "description"):
            current_desc = existing.meta.description or ""
        if current_desc.endswith(f"[{ranked_key}]"):
            return False

    composite = generate_composite_logo(ranked)
    meta = {"description": f"{description} [{ranked_key}]"}
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
