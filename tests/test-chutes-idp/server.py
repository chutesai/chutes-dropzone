#!/usr/bin/env python3

import json
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer


CLIENT_ID = os.environ.get("TEST_CHUTES_CLIENT_ID", "test-client")
CLIENT_SECRET = os.environ.get("TEST_CHUTES_CLIENT_SECRET", "test secret")
GRANTED_SCOPE = os.environ.get(
    "TEST_CHUTES_GRANTED_SCOPE",
    "openid profile chutes:read chutes:invoke",
)
SUPPORTED_SCOPES = {
    "openid",
    "profile",
    "account:read",
    "chutes:read",
    "chutes:invoke",
    "images:read",
    "invocations:read",
}
REDIRECT_URIS = {
    uri.strip()
    for uri in os.environ.get(
        "TEST_CHUTES_REDIRECT_URIS",
        "https://e2ee-local-proxy.chutes.dev/rest/sso/chutes/callback,"
        "https://e2ee-local-proxy.chutes.dev/oauth/oidc/callback,"
        "https://e2ee-local-proxy.chutes.dev/chat/oauth/oidc/callback",
    ).split(",")
    if uri.strip()
}
USERS = {
    "member-code": {
        "sub": "sub-member",
        "username": "member-user",
        "logo": "https://cdn.rayonlabs.ai/chutes/default-avatar.webp",
        "permissions_bitmask": 0,
        "created_at": "2026-01-01T00:00:00Z",
    },
    "admin-code": {
        "sub": "sub-admin",
        "username": "admin-user",
        "logo": "https://cdn.rayonlabs.ai/chutes/default-avatar.webp",
        "permissions_bitmask": 19,
        "created_at": "2026-01-02T00:00:00Z",
    },
}
USER_QUOTAS = {
    "member-code": [{"chute_id": "*", "quota": 5001, "is_default": True}],
    "admin-code": [{"chute_id": "*", "quota": 50000, "is_default": True}],
}
USER_LIVE_QUOTAS = {
    "member-code": {"used": 1284.9, "quota": 5001},
    "admin-code": {"used": 190.25, "quota": 50000},
}
CHUTES = [
    {
        "chute_id": "chute-llm-1",
        "name": "DeepSeek V3",
        "tagline": "Fast text generation",
        "description": "Local test LLM chute",
        "slug": "llm-member",
        "standard_template": "vllm",
        "user": {"username": "member-user"},
        "public": True,
    },
    {
        "chute_id": "chute-image-1",
        "name": "Qwen Image Edit",
        "tagline": "Image generation and editing",
        "description": "Local test image chute",
        "slug": "image-member",
        "standard_template": "diffusion",
        "user": {"username": "member-user"},
        "public": True,
    },
]


def extract_code_from_access_token(token):
    if not token.startswith("token:"):
        return None
    return token.removeprefix("token:").split(":", 1)[0].strip()


def parse_refresh_token(token):
    if not token.startswith("refresh:"):
        return None, None

    parts = token.split(":")
    if len(parts) < 2:
        return None, None

    code = parts[1].strip()
    generation = 0
    if len(parts) >= 3 and parts[2]:
        try:
            generation = int(parts[2])
        except ValueError:
            return None, None

    return code, generation


class Handler(BaseHTTPRequestHandler):
    server_version = "FakeChutesIdP/1.0"

    def log_message(self, fmt, *args):
        return

    def json_response(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def parse_form(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        return urllib.parse.parse_qs(body, keep_blank_values=True)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)

        if parsed.path == "/healthz":
            return self.json_response(200, {"status": "ok"})

        if parsed.path == "/.well-known/openid-configuration":
            issuer = "http://test-chutes-idp:8080"
            return self.json_response(
                200,
                {
                    "issuer": issuer,
                    "authorization_endpoint": f"{issuer}/idp/authorize",
                    "token_endpoint": f"{issuer}/idp/token",
                    "userinfo_endpoint": f"{issuer}/idp/userinfo",
                    "revocation_endpoint": f"{issuer}/idp/token/revoke",
                    "introspection_endpoint": f"{issuer}/idp/token/introspect",
                    "scopes_supported": sorted(SUPPORTED_SCOPES),
                    "response_types_supported": ["code"],
                    "response_modes_supported": ["query"],
                    "grant_types_supported": ["authorization_code", "refresh_token"],
                    "token_endpoint_auth_methods_supported": [
                        "client_secret_post",
                        "client_secret_basic",
                        "none",
                    ],
                    "code_challenge_methods_supported": ["plain", "S256"],
                    "subject_types_supported": ["public"],
                    "claims_supported": [
                        "sub",
                        "username",
                        "created_at",
                    ],
                },
            )

        if parsed.path == "/idp/authorize":
            redirect_uri = query.get("redirect_uri", [""])[0]
            state = query.get("state", [""])[0]
            code = query.get("mock_code", [query.get("login_hint", ["member-code"])[0]])[0]
            requested_scopes = [
                scope for scope in query.get("scope", [""])[0].split() if scope
            ]

            if not redirect_uri:
                return self.json_response(400, {"error": "missing_redirect_uri"})
            if REDIRECT_URIS and redirect_uri not in REDIRECT_URIS:
                return self.json_response(400, {"error": "invalid_redirect_uri"})
            unsupported_scopes = [
                scope for scope in requested_scopes if scope not in SUPPORTED_SCOPES
            ]
            if unsupported_scopes:
                target = (
                    f"{redirect_uri}?error=invalid_scope"
                    f"&error_description={urllib.parse.quote(f'Unknown scope: {unsupported_scopes[0]}')}"
                    f"&state={urllib.parse.quote(state)}"
                )
                return self.redirect(target)

            target = f"{redirect_uri}?code={urllib.parse.quote(code)}&state={urllib.parse.quote(state)}"
            return self.redirect(target)

        if parsed.path == "/idp/userinfo":
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ").strip()
            code = extract_code_from_access_token(token)
            user = USERS.get(code)
            if not user:
                return self.json_response(401, {"error": "invalid_token"})
            return self.json_response(200, user)

        if parsed.path == "/users/me":
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ").strip()
            code = extract_code_from_access_token(token)
            user = USERS.get(code)
            if not user:
                return self.json_response(401, {"error": "invalid_token"})
            return self.json_response(200, user)

        if parsed.path == "/users/me/quotas":
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ").strip()
            code = extract_code_from_access_token(token)
            if code not in USERS:
                return self.json_response(401, {"error": "invalid_token"})
            return self.json_response(200, USER_QUOTAS.get(code, []))

        if parsed.path == "/users/me/quota_usage/h":
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ").strip()
            code = extract_code_from_access_token(token)
            if code not in USERS:
                return self.json_response(401, {"error": "invalid_token"})
            return self.json_response(200, USER_LIVE_QUOTAS.get(code, {"used": 0, "quota": 0}))

        if parsed.path == "/v1/models":
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ").strip()
            code = extract_code_from_access_token(token)
            if code not in USERS:
                return self.json_response(401, {"error": "invalid_token"})

            return self.json_response(
                200,
                {
                    "object": "list",
                    "data": [
                        {
                            "id": "deepseek-ai/DeepSeek-V3",
                            "object": "model",
                            "owned_by": code,
                        }
                    ],
                },
            )

        if parsed.path == "/chutes/":
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ").strip()
            code = extract_code_from_access_token(token)
            if code not in USERS:
                return self.json_response(401, {"error": "invalid_token"})

            include_public = query.get("include_public", ["true"])[0].lower() == "true"
            limit = int(query.get("limit", ["500"])[0] or "500")
            items = [item for item in CHUTES if include_public or not item.get("public", False)]
            return self.json_response(
                200,
                {
                    "total": len(items),
                    "page": 1,
                    "limit": limit,
                    "items": items[:limit],
                    "cord_refs": {},
                },
            )

        return self.json_response(404, {"error": "not_found"})

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/v1/chat/completions":
            authorization = self.headers.get("Authorization", "")
            token = authorization.removeprefix("Bearer ").strip()
            code = extract_code_from_access_token(token)
            if code not in USERS:
                return self.json_response(401, {"error": "invalid_token"})

            length = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(length).decode("utf-8")
            try:
                payload = json.loads(raw_body or "{}")
            except json.JSONDecodeError:
                payload = {}

            user_prompt = ""
            for message in payload.get("messages", []):
                if message.get("role") == "user":
                    user_prompt = message.get("content", "")
                    break

            return self.json_response(
                200,
                {
                    "id": "chatcmpl-test",
                    "object": "chat.completion",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": f"hello from test chute: {user_prompt}".strip(),
                            },
                            "finish_reason": "stop",
                        }
                    ],
                },
            )

        if parsed.path != "/idp/token":
            return self.json_response(404, {"error": "not_found"})

        form = self.parse_form()
        client_id = form.get("client_id", [""])[0]
        client_secret = form.get("client_secret", [""])[0]
        code = form.get("code", [""])[0]
        refresh_token = form.get("refresh_token", [""])[0]
        grant_type = form.get("grant_type", [""])[0]
        redirect_uri = form.get("redirect_uri", [""])[0]

        if client_id != CLIENT_ID or client_secret != CLIENT_SECRET:
            return self.json_response(401, {"error": "invalid_client"})

        if grant_type == "authorization_code":
            if code not in USERS:
                return self.json_response(400, {"error": "invalid_grant"})
            if REDIRECT_URIS and redirect_uri not in REDIRECT_URIS:
                return self.json_response(400, {"error": "invalid_grant"})

            return self.json_response(
                200,
                {
                    "access_token": f"token:{code}",
                    "refresh_token": f"refresh:{code}:0",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "scope": GRANTED_SCOPE,
                },
            )

        if grant_type == "refresh_token":
            code, generation = parse_refresh_token(refresh_token)
            if code not in USERS or generation is None:
                return self.json_response(400, {"error": "invalid_grant"})

            return self.json_response(
                200,
                {
                    "access_token": f"token:{code}:refresh:{generation + 1}",
                    "refresh_token": f"refresh:{code}:{generation + 1}",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "scope": GRANTED_SCOPE,
                },
            )

        if grant_type != "authorization_code":
            return self.json_response(400, {"error": "unsupported_grant_type"})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
