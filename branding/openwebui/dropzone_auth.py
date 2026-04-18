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
CHUTES_AUTH_URL = os.environ.get("CHUTES_AUTH_URL", "https://chutes.ai/auth").strip()
CHUTES_IDP_BASE_URL = os.environ.get("CHUTES_IDP_BASE_URL", "").strip()
OPENID_PROVIDER_URL = os.environ.get("OPENID_PROVIDER_URL", "").strip()
DEFAULT_WRAPPED_AUTHORIZE_HOSTS = frozenset({"api.chutes.ai", "idp.chutes.ai"})
WRAPPED_AUTHORIZE_PATHS = frozenset({"/idp/authorize"})
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


def _wrap_authorize_url(authorize_url: str, redirect_path: str | None) -> str:
    if not CHUTES_AUTH_URL:
        return authorize_url

    try:
        if not _is_wrapped_authorize_url(authorize_url):
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


def _hostname_from_url(url: str) -> str | None:
    if not url:
        return None

    return urllib.parse.urlparse(url).hostname


@lru_cache(maxsize=1)
def _wrapped_authorize_hosts() -> frozenset[str]:
    hosts = set(DEFAULT_WRAPPED_AUTHORIZE_HOSTS)
    for candidate in (CHUTES_IDP_BASE_URL, OPENID_PROVIDER_URL):
        host = _hostname_from_url(candidate)
        if host:
            hosts.add(host)
    return frozenset(hosts)


def _is_wrapped_authorize_url(authorize_url: str) -> bool:
    parsed_authorize = urllib.parse.urlparse(authorize_url)
    path = parsed_authorize.path.rstrip("/") or "/"
    return (
        parsed_authorize.hostname in _wrapped_authorize_hosts()
        and path in WRAPPED_AUTHORIZE_PATHS
    )


def _copy_passthrough_headers(response, upstream_response) -> None:
    for key, value in upstream_response.raw_headers:
        header_name = key.decode("latin-1").lower()
        if header_name in {"content-length", "location"}:
            continue
        response.raw_headers.append((key, value))
    response.headers["Cache-Control"] = "no-store"


def _build_wrapped_authorize_response(authorize_url: str, oidc_response, redirect_path: str | None):
    wrapped_url = _wrap_authorize_url(authorize_url, redirect_path)
    if wrapped_url == authorize_url:
        return oidc_response

    response = RedirectResponse(url=wrapped_url, status_code=oidc_response.status_code)
    _copy_passthrough_headers(response, oidc_response)
    return response


def _build_auth_route_url(path: str, params: list[tuple[str, str]] | None = None) -> str:
    parsed_auth = urllib.parse.urlparse(CHUTES_AUTH_URL)
    existing = urllib.parse.parse_qsl(parsed_auth.query, keep_blank_values=True)
    query = urllib.parse.urlencode(existing + (params or []))
    return urllib.parse.urlunparse(
        parsed_auth._replace(path=path, params="", query=query, fragment="")
    )


def _build_auth_action_url(params: list[tuple[str, str]]) -> str:
    parsed_auth = urllib.parse.urlparse(CHUTES_AUTH_URL)
    existing = urllib.parse.parse_qsl(parsed_auth.query, keep_blank_values=True)
    query = "/login"
    if existing:
        query += "&" + urllib.parse.urlencode(existing)
    if params:
        query += "&" + urllib.parse.urlencode(params)
    return urllib.parse.urlunparse(
        parsed_auth._replace(params="", query=query, fragment="")
    )


def _build_redirect_params(authorize_url: str, redirect_path: str | None) -> list[tuple[str, str]]:
    params = [("redirect_to", authorize_url)]
    if redirect_path:
        params.append(("redirect-path", redirect_path))
    return params


@lru_cache(maxsize=1)
def _load_auth_page_template() -> Template:
    return Template(AUTH_PAGE_TEMPLATE_PATH.read_text(encoding="utf-8"))


def _render_auth_page(
    *,
    auth_start_url: str,
    auth_reset_url: str,
    google_signin_url: str,
    github_signin_url: str,
    fingerprint_action_url: str,
    error_message: str | None,
) -> str:
    error_html = ""
    if error_message:
        error_html = f'<p class="notice" role="alert">{html.escape(error_message)}</p>'

    template = _load_auth_page_template()
    return template.safe_substitute(
        auth_start_url=html.escape(auth_start_url, quote=True),
        auth_reset_url=html.escape(auth_reset_url, quote=True),
        google_signin_url=html.escape(google_signin_url, quote=True),
        github_signin_url=html.escape(github_signin_url, quote=True),
        fingerprint_action_url=html.escape(fingerprint_action_url, quote=True),
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
        return oidc_response

    return _build_wrapped_authorize_response(authorize_url, oidc_response, redirect_path)


@router.get("/auth", include_in_schema=False)
@router.get("/auth/", include_in_schema=False)
async def auth_handoff(request: Request):
    redirect_path = _normalize_redirect_path(request.query_params.get("redirect"))
    authorize_url, oidc_response = await _begin_chutes_login(request)
    if not authorize_url:
        return oidc_response

    parsed_auth = urllib.parse.urlparse(CHUTES_AUTH_URL)
    auth_path = parsed_auth.path.rstrip("/") or "/auth"
    redirect_params = _build_redirect_params(authorize_url, redirect_path)
    callback_url = _build_auth_route_url(
        f"{auth_path}/callback",
        redirect_params,
    )
    try:
        auth_page = _render_auth_page(
            auth_start_url=_build_auth_route_url(f"{auth_path}/start", redirect_params),
            auth_reset_url=_build_auth_route_url(f"{auth_path}/reset"),
            google_signin_url=_build_auth_route_url(
                f"{auth_path}/signin/google", [("callbackUrl", callback_url)]
            ),
            github_signin_url=_build_auth_route_url(
                f"{auth_path}/signin/github", [("callbackUrl", callback_url)]
            ),
            fingerprint_action_url=_build_auth_action_url(redirect_params),
            error_message=request.query_params.get("error"),
        )
    except Exception:
        log.exception("Failed to render Dropzone auth page; falling back to direct Chutes auth")
        return _build_wrapped_authorize_response(authorize_url, oidc_response, redirect_path)

    response = HTMLResponse(auth_page)
    _copy_passthrough_headers(response, oidc_response)
    return response


@router.get(AUTH_HANDOFF_PATH, include_in_schema=False)
async def chutes_login_handoff(request: Request):
    return await _start_chutes_login(
        request, _normalize_redirect_path(request.query_params.get("redirect"))
    )
