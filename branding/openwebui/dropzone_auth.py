"""
Dropzone auth handoff routes for Chutes-first login.

Mounted by patch-openwebui-runtime.py into the OpenWebUI app.
"""

import json
import logging
import os
import urllib.parse
from pathlib import Path

from fastapi import APIRouter, Request
from fastapi.responses import FileResponse, HTMLResponse, RedirectResponse, Response

log = logging.getLogger(__name__)

router = APIRouter(tags=["dropzone-auth"])

AUTH_HANDOFF_PATH = "/api/v1/dropzone/chutes-login"
CHUTES_AUTH_URL = os.environ.get("CHUTES_AUTH_URL", "https://chutes.ai/auth").strip()
OPENWEBUI_INDEX_PATH = Path(os.environ.get("DROPZONE_OPENWEBUI_INDEX_PATH", "/app/build/index.html"))
WRAPPED_AUTHORIZE_HOSTS = frozenset({"api.chutes.ai", "idp.chutes.ai"})


def _auth_shell() -> Response:
    if OPENWEBUI_INDEX_PATH.is_file():
        response = FileResponse(OPENWEBUI_INDEX_PATH, media_type="text/html")
        response.headers["Cache-Control"] = "no-store"
        return response
    log.warning("OpenWebUI index shell missing at %s", OPENWEBUI_INDEX_PATH)
    return HTMLResponse("<!doctype html><title>Auth unavailable</title>", status_code=503)


def _auth_handoff_page(redirect_path: str | None) -> str:
    redirect_json = json.dumps(redirect_path)
    handoff_path = json.dumps(AUTH_HANDOFF_PATH)
    return f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="robots" content="noindex,nofollow" />
    <meta http-equiv="Cache-Control" content="no-store" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Redirecting...</title>
    <style>
      html, body {{
        height: 100%;
        margin: 0;
        background: #050505;
        color: #f8f8f7;
        font: 16px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      }}
      body {{
        display: grid;
        place-items: center;
      }}
      .status {{
        opacity: 0.72;
      }}
    </style>
  </head>
  <body>
    <div class="status">Redirecting to Chutes...</div>
    <script>
      const redirectPath = {redirect_json};
      if (redirectPath) {{
        try {{
          localStorage.setItem("redirectPath", redirectPath);
        }} catch (error) {{
          console.warn("Unable to persist redirectPath", error);
        }}
      }}
      window.location.replace({handoff_path});
    </script>
  </body>
</html>
"""


def _wrap_authorize_url(authorize_url: str) -> str:
    if not CHUTES_AUTH_URL:
        return authorize_url

    try:
        parsed_authorize = urllib.parse.urlparse(authorize_url)
        if parsed_authorize.hostname not in WRAPPED_AUTHORIZE_HOSTS:
            return authorize_url

        parsed_auth = urllib.parse.urlparse(CHUTES_AUTH_URL)
        params = urllib.parse.parse_qsl(parsed_auth.query, keep_blank_values=True)
        params.append(("redirect_to", authorize_url))
        return urllib.parse.urlunparse(parsed_auth._replace(query=urllib.parse.urlencode(params)))
    except Exception as exc:
        log.warning("Failed to wrap authorize URL %s: %s", authorize_url, exc)
        return authorize_url


@router.get("/auth", include_in_schema=False)
@router.get("/auth/", include_in_schema=False)
async def auth_handoff(request: Request):
    if request.cookies.get("token") or request.query_params.get("error"):
        return _auth_shell()

    response = HTMLResponse(_auth_handoff_page(request.query_params.get("redirect")))
    response.headers["Cache-Control"] = "no-store"
    return response


@router.get(AUTH_HANDOFF_PATH, include_in_schema=False)
async def chutes_login_handoff(request: Request):
    oauth_manager = getattr(request.app.state, "oauth_manager", None)
    if oauth_manager is None:
        log.warning("OpenWebUI oauth_manager is unavailable; falling back to native OIDC login")
        return RedirectResponse(url="/oauth/oidc/login", status_code=302)

    oidc_response = await oauth_manager.handle_login(request, "oidc")
    authorize_url = oidc_response.headers.get("location")
    if not authorize_url:
        return oidc_response

    wrapped_url = _wrap_authorize_url(authorize_url)
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
