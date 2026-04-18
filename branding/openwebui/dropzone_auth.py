"""
Dropzone auth handoff routes for Chutes-first login.

Mounted by patch-openwebui-runtime.py into the OpenWebUI app.
"""

import html
import logging
import os
import urllib.parse
from functools import lru_cache
from pathlib import Path
from string import Template

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse

log = logging.getLogger(__name__)

router = APIRouter(tags=["dropzone-auth"])

AUTH_HANDOFF_PATH = "/api/v1/dropzone/chutes-login"
AUTH_REDIRECT_COOKIE_NAME = "dropzone-auth-redirect"
AUTH_REDIRECT_COOKIE_MAX_AGE = 900
DEFAULT_AUTH_REDIRECT = "/c/new"
CHUTES_AUTH_URL = os.environ.get("CHUTES_AUTH_URL", "https://chutes.ai/auth").strip()
AUTH_PAGE_TEMPLATE_PATH = Path(__file__).with_name("dropzone_auth_page.html")


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


def _resolve_redirect_path(value: str | None) -> str:
    return _normalize_redirect_path(value) or DEFAULT_AUTH_REDIRECT


def _copy_passthrough_headers(response, upstream_response) -> None:
    for key, value in upstream_response.raw_headers:
        header_name = key.decode("latin-1").lower()
        if header_name in {"content-length", "location"}:
            continue
        response.raw_headers.append((key, value))
    response.headers["Cache-Control"] = "no-store"


def _set_auth_redirect_cookie(request: Request, response, redirect_path: str | None) -> None:
    target = _resolve_redirect_path(redirect_path)
    response.set_cookie(
        AUTH_REDIRECT_COOKIE_NAME,
        urllib.parse.quote(target, safe=""),
        max_age=AUTH_REDIRECT_COOKIE_MAX_AGE,
        path="/",
        secure=request.url.scheme == "https",
        httponly=False,
        samesite="lax",
    )


def _build_auth_route_url(path: str, params: list[tuple[str, str]] | None = None) -> str:
    parsed_auth = urllib.parse.urlparse(CHUTES_AUTH_URL or "https://chutes.ai/auth")
    existing = urllib.parse.parse_qsl(parsed_auth.query, keep_blank_values=True)
    query = urllib.parse.urlencode(existing + (params or []))
    return urllib.parse.urlunparse(
        parsed_auth._replace(path=path, params="", query=query, fragment="")
    )


def _build_redirect_params(authorize_url: str, redirect_path: str | None) -> list[tuple[str, str]]:
    params = [("redirect_to", authorize_url)]
    if redirect_path:
        params.append(("redirect-path", redirect_path))
    return params


@lru_cache(maxsize=1)
def _load_auth_page_template() -> Template:
    return Template(AUTH_PAGE_TEMPLATE_PATH.read_text(encoding="utf-8"))


def _build_fingerprint_form_context(authorize_url: str) -> dict[str, str]:
    parsed = urllib.parse.urlsplit(authorize_url)
    if not parsed.scheme or not parsed.netloc:
        raise ValueError("OIDC authorize URL is missing an origin")

    query = dict(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True))
    if not query.get("client_id") or not query.get("redirect_uri"):
        raise ValueError("OIDC authorize URL is missing required login parameters")

    return {
        "action_url": urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, "/idp/login", "", "")),
        "client_id": query.get("client_id", ""),
        "redirect_uri": query.get("redirect_uri", ""),
        "state": query.get("state", ""),
        "scope": query.get("scope", ""),
        "code_challenge": query.get("code_challenge", ""),
        "code_challenge_method": query.get("code_challenge_method", ""),
    }


def _render_auth_page(
    *,
    fingerprint_action_url: str,
    fingerprint_client_id: str,
    fingerprint_redirect_uri: str,
    fingerprint_state: str,
    fingerprint_scope: str,
    fingerprint_code_challenge: str,
    fingerprint_code_challenge_method: str,
    auth_start_url: str,
    auth_reset_url: str,
    google_signin_url: str,
    github_signin_url: str,
    error_message: str | None,
) -> str:
    error_html = ""
    if error_message:
        error_html = f'<p class="notice" role="alert">{html.escape(error_message)}</p>'

    template = _load_auth_page_template()
    return template.safe_substitute(
        fingerprint_action_url=html.escape(fingerprint_action_url, quote=True),
        fingerprint_client_id=html.escape(fingerprint_client_id, quote=True),
        fingerprint_redirect_uri=html.escape(fingerprint_redirect_uri, quote=True),
        fingerprint_state=html.escape(fingerprint_state, quote=True),
        fingerprint_scope=html.escape(fingerprint_scope, quote=True),
        fingerprint_code_challenge=html.escape(fingerprint_code_challenge, quote=True),
        fingerprint_code_challenge_method=html.escape(
            fingerprint_code_challenge_method, quote=True
        ),
        auth_start_url=html.escape(auth_start_url, quote=True),
        auth_reset_url=html.escape(auth_reset_url, quote=True),
        google_signin_url=html.escape(google_signin_url, quote=True),
        github_signin_url=html.escape(github_signin_url, quote=True),
        error_html=error_html,
    )


async def _begin_chutes_login(request: Request):
    oauth_manager = getattr(request.app.state, "oauth_manager", None)
    if oauth_manager is None:
        log.warning("OpenWebUI oauth_manager is unavailable; falling back to native OIDC login")
        return None, RedirectResponse(url="/oauth/oidc/login", status_code=302)

    oidc_response = await oauth_manager.handle_login(request, "oidc")
    authorize_url = oidc_response.headers.get("location")
    if not authorize_url:
        return None, oidc_response

    return authorize_url, oidc_response


async def _start_chutes_login(request: Request, redirect_path: str | None):
    authorize_url, oidc_response = await _begin_chutes_login(request)
    if not authorize_url:
        _set_auth_redirect_cookie(request, oidc_response, redirect_path)
        return oidc_response

    _set_auth_redirect_cookie(request, oidc_response, redirect_path)
    return oidc_response


@router.get("/auth", include_in_schema=False)
@router.get("/auth/", include_in_schema=False)
async def auth_handoff(request: Request):
    redirect_path = _resolve_redirect_path(request.query_params.get("redirect"))
    authorize_url, oidc_response = await _begin_chutes_login(request)
    if not authorize_url:
        _set_auth_redirect_cookie(request, oidc_response, redirect_path)
        return oidc_response

    parsed_auth = urllib.parse.urlparse(CHUTES_AUTH_URL or "https://chutes.ai/auth")
    auth_path = parsed_auth.path.rstrip("/") or "/auth"
    redirect_params = _build_redirect_params(authorize_url, redirect_path)
    fingerprint_context = _build_fingerprint_form_context(authorize_url)
    # Fingerprint posts straight to the Chutes IDP; social providers still reuse
    # the chutes-web callback contract so they land back on our OIDC flow.
    callback_url = _build_auth_route_url(
        f"{auth_path}/callback",
        redirect_params,
    )
    try:
        auth_page = _render_auth_page(
            fingerprint_action_url=fingerprint_context["action_url"],
            fingerprint_client_id=fingerprint_context["client_id"],
            fingerprint_redirect_uri=fingerprint_context["redirect_uri"],
            fingerprint_state=fingerprint_context["state"],
            fingerprint_scope=fingerprint_context["scope"],
            fingerprint_code_challenge=fingerprint_context["code_challenge"],
            fingerprint_code_challenge_method=fingerprint_context[
                "code_challenge_method"
            ],
            auth_start_url=_build_auth_route_url(f"{auth_path}/start", redirect_params),
            auth_reset_url=_build_auth_route_url(f"{auth_path}/reset"),
            google_signin_url=_build_auth_route_url(
                f"{auth_path}/signin/google", [("callbackUrl", callback_url)]
            ),
            github_signin_url=_build_auth_route_url(
                f"{auth_path}/signin/github", [("callbackUrl", callback_url)]
            ),
            error_message=request.query_params.get("error"),
        )
    except Exception:
        log.exception("Failed to render Dropzone auth page; falling back to direct Chutes auth")
        _set_auth_redirect_cookie(request, oidc_response, redirect_path)
        return oidc_response

    response = HTMLResponse(auth_page)
    _copy_passthrough_headers(response, oidc_response)
    _set_auth_redirect_cookie(request, response, redirect_path)
    return response


@router.get(AUTH_HANDOFF_PATH, include_in_schema=False)
async def chutes_login_handoff(request: Request):
    return await _start_chutes_login(request, _resolve_redirect_path(request.query_params.get("redirect")))
