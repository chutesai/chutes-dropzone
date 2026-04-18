"""
Dropzone auth handoff routes for Chutes-first login.

Mounted by patch-openwebui-runtime.py into the OpenWebUI app.
"""

import logging
import os
import urllib.parse

from fastapi import APIRouter, Request
from fastapi.responses import RedirectResponse

log = logging.getLogger(__name__)

router = APIRouter(tags=["dropzone-auth"])

AUTH_HANDOFF_PATH = "/api/v1/dropzone/chutes-login"
CHUTES_AUTH_URL = os.environ.get("CHUTES_AUTH_URL", "https://chutes.ai/auth").strip()
WRAPPED_AUTHORIZE_HOSTS = frozenset({"api.chutes.ai", "idp.chutes.ai"})


def _normalize_redirect_path(value: str | None) -> str | None:
    if not value:
        return None

    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme or parsed.netloc:
        return None

    path = parsed.path or ""
    if not path.startswith("/") or path.startswith("//"):
        return None

    normalized = urllib.parse.urlunsplit(("", "", path, parsed.query, parsed.fragment))
    return normalized or None


def _wrap_authorize_url(authorize_url: str, redirect_path: str | None) -> str:
    if not CHUTES_AUTH_URL:
        return authorize_url

    try:
        parsed_authorize = urllib.parse.urlparse(authorize_url)
        if parsed_authorize.hostname not in WRAPPED_AUTHORIZE_HOSTS:
            return authorize_url

        parsed_auth = urllib.parse.urlparse(CHUTES_AUTH_URL)
        params = urllib.parse.parse_qsl(parsed_auth.query, keep_blank_values=True)
        if redirect_path:
            params.append(("redirect-path", redirect_path))
        params.append(("redirect_to", authorize_url))
        return urllib.parse.urlunparse(parsed_auth._replace(query=urllib.parse.urlencode(params)))
    except Exception as exc:
        log.warning("Failed to wrap authorize URL %s: %s", authorize_url, exc)
        return authorize_url


async def _start_chutes_login(request: Request, redirect_path: str | None):
    oauth_manager = getattr(request.app.state, "oauth_manager", None)
    if oauth_manager is None:
        log.warning("OpenWebUI oauth_manager is unavailable; falling back to native OIDC login")
        return RedirectResponse(url="/oauth/oidc/login", status_code=302)

    oidc_response = await oauth_manager.handle_login(request, "oidc")
    authorize_url = oidc_response.headers.get("location")
    if not authorize_url:
        return oidc_response

    wrapped_url = _wrap_authorize_url(authorize_url, redirect_path)
    if wrapped_url == authorize_url:
        return oidc_response

    response = RedirectResponse(url=wrapped_url, status_code=oidc_response.status_code)
    for key, value in oidc_response.raw_headers:
        header_name = key.decode("latin-1").lower()
        if header_name in {"content-length", "location"}:
            continue
        response.raw_headers.append((key, value))
    response.headers["Cache-Control"] = "no-store"
    return response


@router.get("/auth", include_in_schema=False)
@router.get("/auth/", include_in_schema=False)
async def auth_handoff(request: Request):
    return await _start_chutes_login(
        request, _normalize_redirect_path(request.query_params.get("redirect"))
    )


@router.get(AUTH_HANDOFF_PATH, include_in_schema=False)
async def chutes_login_handoff(request: Request):
    return await _start_chutes_login(
        request, _normalize_redirect_path(request.query_params.get("redirect"))
    )
