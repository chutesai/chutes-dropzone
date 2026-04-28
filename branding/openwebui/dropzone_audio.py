"""
OpenAI-compatible audio adapter for Chutes TTS/STT chutes.

Auto-discovers available TTS and STT chutes from the Chutes utilization API
and translates between OpenAI's /v1/audio/* format and Chutes' invocation format.

Mounted by patch-openwebui-runtime.py into the OpenWebUI app.
"""

import asyncio
import base64
import hmac
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, Depends, HTTPException, Request, UploadFile, File, Form
from fastapi.responses import Response
from pydantic import BaseModel
from sqlalchemy.orm import Session
from typing import Optional

from open_webui.dropzone_oauth import get_user_oauth_access_token
from open_webui.internal.db import get_session
from open_webui.utils.auth import get_verified_user
from open_webui.models.users import Users, UserModel

log = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/dropzone", tags=["dropzone-audio"])


_LOOPBACK_PREFIXES = ("127.", "::1", "localhost")


def _is_loopback(request: Request) -> bool:
    """Check that the request originates from loopback (internal OpenWebUI call)."""
    client_host = request.client.host if request.client else ""
    return any(client_host.startswith(p) for p in _LOOPBACK_PREFIXES)


def _expected_internal_audio_api_keys() -> tuple[str, ...]:
    keys = []
    for env_name in (
        "DROPZONE_AUDIO_INTERNAL_API_KEY",
        "AUDIO_TTS_OPENAI_API_KEY",
        "AUDIO_STT_OPENAI_API_KEY",
    ):
        value = os.environ.get(env_name, "").strip()
        if value and value != "unused":
            keys.append(value)
    return tuple(dict.fromkeys(keys))


def _has_valid_internal_audio_auth(request: Request) -> bool:
    auth_header = request.headers.get("Authorization", "")
    if not auth_header.startswith("Bearer "):
        return False

    token = auth_header[7:].strip()
    if not token:
        return False

    for expected in _expected_internal_audio_api_keys():
        if hmac.compare_digest(token, expected):
            return True
    return False


def _resolve_user(request: Request) -> UserModel:
    """Resolve user from forwarded user-id header (internal OpenWebUI calls).

    OpenWebUI's audio router calls us with Authorization: Bearer <api-key>
    and X-OpenWebUI-User-Id: <user-id>. We trust the user-id header only
    when the request arrives from loopback with the configured internal
    audio API key. The edge proxy also strips this header from external
    requests.
    """
    if not _is_loopback(request):
        raise HTTPException(status_code=403, detail="This endpoint is internal-only")
    if not _has_valid_internal_audio_auth(request):
        raise HTTPException(status_code=403, detail="Invalid internal audio authentication")
    user_id = request.headers.get("X-OpenWebUI-User-Id", "")
    if user_id:
        found = Users.get_user_by_id(user_id)
        if found:
            return found
    raise HTTPException(status_code=401, detail="Authentication required — missing user context")

UTILIZATION_URL = os.environ.get(
    "CHUTES_UTILIZATION_URL", "https://api.chutes.ai/chutes/utilization"
)
CHUTES_LIST_URL = os.environ.get(
    "CHUTES_LIST_URL", "https://api.chutes.ai/chutes/"
)

TTS_TEMPLATES = {"kokoro", "spark-tts", "orpheus-tts", "cosy-voice-tts", "cosy-voice-tts-16g"}
STT_TEMPLATES = {"whisper-large-v3", "whisper-small-v3", "whisper-tiny-v3", "whisper-stt"}

TTS_CORD = "/speak"
STT_CORD = "/transcribe"

CHUTES_API_BASE = os.environ.get("CHUTES_IDP_BASE_URL", "https://api.chutes.ai").rstrip("/")

CACHE_TTL = 300  # 5 minutes
WARMUP_COOLDOWN_SECONDS = 60
TRANSIENT_AUDIO_HTTP_STATUS_CODES = {408, 409, 425, 429, 500, 502, 503, 504}

_cache: dict = {}
_warmup_cache: dict[str, float] = {}
_tts_limiters: dict[str, tuple[int, asyncio.Semaphore]] = {}


def _traffic_mode() -> str:
    return (os.environ.get("CHUTES_TRAFFIC_MODE") or "direct").strip().lower() or "direct"


def _proxy_internal_url() -> str:
    return (os.environ.get("CHUTES_PROXY_INTERNAL_URL") or "").strip().rstrip("/")


def _allow_non_confidential() -> bool:
    return (os.environ.get("ALLOW_NON_CONFIDENTIAL") or "false").strip().lower() == "true"


def _audio_proxy_allowed(chute: dict) -> bool:
    if _traffic_mode() != "e2ee-proxy":
        return True
    return bool(chute.get("tee")) or _allow_non_confidential()


def _no_audio_chute_detail(kind: str) -> str:
    label = "TTS" if kind == "tts" else "STT"
    if _traffic_mode() == "e2ee-proxy" and not _allow_non_confidential():
        return (
            f"No TEE-enabled {label} chute is available right now for strict "
            "e2ee-proxy mode. Set ALLOW_NON_CONFIDENTIAL=true or use direct traffic mode."
        )
    return f"No {label} chute available"


def _normalize_audio_model(value: Optional[str]) -> str:
    return str(value or "").strip().lower()


def _audio_model_aliases(chute: dict) -> tuple[str, ...]:
    aliases = []
    for value in (
        chute.get("chute_id"),
        chute.get("id"),
        chute.get("name"),
        chute.get("slug"),
    ):
        normalized = _normalize_audio_model(value)
        if normalized and normalized not in aliases:
            aliases.append(normalized)
    return tuple(aliases)


def _proxy_audio_model(chute: dict) -> str:
    return str(chute.get("chute_id") or chute.get("id") or chute.get("name") or "").strip()


def _audio_request_target(chute: dict, cord: str) -> tuple[str, dict]:
    """Return (url, extra_body) for the configured traffic mode.

    Direct: POST https://{slug}.chutes.ai{cord} with chute-native body.
    Proxy: POST {internal}/v1/audio/speech or /v1/audio/transcriptions with
    the chute id as ``model`` so the proxy can route to the right chute.
    """
    mode = _traffic_mode()
    if mode == "e2ee-proxy":
        internal = _proxy_internal_url()
        if not internal:
            raise HTTPException(
                status_code=503,
                detail=(
                    "CHUTES_TRAFFIC_MODE=e2ee-proxy requires CHUTES_PROXY_INTERNAL_URL "
                    "to be set; refusing to route audio directly to chutes.ai"
                ),
            )
        if not _audio_proxy_allowed(chute):
            raise HTTPException(
                status_code=503,
                detail=_no_audio_chute_detail("tts" if cord == TTS_CORD else "stt"),
            )
        endpoint = "/v1/audio/speech" if cord == TTS_CORD else "/v1/audio/transcriptions"
        return f"{internal}{endpoint}", {"model": _proxy_audio_model(chute)}

    return f"https://{chute['slug']}.chutes.ai{cord}", {}


def _fetch_json(url: str, timeout: int = 15):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


def _env_int(name: str, default: int, minimum: int = 1, maximum: int = 5) -> int:
    try:
        value = int(str(os.environ.get(name, default)).strip())
    except (TypeError, ValueError):
        value = default
    return max(minimum, min(maximum, value))


def _env_float(name: str, default: float, minimum: float = 0.0, maximum: float = 5.0) -> float:
    try:
        value = float(str(os.environ.get(name, default)).strip())
    except (TypeError, ValueError):
        value = default
    return max(minimum, min(maximum, value))


def _audio_concurrency_limit(chute: dict, env_name: str, default_cap: int = 1) -> int:
    configured = _env_int(env_name, 0, minimum=0, maximum=32)
    if configured > 0:
        return configured

    active_instances = int(chute.get("active_instance_count") or 0)
    if active_instances > 0:
        return max(1, min(active_instances, default_cap))
    return 1


def _tts_limiter(chute: dict) -> asyncio.Semaphore:
    name = str(chute.get("name") or chute.get("id") or "default")
    limit = _audio_concurrency_limit(chute, "DROPZONE_AUDIO_TTS_MAX_CONCURRENCY")
    cached = _tts_limiters.get(name)
    if cached and cached[0] == limit:
        return cached[1]

    limiter = asyncio.Semaphore(limit)
    _tts_limiters[name] = (limit, limiter)
    return limiter


def _http_error_excerpt(error: urllib.error.HTTPError, limit: int = 512) -> str:
    try:
        body = error.read(limit + 1)
    except Exception:
        return ""
    if not body:
        return ""
    text = body.decode("utf-8", errors="replace").strip()
    lowered = text.lower()
    gateway_markers = ("<html", "bad gateway", "service unavailable", "gateway timeout", "nginx")
    if not any(marker in lowered for marker in gateway_markers):
        return f"[redacted non-gateway error body, {len(body)} bytes]"
    if len(text) > limit:
        return f"{text[:limit]}..."
    return text


def _warmup_chute(name: str, token: str) -> None:
    """Fire-and-forget warmup for a cold chute using the caller's own OAuth token.

    Background warmup runs every 5 min via openwebui-model-order-sync.py using the
    admin's stored OAuth session.  This on-demand path covers the gap when a user
    hits a cold chute between sync cycles — their own SSO token is already available
    from the request context, so no service-account token is needed.
    """
    now = time.time()
    last_attempt = _warmup_cache.get(name, 0)
    if now - last_attempt < WARMUP_COOLDOWN_SECONDS:
        return
    _warmup_cache[name] = now

    url = f"{CHUTES_API_BASE}/chutes/warmup/{urllib.parse.quote(name, safe='')}"
    req = urllib.request.Request(
        url,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            resp.read()
        log.info("warmup requested for %s", name)
    except Exception as e:
        log.debug("warmup failed for %s: %s", name, e)


def _discover_chutes() -> dict:
    """Discover available TTS/STT chutes and pick the best by capacity."""
    now = time.time()
    cache_mode = f"{_traffic_mode()}:{int(_allow_non_confidential())}"
    if (
        _cache.get("ts", 0) + CACHE_TTL > now
        and _cache.get("mode") == cache_mode
        and "tts" in _cache
        and "stt" in _cache
    ):
        return _cache

    utilization = _fetch_json(UTILIZATION_URL)
    chutes_list = _fetch_json(f"{CHUTES_LIST_URL}?include_public=true&limit=500")

    if not utilization or not chutes_list:
        if _cache.get("mode") == cache_mode and "tts" in _cache and "stt" in _cache:
            return _cache
        return {
            "tts": None,
            "stt": None,
            "tts_items": [],
            "stt_items": [],
            "tts_items_all": [],
            "stt_items_all": [],
            "ts": now,
            "mode": cache_mode,
        }

    items = chutes_list.get("items", [])
    chute_map = {}
    for item in items:
        name = item.get("name", "")
        user = item.get("user") if isinstance(item.get("user"), dict) else {}
        chute_map[name] = {
            "slug": item.get("slug", ""),
            "chute_id": item.get("chute_id", ""),
            "tee": item.get("tee") is True,
            "username": str(user.get("username") or item.get("username") or "").strip(),
        }

    tts_candidates = []
    stt_candidates = []

    for entry in utilization:
        name = entry.get("name", "")
        instances = entry.get("active_instance_count", 0)
        total = entry.get("total_instance_count", 0)
        if instances <= 0 and total <= 0:
            continue
        util_5m = entry.get("utilization_5m", 1.0)
        score = max(instances * (1.0 - util_5m), 0.001) if instances > 0 else 0.0001
        chute_meta = chute_map.get(name, {})
        slug = chute_meta.get("slug", "")
        chute_id = chute_meta.get("chute_id", "")
        tee = chute_meta.get("tee") is True
        username = chute_meta.get("username", "")
        model_id = f"{username}/{name}" if username else name

        name_lower = name.lower()
        candidate = {
            "id": model_id,
            "name": name,
            "slug": slug,
            "chute_id": chute_id,
            "tee": tee,
            "score": score,
            "active_instance_count": int(instances or 0),
            "total_instance_count": int(total or 0),
            "utilization_5m": float(util_5m) if util_5m is not None else None,
        }

        if any(t in name_lower for t in TTS_TEMPLATES) or name_lower in TTS_TEMPLATES:
            if slug:
                tts_candidates.append(candidate)

        if any(t in name_lower for t in STT_TEMPLATES) or name_lower in STT_TEMPLATES:
            if slug:
                stt_candidates.append(candidate)

    def _sort_candidates(candidates: list[dict]) -> list[dict]:
        return sorted(
            candidates,
            key=lambda candidate: (
                -float(candidate.get("score", 0.0) or 0.0),
                -int(candidate.get("active_instance_count", 0) or 0),
                _normalize_audio_model(candidate.get("id") or candidate.get("name")),
            ),
        )

    tts_candidates_all = _sort_candidates(tts_candidates)
    stt_candidates_all = _sort_candidates(stt_candidates)
    tts_allowed = [candidate for candidate in tts_candidates_all if _audio_proxy_allowed(candidate)]
    stt_allowed = [candidate for candidate in stt_candidates_all if _audio_proxy_allowed(candidate)]

    tts_best = tts_allowed[0] if tts_allowed else None
    stt_best = stt_allowed[0] if stt_allowed else None

    result = {
        "tts": tts_best,
        "stt": stt_best,
        "tts_items": tts_allowed,
        "stt_items": stt_allowed,
        "tts_items_all": tts_candidates_all,
        "stt_items_all": stt_candidates_all,
        "ts": now,
        "mode": cache_mode,
    }
    _cache.update(result)
    log.info(
        "audio discovery: tts=%s stt=%s",
        tts_best["name"] if tts_best else "(none)",
        stt_best["name"] if stt_best else "(none)",
    )
    return result


async def _discover_chutes_async() -> dict:
    """Run blocking chute discovery off the FastAPI event loop."""

    return await asyncio.to_thread(_discover_chutes)


def _get_oauth_token(user, db) -> str:
    """Get the user's OAuth access token for Chutes API calls."""
    try:
        return get_user_oauth_access_token(user.id, db=db, provider="oidc")
    except Exception:
        pass
    return ""


def _select_audio_chute(kind: str, requested_model: Optional[str], discovery: dict) -> dict:
    available = list(discovery.get(f"{kind}_items") or [])
    requested = _normalize_audio_model(requested_model)
    if not available:
        raise HTTPException(status_code=503, detail=_no_audio_chute_detail(kind))

    if not requested:
        return available[0]

    for candidate in available:
        if requested in _audio_model_aliases(candidate):
            return candidate

    for candidate in list(discovery.get(f"{kind}_items_all") or []):
        if requested in _audio_model_aliases(candidate):
            if not _audio_proxy_allowed(candidate):
                raise HTTPException(status_code=503, detail=_no_audio_chute_detail(kind))
            break

    label = "TTS" if kind == "tts" else "STT"
    raise HTTPException(status_code=404, detail=f"Requested {label} model '{requested_model}' is unavailable")


def _encode_multipart_form_data(fields: dict, file_field: str, filename: str, content_type: str, file_bytes: bytes) -> tuple[bytes, str]:
    boundary = f"----dropzone-{int(time.time() * 1_000_000)}"
    safe_filename = str(filename or "audio").replace("\\", "_").replace('"', "_")
    parts: list[bytes] = []

    for name, value in fields.items():
        if value is None:
            continue
        parts.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"),
                str(value).encode("utf-8"),
                b"\r\n",
            ]
        )

    parts.extend(
        [
            f"--{boundary}\r\n".encode("utf-8"),
            (
                f'Content-Disposition: form-data; name="{file_field}"; filename="{safe_filename}"\r\n'
            ).encode("utf-8"),
            f"Content-Type: {content_type or 'application/octet-stream'}\r\n\r\n".encode("utf-8"),
            file_bytes,
            b"\r\n",
            f"--{boundary}--\r\n".encode("utf-8"),
        ]
    )
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def _proxy_tts_payload(chute: dict, payload: dict) -> dict:
    body = {
        "model": _proxy_audio_model(chute),
        "input": str(payload.get("text") or ""),
        "voice": str(payload.get("voice") or "af_heart"),
    }
    response_format = str(payload.get("response_format") or "").strip()
    if response_format:
        body["response_format"] = response_format
    return body


def _proxy_stt_fields(chute: dict) -> dict:
    return {
        "model": _proxy_audio_model(chute),
        "response_format": "json",
    }


def _default_audio_content_type(response_format: Optional[str], upstream_content_type: str) -> str:
    normalized = str(upstream_content_type or "").split(";", 1)[0].strip().lower()
    if normalized and normalized not in {"application/json", "application/octet-stream"}:
        return normalized

    return {
        "aac": "audio/aac",
        "flac": "audio/flac",
        "mp3": "audio/mpeg",
        "opus": "audio/opus",
        "pcm": "audio/pcm",
        "wav": "audio/wav",
    }.get(_normalize_audio_model(response_format), "audio/wav")


def _invoke_audio_request(
    chute: dict,
    cord: str,
    payload: dict,
    token: str,
    timeout: int = 30,
    file_bytes: Optional[bytes] = None,
    filename: Optional[str] = None,
    file_content_type: Optional[str] = None,
) -> tuple[bytes, str]:
    """Invoke a Chutes chute (directly or via the e2ee-proxy) and return raw bytes."""
    url, extra_body = _audio_request_target(chute, cord)
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }

    if _traffic_mode() == "e2ee-proxy" and cord == TTS_CORD:
        data = json.dumps({**extra_body, **_proxy_tts_payload(chute, payload)}).encode("utf-8")
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "audio/*,application/json;q=0.9"
    elif _traffic_mode() == "e2ee-proxy" and cord == STT_CORD:
        if file_bytes is None:
            raise HTTPException(status_code=500, detail="Proxy STT invocation requires uploaded audio bytes")
        data, multipart_content_type = _encode_multipart_form_data(
            {**extra_body, **_proxy_stt_fields(chute)},
            "file",
            filename or "audio",
            file_content_type or "application/octet-stream",
            file_bytes,
        )
        headers["Content-Type"] = multipart_content_type
    else:
        data = json.dumps({**extra_body, **payload}).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(
        url,
        data=data,
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read(), resp.headers.get("Content-Type", "")


async def _invoke_audio_request_async(
    chute: dict,
    cord: str,
    payload: dict,
    token: str,
    timeout: int = 30,
    file_bytes: Optional[bytes] = None,
    filename: Optional[str] = None,
    file_content_type: Optional[str] = None,
) -> tuple[bytes, str]:
    """Run blocking stdlib HTTP off the FastAPI event loop."""

    return await asyncio.to_thread(
        _invoke_audio_request,
        chute,
        cord,
        payload,
        token,
        timeout=timeout,
        file_bytes=file_bytes,
        filename=filename,
        file_content_type=file_content_type,
    )


def _schedule_warmup_chute(name: str, token: str) -> None:
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        _warmup_chute(name, token)
        return
    loop.create_task(asyncio.to_thread(_warmup_chute, name, token))


async def _invoke_tts_with_retries(tts: dict, payload: dict, token: str) -> tuple[bytes, str]:
    attempts = _env_int("DROPZONE_AUDIO_TTS_RETRY_ATTEMPTS", 3, minimum=1, maximum=5)
    base_delay = _env_float("DROPZONE_AUDIO_TTS_RETRY_BASE_DELAY_SECONDS", 0.4, maximum=3.0)

    async with _tts_limiter(tts):
        for attempt in range(1, attempts + 1):
            try:
                return await _invoke_audio_request_async(tts, TTS_CORD, payload, token)
            except HTTPException:
                raise
            except urllib.error.HTTPError as e:
                body_excerpt = _http_error_excerpt(e)
                log.warning(
                    "tts upstream http error via %s attempt %d/%d: status=%s reason=%s body=%s",
                    tts.get("name"),
                    attempt,
                    attempts,
                    e.code,
                    e.reason,
                    body_excerpt,
                )
                if e.code in TRANSIENT_AUDIO_HTTP_STATUS_CODES and attempt < attempts:
                    await asyncio.sleep(base_delay * attempt)
                    continue
                detail = f"TTS chute error after {attempt} attempt(s): {e.reason}"
                raise HTTPException(status_code=e.code, detail=detail)
            except Exception as e:
                log.warning(
                    "tts invocation error via %s attempt %d/%d: %s",
                    tts.get("name"),
                    attempt,
                    attempts,
                    e,
                )
                if attempt < attempts:
                    await asyncio.sleep(base_delay * attempt)
                    continue
                raise HTTPException(status_code=502, detail=f"TTS invocation failed after {attempt} attempt(s): {e}")

    raise HTTPException(status_code=502, detail="TTS invocation failed")


MAX_TTS_INPUT_LENGTH = 10_000  # characters
MAX_STT_UPLOAD_BYTES = 25 * 1024 * 1024  # 25 MB
UPLOAD_READ_CHUNK_BYTES = 1024 * 1024  # 1 MB


class TTSRequest(BaseModel):
    model: Optional[str] = "kokoro"
    input: str
    voice: Optional[str] = "af_heart"
    response_format: Optional[str] = "mp3"


async def _read_upload_limited(file: UploadFile, max_bytes: int) -> bytes:
    chunks = []
    total = 0

    while True:
        chunk = await file.read(UPLOAD_READ_CHUNK_BYTES)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise HTTPException(
                status_code=413,
                detail=f"Audio upload exceeds {max_bytes // (1024 * 1024)} MB",
            )
        chunks.append(chunk)

    return b"".join(chunks)


@router.post("/audio/speech")
async def text_to_speech(request: Request, body: TTSRequest, user=Depends(_resolve_user), db: Session = Depends(get_session)):
    if len(body.input) > MAX_TTS_INPUT_LENGTH:
        raise HTTPException(status_code=413, detail=f"TTS input exceeds {MAX_TTS_INPUT_LENGTH} characters")

    discovery = await _discover_chutes_async()
    tts = _select_audio_chute("tts", body.model, discovery)

    token = _get_oauth_token(user, db)
    if not token:
        raise HTTPException(status_code=401, detail="No Chutes session — sign in with Chutes SSO")

    # On-demand warmup: if the chute looks cold, nudge it with the user's own token
    if tts.get("score", 0) < 0.01:
        _schedule_warmup_chute(tts["name"], token)

    started = time.time()
    raw, upstream_content_type = await _invoke_tts_with_retries(
        tts,
        {
            "text": body.input,
            "voice": body.voice or "af_heart",
            "response_format": body.response_format or "wav",
        },
        token,
    )
    log.info(
        "tts generated via %s in %.2fs (%d bytes)",
        tts.get("name"),
        time.time() - started,
        len(raw),
    )

    # Chutes TTS returns raw audio bytes or JSON with base64
    content_type = _default_audio_content_type(body.response_format, upstream_content_type)
    try:
        result = json.loads(raw)
        if "audio_b64" in result:
            audio_bytes = base64.b64decode(result["audio_b64"])
            return Response(
                content=audio_bytes,
                media_type=_default_audio_content_type(body.response_format, result.get("content_type", content_type)),
            )
        if "video_b64" in result:
            # Some chutes return data URI
            data_uri = result["video_b64"]
            if "," in data_uri:
                audio_bytes = base64.b64decode(data_uri.split(",", 1)[1])
            else:
                audio_bytes = base64.b64decode(data_uri)
            return Response(
                content=audio_bytes,
                media_type=_default_audio_content_type(body.response_format, result.get("content_type", content_type)),
            )
    except (json.JSONDecodeError, ValueError):
        pass

    # Raw audio response
    return Response(content=raw, media_type=content_type)


@router.post("/audio/transcriptions")
async def speech_to_text(
    request: Request,
    file: UploadFile = File(...),
    model: Optional[str] = Form("whisper-large-v3"),
    user=Depends(_resolve_user),
    db: Session = Depends(get_session),
):
    discovery = await _discover_chutes_async()
    stt = _select_audio_chute("stt", model, discovery)

    token = _get_oauth_token(user, db)
    if not token:
        raise HTTPException(status_code=401, detail="No Chutes session — sign in with Chutes SSO")

    if stt.get("score", 0) < 0.01:
        _schedule_warmup_chute(stt["name"], token)

    upload_filename = file.filename or "audio"
    upload_content_type = file.content_type or "application/octet-stream"
    try:
        audio_data = await _read_upload_limited(file, MAX_STT_UPLOAD_BYTES)
    finally:
        await file.close()

    audio_b64 = base64.b64encode(audio_data).decode("ascii")

    try:
        started = time.time()
        raw, _ = await _invoke_audio_request_async(
            stt,
            STT_CORD,
            {
                "audio_b64": audio_b64,
            },
            token,
            file_bytes=audio_data,
            filename=upload_filename,
            file_content_type=upload_content_type,
        )
        log.info(
            "stt transcribed via %s in %.2fs (%d upload bytes)",
            stt.get("name"),
            time.time() - started,
            len(audio_data),
        )
    except urllib.error.HTTPError as e:
        raise HTTPException(status_code=e.code, detail=f"STT chute error: {e.reason}")
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"STT invocation failed: {e}")

    # Whisper chute returns a list of chunks: [{"start", "end", "text"}, ...]
    try:
        result = json.loads(raw)
        if isinstance(result, list):
            text = " ".join(chunk.get("text", "").strip() for chunk in result if isinstance(chunk, dict))
        elif isinstance(result, dict):
            text = result.get("text", "")
        else:
            text = str(result)
    except (json.JSONDecodeError, ValueError):
        text = raw.decode("utf-8", errors="replace")

    # OpenAI-compatible response
    return {"text": text.strip()}


@router.get("/discovery")
async def audio_discovery(user=Depends(get_verified_user)):
    """Show currently discovered TTS/STT chutes."""
    discovery = await _discover_chutes_async()
    return {
        "tts": discovery.get("tts"),
        "stt": discovery.get("stt"),
    }
