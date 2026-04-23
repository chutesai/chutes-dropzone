"""
Chutes diffusion model discovery and image generation bridge for OpenWebUI.

This adapter keeps OpenWebUI's native image-generation UX while routing
requests to live Chutes diffusion chutes discovered from the Chutes API.
"""

from __future__ import annotations

import asyncio
import base64
import binascii
import hashlib
import hmac
import json
import logging
import os
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
PREFERRED_IMAGE_MODEL_ORDER = ("qwen", "hunyuan", "z-image", "flux")

CHUTES_LIST_URL = os.environ.get(
    "CHUTES_LIST_URL", "https://api.chutes.ai/chutes/"
).rstrip("/")
CHUTES_UTILIZATION_URL = os.environ.get(
    "CHUTES_UTILIZATION_URL", "https://api.chutes.ai/chutes/utilization"
).rstrip("/")
CHUTES_IMAGE_TIMEOUT = max(
    10, int((os.environ.get("DROPZONE_IMAGE_TIMEOUT_SECONDS") or "180").strip() or "180")
)


def _traffic_mode() -> str:
    return (os.environ.get("CHUTES_TRAFFIC_MODE") or "direct").strip().lower() or "direct"


def _proxy_internal_url() -> str:
    return (os.environ.get("CHUTES_PROXY_INTERNAL_URL") or "").strip().rstrip("/")


def _allow_non_confidential() -> bool:
    return (os.environ.get("ALLOW_NON_CONFIDENTIAL") or "false").strip().lower() == "true"


_discovery_cache: dict[str, dict[str, Any]] = {}
_utilization_cache: dict[str, Any] = {"items": [], "ts": 0.0}


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
    readme = str(item.get("readme") or "").strip().lower()
    image = item.get("image") if isinstance(item.get("image"), dict) else {}
    image_name = str(image.get("name") or "").strip().lower()
    blob = " ".join(part for part in (name, slug, readme, image_name) if part)

    if not any(keyword in blob for keyword in PREFERRED_IMAGE_MODEL_ORDER):
        return False

    if any(token in blob for token in ("edit", "i2v", "video", "classifier", "nsfw")):
        return False

    if image_name in {"vllm", "sglang", "tei", "tgi", "text-embeddings-inference", "nfsw-classifier"}:
        return False

    if not any(token in image_name for token in ("image", "diffusion", "comfyui", "wan")):
        return False

    return True


def _no_image_models_detail() -> str:
    if _traffic_mode() == "e2ee-proxy" and not _allow_non_confidential():
        return (
            "No TEE-enabled Chutes image models are available right now for strict "
            "e2ee-proxy mode. Set ALLOW_NON_CONFIDENTIAL=true or use direct traffic mode."
        )
    return "No Chutes image models are available right now"


def _preferred_image_rank(model_name: str) -> int:
    normalized = str(model_name or "").strip().lower()
    for index, keyword in enumerate(PREFERRED_IMAGE_MODEL_ORDER):
        if keyword in normalized:
            return index
    return len(PREFERRED_IMAGE_MODEL_ORDER)


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
    cache_key = _token_cache_key(token)
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
            _preferred_image_rank(model.get("name") or model.get("id") or ""),
            -int(model.get("active_instance_count", 0) or 0),
            -float(model.get("utilization_1h", 0.0) or 0.0),
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
        return auto_selected, discovered

    for item in items:
        if hmac.compare_digest(str(item.get("id") or ""), model_id):
            return item, discovered

    log.warning("image model %s was unavailable; falling back to auto", model_id)
    return auto_selected, discovered


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
    selected_model, _ = _resolve_selected_model(requested_model, access_token)
    url, extra_body, accept_header = _image_request_target(selected_model)
    payload = {**extra_body, **base_payload}

    images: list[tuple[bytes, str]] = []
    for _ in range(image_count):
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
        try:
            with urllib.request.urlopen(chute_request, timeout=CHUTES_IMAGE_TIMEOUT) as response:
                images.extend(
                    _decode_generated_images(
                        response.read(),
                        response.headers.get("Content-Type", "image/jpeg"),
                        access_token,
                    )
                )
                if len(images) >= image_count:
                    break
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            log.warning("image generation failed for %s: %s %s", selected_model["id"], exc.code, detail)
            raise HTTPException(
                status_code=502,
                detail=f"Chutes image generation failed for {selected_model['id']}: {detail or exc.reason}",
            ) from exc
        except Exception as exc:
            log.warning("image generation failed for %s: %s", selected_model["id"], exc)
            raise HTTPException(
                status_code=502,
                detail=f"Chutes image generation failed for {selected_model['id']}",
            ) from exc

    return images[:image_count], selected_model


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
