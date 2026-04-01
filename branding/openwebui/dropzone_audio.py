"""
OpenAI-compatible audio adapter for Chutes TTS/STT chutes.

Auto-discovers available TTS and STT chutes from the Chutes utilization API
and translates between OpenAI's /v1/audio/* format and Chutes' invocation format.

Mounted by patch-openwebui-runtime.py into the OpenWebUI app.
"""

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

_cache: dict = {}
_warmup_cache: dict[str, float] = {}


def _fetch_json(url: str, timeout: int = 15):
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except Exception:
        return None


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
    if _cache.get("ts", 0) + CACHE_TTL > now and _cache.get("tts") is not None:
        return _cache

    utilization = _fetch_json(UTILIZATION_URL)
    chutes_list = _fetch_json(f"{CHUTES_LIST_URL}?include_public=true&limit=500")

    if not utilization or not chutes_list:
        if _cache.get("tts"):
            return _cache
        return {"tts": None, "stt": None, "ts": now}

    items = chutes_list.get("items", [])
    slug_map = {}
    for item in items:
        name = item.get("name", "")
        slug_map[name] = item.get("slug", "")

    tts_best = None
    tts_score = -1
    stt_best = None
    stt_score = -1

    for entry in utilization:
        name = entry.get("name", "")
        instances = entry.get("active_instance_count", 0)
        total = entry.get("total_instance_count", 0)
        if instances <= 0 and total <= 0:
            continue
        util_5m = entry.get("utilization_5m", 1.0)
        score = max(instances * (1.0 - util_5m), 0.001) if instances > 0 else 0.0001
        slug = slug_map.get(name, "")

        name_lower = name.lower()
        if any(t in name_lower for t in TTS_TEMPLATES) or name_lower in TTS_TEMPLATES:
            if score > tts_score and slug:
                tts_best = {"name": name, "slug": slug, "score": score}
                tts_score = score

        if any(t in name_lower for t in STT_TEMPLATES) or name_lower in STT_TEMPLATES:
            if score > stt_score and slug:
                stt_best = {"name": name, "slug": slug, "score": score}
                stt_score = score

    result = {"tts": tts_best, "stt": stt_best, "ts": now}
    _cache.update(result)
    log.info(
        "audio discovery: tts=%s stt=%s",
        tts_best["name"] if tts_best else "(none)",
        stt_best["name"] if stt_best else "(none)",
    )
    return result


def _get_oauth_token(user, db) -> str:
    """Get the user's OAuth access token for Chutes API calls."""
    try:
        from open_webui.models.oauth_sessions import OAuthSessions

        session = OAuthSessions.get_session_by_provider_and_user_id("oidc", user.id, db=db)
        if not session:
            sessions = OAuthSessions.get_sessions_by_user_id(user.id, db=db)
            session = sessions[0] if sessions else None
        if session and isinstance(session.token, dict):
            return session.token.get("access_token", "")
    except Exception:
        pass
    return ""


def _invoke_chute(slug: str, cord: str, payload: dict, token: str, timeout: int = 30) -> bytes:
    """Invoke a Chutes chute and return raw response bytes."""
    url = f"https://{slug}.chutes.ai{cord}"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


MAX_TTS_INPUT_LENGTH = 10_000  # characters
MAX_STT_UPLOAD_BYTES = 25 * 1024 * 1024  # 25 MB
UPLOAD_READ_CHUNK_BYTES = 1024 * 1024  # 1 MB


class TTSRequest(BaseModel):
    model: Optional[str] = "kokoro"
    input: str
    voice: Optional[str] = "af_heart"
    response_format: Optional[str] = "wav"


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

    discovery = _discover_chutes()
    tts = discovery.get("tts")
    if not tts:
        raise HTTPException(status_code=503, detail="No TTS chute available")

    token = _get_oauth_token(user, db)
    if not token:
        raise HTTPException(status_code=401, detail="No Chutes session — sign in with Chutes SSO")

    # On-demand warmup: if the chute looks cold, nudge it with the user's own token
    if tts.get("score", 0) < 0.01:
        _warmup_chute(tts["name"], token)

    try:
        raw = _invoke_chute(tts["slug"], TTS_CORD, {
            "text": body.input,
            "voice": body.voice or "af_heart",
        }, token)
    except urllib.error.HTTPError as e:
        raise HTTPException(status_code=e.code, detail=f"TTS chute error: {e.reason}")
    except Exception as e:
        raise HTTPException(status_code=502, detail=f"TTS invocation failed: {e}")

    # Chutes TTS returns raw audio bytes or JSON with base64
    content_type = "audio/wav"
    try:
        result = json.loads(raw)
        if "audio_b64" in result:
            audio_bytes = base64.b64decode(result["audio_b64"])
            return Response(content=audio_bytes, media_type=content_type)
        if "video_b64" in result:
            # Some chutes return data URI
            data_uri = result["video_b64"]
            if "," in data_uri:
                audio_bytes = base64.b64decode(data_uri.split(",", 1)[1])
            else:
                audio_bytes = base64.b64decode(data_uri)
            return Response(content=audio_bytes, media_type=content_type)
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
    discovery = _discover_chutes()
    stt = discovery.get("stt")
    if not stt:
        raise HTTPException(status_code=503, detail="No STT chute available")

    token = _get_oauth_token(user, db)
    if not token:
        raise HTTPException(status_code=401, detail="No Chutes session — sign in with Chutes SSO")

    if stt.get("score", 0) < 0.01:
        _warmup_chute(stt["name"], token)

    try:
        audio_data = await _read_upload_limited(file, MAX_STT_UPLOAD_BYTES)
    finally:
        await file.close()

    audio_b64 = base64.b64encode(audio_data).decode("ascii")

    try:
        raw = _invoke_chute(stt["slug"], STT_CORD, {
            "audio_b64": audio_b64,
        }, token)
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
    discovery = _discover_chutes()
    return {
        "tts": discovery.get("tts"),
        "stt": discovery.get("stt"),
    }
