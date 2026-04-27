"""
Chutes image model discovery and image generation bridge for OpenWebUI.

This adapter keeps OpenWebUI's native image-generation UX while routing
requests to live Chutes image chutes discovered from the Chutes API.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import hmac
import html
import json
import logging
import os
import re
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Optional

from fastapi import HTTPException, Request

from open_webui.dropzone_oauth import (
    get_request_oauth_token,
    get_user_oauth_access_token,
)

log = logging.getLogger(__name__)


AUTO_IMAGE_MODEL_ID = "chutes-auto-image"
IMAGE_MODEL_COOKIE_NAME = "dropzone-image-model"
TEXT_TO_IMAGE_KEYWORDS = (
    "text-to-image",
    "text to image",
    "txt2img",
    "t2i",
    "image generation",
    "image generator",
    "generate image",
    "generate images",
    "generates image",
    "generates images",
)
IMAGE_RUNTIME_KEYWORDS = (
    "image",
    "diffusion",
    "comfyui",
    "automatic1111",
    "a1111",
    "stable-diffusion",
    "stable diffusion",
    "sdxl",
    "sd3",
    "txt2img",
    "t2i",
)
NON_TEXT_TO_IMAGE_KEYWORDS = (
    "image edit",
    "edit image",
    "image-to-image",
    "image to image",
    "img2img",
    "i2i",
    "inpaint",
    "outpaint",
    "i2v",
    "image-to-video",
    "image to video",
    "text-to-video",
    "text to video",
    "video",
    "classifier",
    "nsfw",
    "upscaler",
    "upscale",
)
TEXT_RUNTIME_IMAGE_NAMES = {
    "vllm",
    "sglang",
    "tei",
    "tgi",
    "text-embeddings-inference",
    "nsfw-classifier",
}

CHUTES_LIST_URL = os.environ.get(
    "CHUTES_LIST_URL", "https://api.chutes.ai/chutes/"
).rstrip("/")
CHUTES_UTILIZATION_URL = os.environ.get(
    "CHUTES_UTILIZATION_URL", "https://api.chutes.ai/chutes/utilization"
).rstrip("/")
CHUTES_IMAGE_TIMEOUT = max(
    10, int((os.environ.get("DROPZONE_IMAGE_TIMEOUT_SECONDS") or "180").strip() or "180")
)
CHUTES_IMAGE_FALLBACK_ATTEMPTS = max(
    1,
    int((os.environ.get("DROPZONE_IMAGE_FALLBACK_ATTEMPTS") or "8").strip() or "8"),
)
CHUTES_IMAGE_FAILURE_COOLDOWN = max(
    0,
    int((os.environ.get("DROPZONE_IMAGE_FAILURE_COOLDOWN_SECONDS") or "90").strip() or "90"),
)
TRANSIENT_IMAGE_STATUS_CODES = {408, 429, 500, 502, 503, 504}


def _traffic_mode() -> str:
    return (os.environ.get("CHUTES_TRAFFIC_MODE") or "direct").strip().lower() or "direct"


def _proxy_internal_url() -> str:
    return (os.environ.get("CHUTES_PROXY_INTERNAL_URL") or "").strip().rstrip("/")


def _allow_non_confidential() -> bool:
    return (os.environ.get("ALLOW_NON_CONFIDENTIAL") or "false").strip().lower() == "true"


_discovery_cache: dict[str, dict[str, Any]] = {}
_utilization_cache: dict[str, Any] = {"items": [], "ts": 0.0}
_image_failure_cache: dict[str, dict[str, Any]] = {}


def _cache_ttl() -> int:
    for env_name in (
        "DROPZONE_IMAGE_MODELS_CACHE_TTL",
        "OPENWEBUI_MODEL_ORDER_SYNC_INTERVAL",
        "MODELS_CACHE_TTL",
    ):
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


def _format_refresh_interval(seconds: int) -> str:
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


def _token_cache_key(token: str) -> str:
    if not token:
        return "public"
    digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
    return f"oauth:{digest[:24]}"


def _discovery_cache_key(token: str) -> str:
    return "|".join(
        (
            _token_cache_key(token),
            f"mode:{_traffic_mode()}",
            f"allow_non_confidential:{str(_allow_non_confidential()).lower()}",
        )
    )


def _fetch_json(url: str, token: str = "", timeout: int = 20):
    headers = {"Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def _fetch_utilization() -> list[dict[str, Any]]:
    now = time.time()
    ttl = _cache_ttl()
    if _utilization_cache.get("ts", 0) + ttl > now and _utilization_cache.get("items") is not None:
        return list(_utilization_cache.get("items") or [])

    try:
        payload = _fetch_json(CHUTES_UTILIZATION_URL)
    except Exception as exc:
        log.debug("image utilization fetch failed: %s", exc)
        payload = []

    items = payload if isinstance(payload, list) else []
    _utilization_cache["items"] = items
    _utilization_cache["ts"] = now
    return list(items)


def _fetch_diffusion_chutes(token: str = "") -> list[dict[str, Any]]:
    query = urllib.parse.urlencode(
        {
            "include_public": "true",
            "template": "diffusion",
            "limit": "500",
        }
    )
    url = f"{CHUTES_LIST_URL}/?{query}" if not CHUTES_LIST_URL.endswith("/") else f"{CHUTES_LIST_URL}?{query}"
    payload = _fetch_json(url, token=token)
    items = payload.get("items", []) if isinstance(payload, dict) else payload
    return items if isinstance(items, list) else []


def _fetch_public_chutes(token: str = "") -> list[dict[str, Any]]:
    query = urllib.parse.urlencode({"include_public": "true", "limit": 500})
    url = f"{CHUTES_LIST_URL}/?{query}" if not CHUTES_LIST_URL.endswith("/") else f"{CHUTES_LIST_URL}?{query}"
    payload = _fetch_json(url, token=token)
    items = payload.get("items", []) if isinstance(payload, dict) else payload
    return items if isinstance(items, list) else []


def _model_score(utilization: dict[str, Any]) -> float:
    active = int(utilization.get("active_instance_count", 0) or 0)
    total = int(utilization.get("total_instance_count", 0) or 0)
    util_5m_raw = utilization.get("utilization_5m", None)
    util_5m = 1.0 if util_5m_raw is None else float(util_5m_raw)

    if active > 0:
        return max(active * (1.0 - util_5m), 0.001)
    if total > 0:
        return 0.0001
    return 0.0


def _friendly_image_name(model: dict[str, Any]) -> str:
    return str(model.get("display_name") or model.get("name") or model.get("id") or "").strip()


def _image_model_key(model: dict[str, Any]) -> str:
    return str(model.get("id") or model.get("chute_id") or model.get("slug") or "").strip()


def _image_model_failure_key(model: dict[str, Any]) -> str:
    for key in ("id", "chute_id", "slug"):
        value = str(model.get(key) or "").strip()
        if value:
            return f"{key}:{value}"
    return _image_model_key(model)


def _image_model_recent_failure(model: dict[str, Any], now: float | None = None) -> dict[str, Any] | None:
    if CHUTES_IMAGE_FAILURE_COOLDOWN <= 0:
        return None
    key = _image_model_failure_key(model)
    if not key:
        return None
    now = time.time() if now is None else now
    failure = _image_failure_cache.get(key)
    if not failure:
        return None
    if float(failure.get("ts", 0.0) or 0.0) + CHUTES_IMAGE_FAILURE_COOLDOWN <= now:
        _image_failure_cache.pop(key, None)
        return None
    return failure


def _mark_image_model_unhealthy(model: dict[str, Any], error: str) -> None:
    if CHUTES_IMAGE_FAILURE_COOLDOWN <= 0:
        return
    key = _image_model_failure_key(model)
    if key:
        _image_failure_cache[key] = {
            "ts": time.time(),
            "model_id": str(model.get("id") or ""),
            "error": str(error or ""),
        }


def _mark_image_model_healthy(model: dict[str, Any]) -> None:
    key = _image_model_failure_key(model)
    if key:
        _image_failure_cache.pop(key, None)


def _image_model_proxy_allowed(model: dict[str, Any]) -> bool:
    if _traffic_mode() != "e2ee-proxy":
        return True
    return bool(model.get("tee")) or _allow_non_confidential()


def _routable_image_models(models: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [model for model in models if _image_model_proxy_allowed(model)]


def _is_rescued_public_image_candidate(item: dict[str, Any]) -> bool:
    standard_template = str(item.get("standard_template") or "").strip().lower()
    if standard_template == "diffusion":
        return False

    name = str(item.get("name") or "").strip().lower()
    slug = str(item.get("slug") or "").strip().lower()
    tagline = str(item.get("tagline") or "").strip().lower()
    readme = str(item.get("readme") or "").strip().lower()
    image = item.get("image") if isinstance(item.get("image"), dict) else {}
    image_name = str(image.get("name") or "").strip().lower()
    image_runtime_blob = " ".join(part for part in (image_name, str(item.get("image") or "").lower()) if part)
    metadata_blob = " ".join(part for part in (name, slug, tagline, readme, image_name) if part)

    if any(token in metadata_blob for token in NON_TEXT_TO_IMAGE_KEYWORDS):
        return False

    if image_name in TEXT_RUNTIME_IMAGE_NAMES:
        return False

    has_image_runtime = any(token in image_runtime_blob for token in IMAGE_RUNTIME_KEYWORDS)
    has_text_to_image_metadata = any(token in metadata_blob for token in TEXT_TO_IMAGE_KEYWORDS)

    return has_image_runtime and has_text_to_image_metadata


def _no_image_models_detail() -> str:
    if _traffic_mode() == "e2ee-proxy" and not _allow_non_confidential():
        return (
            "No TEE-enabled Chutes image models are available right now for strict "
            "e2ee-proxy mode. Set ALLOW_NON_CONFIDENTIAL=true or use direct traffic mode."
        )
    return "No Chutes image models are available right now"


def _image_capability_rank(model: dict[str, Any]) -> int:
    standard_template = str(model.get("standard_template") or "").strip().lower()
    if standard_template == "diffusion":
        return 0
    image_name = str(model.get("image_name") or "").strip().lower()
    if any(token in image_name for token in IMAGE_RUNTIME_KEYWORDS):
        return 1
    return 2


def _build_auto_description(selected: Optional[dict[str, Any]]) -> str:
    refresh = _format_refresh_interval(_cache_ttl())
    if selected:
        return f"Now using {_friendly_image_name(selected)}. Refreshes every {refresh}."
    return f"Best available image model. Refreshes every {refresh}."


def _build_auto_tooltip(selected: Optional[dict[str, Any]], models: list[dict[str, Any]]) -> str:
    lines: list[str] = [_build_auto_description(selected)]
    if models:
        lines.extend(["", "Top choices"])
        for model in models[:4]:
            details = []
            active = int(model.get("active_instance_count", 0) or 0)
            if active > 0:
                details.append(f"{active} active")
            util_5m = model.get("utilization_5m")
            if util_5m is not None:
                details.append(f"{round(float(util_5m) * 100)}% busy")

            label = _friendly_image_name(model)
            if details:
                label += " (" + ", ".join(details) + ")"
            lines.append(label)
        if len(models) > 4:
            lines.append(f"+ {len(models) - 4} more live model(s)")
    return "\n".join(lines).strip()


def _discover_models(token: str = "") -> dict[str, Any]:
    cache_key = _discovery_cache_key(token)
    now = time.time()
    ttl = _cache_ttl()
    cached = _discovery_cache.get(cache_key)
    if cached and cached.get("ts", 0) + ttl > now:
        return cached

    items: list[dict[str, Any]] = []
    if token:
        try:
            items = _fetch_diffusion_chutes(token)
        except Exception as exc:
            log.debug("authenticated diffusion discovery failed: %s", exc)
            items = []

    public_items: list[dict[str, Any]] = []
    try:
        public_items = _fetch_diffusion_chutes("")
    except Exception as exc:
        log.debug("public diffusion discovery failed: %s", exc)
        public_items = []

    if public_items:
        merged_diffusion: dict[str, dict[str, Any]] = {}
        for item in items + public_items:
            if not isinstance(item, dict):
                continue
            key = str(item.get("chute_id") or item.get("id") or "").strip() or str(id(item))
            merged_diffusion[key] = item
        items = list(merged_diffusion.values())

    rescued_items: list[dict[str, Any]] = []
    if token:
        try:
            rescued_items = _fetch_public_chutes(token)
        except Exception as exc:
            log.debug("authenticated public image discovery failed: %s", exc)
            rescued_items = []

    public_rescued_items: list[dict[str, Any]] = []
    try:
        public_rescued_items = _fetch_public_chutes("")
    except Exception as exc:
        log.debug("public image discovery failed: %s", exc)
        public_rescued_items = []

    if not items:
        try:
            items = _fetch_diffusion_chutes("")
        except Exception as exc:
            log.debug("public diffusion discovery failed: %s", exc)
            items = []

    if public_rescued_items:
        merged_rescued: dict[str, dict[str, Any]] = {}
        for item in rescued_items + public_rescued_items:
            if not isinstance(item, dict):
                continue
            key = str(item.get("chute_id") or item.get("id") or "").strip() or str(id(item))
            merged_rescued[key] = item
        rescued_items = list(merged_rescued.values())

    if rescued_items:
        merged_items: dict[str, dict[str, Any]] = {}
        for item in items:
            if isinstance(item, dict):
                key = str(item.get("chute_id") or item.get("id") or "").strip() or str(id(item))
                merged_items[key] = item
        for item in rescued_items:
            if not isinstance(item, dict) or not _is_rescued_public_image_candidate(item):
                continue
            key = str(item.get("chute_id") or item.get("id") or "").strip() or str(id(item))
            merged_items.setdefault(key, item)
        items = list(merged_items.values())

    utilization_items = _fetch_utilization()
    utilization_by_chute_id = {
        str(entry.get("chute_id") or "").strip(): entry
        for entry in utilization_items
        if isinstance(entry, dict) and entry.get("chute_id")
    }
    utilization_by_name = {
        str(entry.get("name") or "").strip(): entry
        for entry in utilization_items
        if isinstance(entry, dict) and entry.get("name")
    }

    name_counts: dict[str, int] = {}
    for item in items:
        name = str(item.get("name") or "").strip()
        if name:
            name_counts[name] = name_counts.get(name, 0) + 1

    models: list[dict[str, Any]] = []
    for item in items:
        if not isinstance(item, dict):
            continue

        chute_id = str(item.get("chute_id") or "").strip()
        name = str(item.get("name") or "").strip()
        slug = str(item.get("slug") or "").strip()
        user = item.get("user") if isinstance(item.get("user"), dict) else {}
        image = item.get("image") if isinstance(item.get("image"), dict) else {}
        username = str(user.get("username") or item.get("username") or "").strip()
        if not name or not slug or not username:
            continue

        model_id = f"{username}/{name}"
        utilization = utilization_by_chute_id.get(chute_id) or utilization_by_name.get(name, {})
        score = _model_score(utilization)
        display_name = name if name_counts.get(name, 0) <= 1 else model_id

        models.append(
            {
                "id": model_id,
                "chute_id": chute_id,
                "name": name,
                "display_name": display_name,
                "username": username,
                "slug": slug,
                "score": score,
                "tee": item.get("tee") is True,
                "standard_template": str(item.get("standard_template") or "").strip(),
                "image_name": str(image.get("name") or item.get("image") or "").strip(),
                "active_instance_count": int(utilization.get("active_instance_count", 0) or 0),
                "total_instance_count": int(utilization.get("total_instance_count", 0) or 0),
                "utilization_5m": (
                    float(utilization.get("utilization_5m"))
                    if utilization.get("utilization_5m") is not None
                    else None
                ),
                "utilization_1h": (
                    float(utilization.get("utilization_1h"))
                    if utilization.get("utilization_1h") is not None
                    else (
                        float(utilization.get("avg_busy_ratio"))
                        if utilization.get("avg_busy_ratio") is not None
                        else None
                    )
                ),
                "logo_url": str(item.get("logo") or user.get("logo") or "").strip(),
                "tagline": str(item.get("tagline") or "").strip(),
            }
        )

    models.sort(
        key=lambda model: (
            _image_capability_rank(model),
            -int(model.get("active_instance_count", 0) or 0),
            float(model.get("utilization_5m", 1.0) or 1.0),
            -int(model.get("total_instance_count", 0) or 0),
            _friendly_image_name(model).lower(),
        )
    )
    selected = models[0] if models else None

    payload = {
        "items": models,
        "selected": selected,
        "ts": now,
    }
    _discovery_cache[cache_key] = payload
    return payload


def is_chutes_image_backend(request: Request) -> bool:
    provider = (os.environ.get("DROPZONE_IMAGE_GENERATION_PROVIDER") or "").strip().lower()
    if provider == "chutes":
        return True

    if getattr(request.app.state.config, "IMAGE_GENERATION_ENGINE", "") != "openai":
        return False

    base_url = str(getattr(request.app.state.config, "IMAGES_OPENAI_API_BASE_URL", "") or "").strip()
    if not base_url:
        return False

    try:
        hostname = urllib.parse.urlparse(base_url).netloc.lower()
    except Exception:
        return False

    return hostname.endswith("chutes.ai") or ".chutes.ai" in hostname


def _normalize_model_id(value: Any) -> str:
    text = str(value or "").strip()
    if not text:
        return ""
    return urllib.parse.unquote(text).strip()


def get_chutes_image_model(request: Request, form_data=None) -> str:
    for candidate in (
        getattr(form_data, "model", None),
        request.cookies.get(IMAGE_MODEL_COOKIE_NAME, ""),
        getattr(request.app.state.config, "IMAGE_GENERATION_MODEL", ""),
        AUTO_IMAGE_MODEL_ID,
    ):
        value = _normalize_model_id(candidate)
        if value:
            return value
    return AUTO_IMAGE_MODEL_ID


def get_chutes_image_models(user=None) -> list[dict[str, Any]]:
    token = ""
    if user:
        try:
            token = get_user_oauth_access_token(user.id, provider="oidc")
        except Exception as exc:
            log.debug("image model oauth lookup failed: %s", exc)

    discovered = _discover_models(token)
    models = _routable_image_models(list(discovered.get("items") or []))
    selected = models[0] if models else None

    if not models:
        return []

    rendered = []
    for model in models:
        rendered.append(
            {
                "id": model["id"],
                "name": model["display_name"],
                "description": model.get("tagline") or model["id"],
                "meta": {
                    "slug": model["slug"],
                    "username": model["username"],
                    "score": model["score"],
                    "logo": model.get("logo_url") or "",
                },
            }
        )

    rendered.append(
        {
            "id": AUTO_IMAGE_MODEL_ID,
            "name": "Chutes Auto Image",
            "description": _build_auto_description(selected),
            "meta": {
                "description": "Chutes Auto Image",
                "routing_tooltip": _build_auto_tooltip(selected, models),
                "resolved_model": selected.get("id") if selected else "",
            },
        }
    )

    return rendered


async def _resolve_request_access_token(request: Request, user=None) -> str:
    oauth_token = await get_request_oauth_token(request, user) if user else None
    access_token = (
        str(oauth_token.get("access_token") or "").strip() if isinstance(oauth_token, dict) else ""
    )
    if access_token:
        return access_token
    return str(getattr(request.app.state.config, "IMAGES_OPENAI_API_KEY", "") or "").strip()


def _resolve_selected_model(model_id: str, token: str = "") -> tuple[dict[str, Any], dict[str, Any]]:
    model_id = _normalize_model_id(model_id)
    discovered = _discover_models(token)
    items = _routable_image_models(list(discovered.get("items") or []))
    auto_selected = items[0] if items else None
    if not items or not auto_selected:
        raise HTTPException(status_code=503, detail=_no_image_models_detail())

    if model_id == AUTO_IMAGE_MODEL_ID:
        return _annotate_model_resolution(auto_selected, model_id, "auto"), discovered

    for item in items:
        if hmac.compare_digest(str(item.get("id") or ""), model_id):
            return _annotate_model_resolution(item, model_id, "exact"), discovered

    log.warning("image model %s was unavailable; falling back to auto", model_id)
    return _annotate_model_resolution(auto_selected, model_id, "fallback"), discovered


def _candidate_image_models(model_id: str, token: str = "") -> list[dict[str, Any]]:
    """Return the selected model followed by ranked fallbacks.

    Chutes are independently deployed services, so a single image chute can
    return a transient 5xx while others are healthy. Keeping fallback local to
    auto-image routing prevents the chat model from retrying the same bad chute.
    """
    selected_model, discovered = _resolve_selected_model(model_id, token)
    items = _routable_image_models(list(discovered.get("items") or []))
    healthy_candidates: list[dict[str, Any]] = []
    cooling_candidates: list[dict[str, Any]] = []
    seen: set[str] = set()
    now = time.time()

    def add(model: dict[str, Any]) -> None:
        if len(healthy_candidates) + len(cooling_candidates) >= CHUTES_IMAGE_FALLBACK_ATTEMPTS:
            return
        key = _image_model_key(model)
        if not key or key in seen:
            return
        seen.add(key)
        model_copy = dict(model)
        if _image_model_recent_failure(model_copy, now=now):
            cooling_candidates.append(model_copy)
        else:
            healthy_candidates.append(model_copy)

    add(selected_model)
    for item in items:
        add(item)
        if len(healthy_candidates) + len(cooling_candidates) >= CHUTES_IMAGE_FALLBACK_ATTEMPTS:
            break

    return healthy_candidates + cooling_candidates


def _annotate_model_resolution(
    selected_model: dict[str, Any], requested_model: str, resolution: str
) -> dict[str, Any]:
    selected = dict(selected_model)
    selected_id = str(selected.get("id") or "").strip()
    requested_id = _normalize_model_id(requested_model) or AUTO_IMAGE_MODEL_ID
    fell_back = resolution == "fallback" and requested_id != selected_id
    selected["requested_model"] = requested_id
    selected["resolved_model"] = selected_id
    selected["model_resolution"] = resolution
    selected["model_fallback"] = fell_back
    if fell_back:
        selected["fallback_from"] = requested_id
        selected["fallback_to"] = selected_id
        selected["fallback_reason"] = "requested image model is unavailable; using Chutes Auto Image"
    return selected


def _annotate_runtime_fallback_model(
    selected_model: dict[str, Any],
    requested_model: str,
    failures: list[dict[str, str]],
) -> dict[str, Any]:
    selected = dict(selected_model)
    selected_id = str(selected.get("id") or "").strip()
    requested_id = _normalize_model_id(requested_model) or AUTO_IMAGE_MODEL_ID
    failed_models = [failure.get("model_id", "") for failure in failures if failure.get("model_id")]
    last_failure = failures[-1] if failures else {}
    last_model = str(last_failure.get("model_id") or "").strip()
    last_error = str(last_failure.get("error") or "").strip()

    selected["requested_model"] = requested_id
    selected["resolved_model"] = selected_id
    selected["model_resolution"] = "runtime_fallback"
    selected["model_fallback"] = bool(failures)
    selected["fallback_from"] = requested_id
    selected["fallback_to"] = selected_id
    selected["failed_image_models"] = failed_models
    if last_model and last_error:
        selected["fallback_reason"] = (
            f"{last_model} failed transiently ({last_error}); using next available Chutes image model"
        )
    elif last_model:
        selected["fallback_reason"] = (
            f"{last_model} failed transiently; using next available Chutes image model"
        )
    else:
        selected["fallback_reason"] = "previous image model failed transiently; using next available Chutes image model"
    return selected


def _sanitize_upstream_error(raw: bytes, fallback: Any = "", limit: int = 320) -> str:
    text = ""
    try:
        decoded = raw.decode("utf-8", errors="replace").strip()
    except Exception:
        decoded = ""

    if decoded:
        try:
            payload = json.loads(decoded)
        except Exception:
            payload = None

        if isinstance(payload, dict):
            for key in ("detail", "message", "error"):
                value = payload.get(key)
                if isinstance(value, dict):
                    text = str(value.get("message") or value.get("detail") or "").strip()
                elif value is not None:
                    text = str(value).strip()
                if text:
                    break
        elif isinstance(payload, str):
            text = payload.strip()

        if not text:
            text = decoded

    if not text:
        text = str(fallback or "").strip()

    text = html.unescape(text)
    text = re.sub(r"(?is)<(script|style)\b.*?</\1>", " ", text)
    text = re.sub(r"(?s)<[^>]*>", " ", text)
    text = re.sub(r"(?i)bearer\s+[a-z0-9._~+/=-]+", "Bearer [redacted]", text)
    text = re.sub(r"\s+", " ", text).strip()
    if not text:
        text = "upstream service returned an error"
    if len(text) > limit:
        text = text[: max(0, limit - 3)].rstrip() + "..."
    return text


def _explicit_size(request: Request, form_data) -> tuple[int, int] | None:
    raw = str(getattr(form_data, "size", None) or "").strip()
    if not raw:
        raw = str(getattr(request.app.state.config, "IMAGE_SIZE", "") or "").strip()

    if not raw or raw == "auto" or "x" not in raw:
        return None

    try:
        width_str, height_str = raw.lower().split("x", 1)
        width = int(width_str)
        height = int(height_str)
    except (TypeError, ValueError):
        return None

    if width <= 0 or height <= 0:
        return None
    return width, height


def _generation_payload(request: Request, form_data) -> dict[str, Any]:
    payload: dict[str, Any] = {"prompt": str(getattr(form_data, "prompt", "") or "").strip()}
    if not payload["prompt"]:
        raise HTTPException(status_code=400, detail="Image prompt is required")

    negative_prompt = str(getattr(form_data, "negative_prompt", "") or "").strip()
    if negative_prompt:
        payload["negative_prompt"] = negative_prompt

    size = _explicit_size(request, form_data)
    if size:
        payload["width"], payload["height"] = size

    steps = getattr(form_data, "steps", None)
    if steps is not None:
        try:
            steps_value = int(steps)
        except (TypeError, ValueError):
            steps_value = None
        if steps_value and steps_value > 0:
            payload["num_inference_steps"] = steps_value

    return payload


def _model_accepts_standard_diffusion_payload(model: dict[str, Any]) -> bool:
    """Only standard diffusion template chutes accept width/height/step overrides reliably."""

    return str(model.get("standard_template") or "").strip().lower() == "diffusion"


def _payload_for_image_model(model: dict[str, Any], payload: dict[str, Any]) -> dict[str, Any]:
    if _model_accepts_standard_diffusion_payload(model):
        return dict(payload)

    # Some public image chutes are not registered as the standard diffusion
    # template. They still expose /generate, but reject the template-specific
    # width/height/num_inference_steps fields. Keep the prompt contract minimal.
    allowed = {"prompt", "negative_prompt"}
    return {key: value for key, value in payload.items() if key in allowed and value not in (None, "")}


def _payload_size(payload: dict[str, Any]) -> str:
    width = payload.get("width")
    height = payload.get("height")
    if isinstance(width, int) and isinstance(height, int) and width > 0 and height > 0:
        return f"{width}x{height}"
    return ""


async def describe_chutes_image_request(request: Request, form_data, user=None) -> dict[str, Any]:
    access_token = await _resolve_request_access_token(request, user)
    if not access_token:
        raise HTTPException(
            status_code=502,
            detail="No Chutes image authorization is available for this request",
        )

    requested_model = get_chutes_image_model(request, form_data)
    payload = _generation_payload(request, form_data)
    selected_model, _ = _resolve_selected_model(requested_model, access_token)
    selected_name = _friendly_image_name(selected_model)

    return {
        "requested_model": requested_model,
        "selected_model": {
            "id": str(selected_model.get("id") or "").strip(),
            "name": selected_name,
            "slug": str(selected_model.get("slug") or "").strip(),
            "chute_id": str(selected_model.get("chute_id") or "").strip(),
            "requested_model": str(selected_model.get("requested_model") or requested_model).strip(),
            "resolved_model": str(selected_model.get("resolved_model") or selected_model.get("id") or "").strip(),
            "model_resolution": str(selected_model.get("model_resolution") or "").strip(),
            "model_fallback": bool(selected_model.get("model_fallback")),
            **(
                {
                    "fallback_from": str(selected_model.get("fallback_from") or "").strip(),
                    "fallback_to": str(selected_model.get("fallback_to") or "").strip(),
                    "fallback_reason": str(selected_model.get("fallback_reason") or "").strip(),
                }
                if selected_model.get("model_fallback")
                else {}
            ),
        },
        "payload": dict(payload),
        "traffic_mode": _traffic_mode(),
        "size": _payload_size(payload),
    }


def _image_request_target(selected_model: dict[str, Any]) -> tuple[str, dict[str, Any], str]:
    """Return (url, body, accept_header) for the configured traffic mode.

    In direct mode the request goes straight to the chute's own /generate
    endpoint with a chute-native body. In e2ee-proxy mode the request goes to
    the locally-deployed proxy using an OpenAI-compatible images body that
    carries the selected chute as ``model``.
    """
    mode = _traffic_mode()
    if mode == "e2ee-proxy":
        internal = _proxy_internal_url()
        if not internal:
            raise HTTPException(
                status_code=503,
                detail=(
                    "CHUTES_TRAFFIC_MODE=e2ee-proxy requires CHUTES_PROXY_INTERNAL_URL "
                    "to be set; refusing to route image generation directly to chutes.ai"
                ),
            )
        if not _image_model_proxy_allowed(selected_model):
            raise HTTPException(status_code=503, detail=_no_image_models_detail())
        proxy_model = str(selected_model.get("chute_id") or selected_model["id"]).strip()
        return f"{internal}/v1/images/generations", {"model": proxy_model}, "application/json, image/*"

    return f"https://{selected_model['slug']}.chutes.ai/generate", {}, "image/jpeg"


def _decode_data_url(value: str) -> tuple[bytes, str]:
    text = str(value or "").strip()
    if not text.startswith("data:") or "," not in text:
        raise ValueError("invalid data URL")

    header, payload = text.split(",", 1)
    media_type = "image/png"
    if ";" in header:
        media_type = header[5:].split(";", 1)[0] or media_type
    elif header[5:]:
        media_type = header[5:]

    try:
        return base64.b64decode(payload, validate=True), media_type
    except (ValueError, binascii.Error) as exc:
        raise ValueError("invalid data URL payload") from exc


def _fetch_remote_image(url: str, access_token: str) -> tuple[bytes, str]:
    headers = {"Accept": "image/*,application/octet-stream;q=0.9,*/*;q=0.1"}
    request = urllib.request.Request(str(url).strip(), headers=headers)
    with urllib.request.urlopen(request, timeout=CHUTES_IMAGE_TIMEOUT) as response:
        return response.read(), response.headers.get("Content-Type", "image/png")


def _decode_image_record(record: Any, access_token: str) -> Optional[tuple[bytes, str]]:
    content_type = "image/png"
    candidate = record

    if isinstance(record, dict):
        content_type = str(record.get("content_type") or record.get("mime_type") or content_type).strip()

        for key in ("b64_json", "image_b64", "b64", "base64"):
            raw_value = record.get(key)
            if raw_value:
                try:
                    return base64.b64decode(str(raw_value), validate=True), content_type
                except (ValueError, binascii.Error) as exc:
                    raise HTTPException(status_code=502, detail="Chutes image response contained invalid base64") from exc

        for key in ("data_url", "data_uri", "url", "image_url", "output_url"):
            raw_value = record.get(key)
            if raw_value:
                candidate = raw_value
                break
        else:
            nested = record.get("data")
            if isinstance(nested, str):
                candidate = nested
            else:
                return None

    if isinstance(candidate, str):
        text = candidate.strip()
        if not text:
            return None
        if text.startswith("data:"):
            try:
                return _decode_data_url(text)
            except ValueError as exc:
                raise HTTPException(status_code=502, detail="Chutes image response contained an invalid data URL") from exc
        if text.startswith("http://") or text.startswith("https://"):
            try:
                return _fetch_remote_image(text, access_token)
            except Exception as exc:
                raise HTTPException(status_code=502, detail="Chutes image response returned an unreadable image URL") from exc

    return None


def _extract_images_from_json(raw: bytes, access_token: str) -> list[tuple[bytes, str]]:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except Exception as exc:
        raise HTTPException(status_code=502, detail="Chutes image proxy returned invalid JSON") from exc

    if isinstance(payload, dict):
        candidates: Any = payload.get("data")
        if not isinstance(candidates, list):
            candidates = payload.get("images")
        if not isinstance(candidates, list):
            candidates = payload.get("output")
        if not isinstance(candidates, list):
            candidates = [payload]
    elif isinstance(payload, list):
        candidates = payload
    else:
        candidates = [payload]

    images: list[tuple[bytes, str]] = []
    for record in candidates:
        decoded = _decode_image_record(record, access_token)
        if decoded:
            images.append(decoded)

    if images:
        return images

    raise HTTPException(
        status_code=502,
        detail="Chutes image proxy returned JSON without image data",
    )


def _decode_generated_images(raw: bytes, content_type: str, access_token: str) -> list[tuple[bytes, str]]:
    normalized = str(content_type or "").strip().lower()
    if "json" in normalized:
        return _extract_images_from_json(raw, access_token)

    leading = raw.lstrip()
    if leading.startswith(b"{") or leading.startswith(b"["):
        try:
            return _extract_images_from_json(raw, access_token)
        except HTTPException:
            if "image/" not in normalized:
                raise

    return [(raw, content_type or "image/jpeg")]


def _generate_chutes_images_blocking(
    requested_model: str,
    access_token: str,
    base_payload: dict[str, Any],
    image_count: int,
) -> tuple[list[tuple[bytes, str]], dict[str, Any]]:
    candidates = _candidate_image_models(requested_model, access_token)
    failures: list[dict[str, str]] = []
    last_model = candidates[0] if candidates else {}

    for candidate in candidates:
        selected_model = (
            _annotate_runtime_fallback_model(candidate, requested_model, failures)
            if failures
            else candidate
        )
        last_model = selected_model
        url, extra_body, accept_header = _image_request_target(selected_model)
        payload = {**extra_body, **_payload_for_image_model(selected_model, base_payload)}
        candidate_images: list[tuple[bytes, str]] = []

        try:
            while len(candidate_images) < image_count:
                request_data = json.dumps(payload).encode("utf-8")
                chute_request = urllib.request.Request(
                    url,
                    data=request_data,
                    headers={
                        "Authorization": f"Bearer {access_token}",
                        "Content-Type": "application/json",
                        "Accept": accept_header,
                    },
                    method="POST",
                )
                with urllib.request.urlopen(chute_request, timeout=CHUTES_IMAGE_TIMEOUT) as response:
                    candidate_images.extend(
                        _decode_generated_images(
                            response.read(),
                            response.headers.get("Content-Type", "image/jpeg"),
                            access_token,
                        )
                    )
                    if len(candidate_images) >= image_count:
                        break
            if len(candidate_images) >= image_count:
                _mark_image_model_healthy(selected_model)
                if failures:
                    log.warning(
                        "image generation recovered with %s after %d transient failure(s)",
                        selected_model.get("id"),
                        len(failures),
                    )
                return candidate_images[:image_count], selected_model
        except HTTPException:
            raise
        except urllib.error.HTTPError as exc:
            raw_detail = exc.read()
            detail = _sanitize_upstream_error(raw_detail, exc.reason)
            error_label = f"HTTP {exc.code}: {detail}"
            failure = {"model_id": str(selected_model.get("id") or ""), "error": error_label}
            can_fallback = exc.code in TRANSIENT_IMAGE_STATUS_CODES and candidate is not candidates[-1]
            if exc.code in TRANSIENT_IMAGE_STATUS_CODES:
                _mark_image_model_unhealthy(selected_model, error_label)
            log.warning(
                "image generation failed for %s: %s %s%s",
                selected_model.get("id"),
                exc.code,
                detail,
                "; trying next image model" if can_fallback else "",
            )
            failures.append(failure)
            if can_fallback:
                continue
            break
        except (TimeoutError, socket.timeout, urllib.error.URLError) as exc:
            detail = _sanitize_upstream_error(b"", exc)
            failure = {"model_id": str(selected_model.get("id") or ""), "error": detail}
            can_fallback = candidate is not candidates[-1]
            _mark_image_model_unhealthy(selected_model, detail)
            log.warning(
                "image generation failed for %s: %s%s",
                selected_model.get("id"),
                detail,
                "; trying next image model" if can_fallback else "",
            )
            failures.append(failure)
            if can_fallback:
                continue
            break
        except Exception as exc:
            log.warning("image generation failed for %s: %s", selected_model.get("id"), exc)
            raise HTTPException(
                status_code=502,
                detail=f"Chutes image generation failed for {selected_model.get('id') or 'selected model'}",
            ) from exc

    attempted = "; ".join(
        f"{failure.get('model_id')}: {failure.get('error')}"
        for failure in failures
        if failure.get("model_id") or failure.get("error")
    )
    detail = "Chutes image generation failed after trying all available fallback image models"
    if attempted:
        detail = f"{detail}. Attempted image models: {attempted}"
    raise HTTPException(status_code=502, detail=detail)


async def generate_chutes_images(request: Request, form_data, user=None) -> tuple[list[tuple[bytes, str]], dict[str, Any]]:
    access_token = await _resolve_request_access_token(request, user)
    if not access_token:
        raise HTTPException(
            status_code=502,
            detail="No Chutes image authorization is available for this request",
        )

    requested_model = get_chutes_image_model(request, form_data)
    base_payload = _generation_payload(request, form_data)
    image_count = max(1, int(getattr(form_data, "n", 1) or 1))
    return await asyncio.to_thread(
        _generate_chutes_images_blocking,
        requested_model,
        access_token,
        base_payload,
        image_count,
    )
