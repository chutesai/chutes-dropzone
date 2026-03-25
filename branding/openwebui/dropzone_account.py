from __future__ import annotations

import os
import time
from typing import Any

import requests
from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from open_webui.models.oauth_sessions import OAuthSessionModel, OAuthSessions
from open_webui.models.users import UserModel

CHUTES_API_BASE_URL = (
    os.environ.get("CHUTES_IDP_BASE_URL", "https://api.chutes.ai").rstrip("/")
)
CHUTES_HOME_URL = "https://chutes.ai/"
CHUTES_ACCOUNT_URL = "https://chutes.ai/app/api/billing-balance#daily-quota-usage"
N8N_ENABLED = os.environ.get("DROPZONE_ENABLE_N8N", "true").lower() not in ("false", "0", "no")
ADMIN_PERMISSION_BITMASK = 19
FREE_PERMISSION_BITMASK = 0
DEFAULT_TIMEOUT = 15


def _coerce_float(value: Any) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def _extract_daily_quota(quotas: Any) -> float:
    if not quotas:
        return 0.0

    if isinstance(quotas, list):
        for item in quotas:
            if not isinstance(item, dict):
                continue
            chute_id = item.get("chute_id")
            if chute_id in {"*", "x"} or item.get("is_default"):
                return _coerce_float(item.get("quota"))
        return _coerce_float(quotas[0].get("quota")) if quotas and isinstance(quotas[0], dict) else 0.0

    if isinstance(quotas, dict):
        for key in ("*", "x", "global"):
            if key in quotas:
                return _coerce_float(quotas.get(key))

        for value in quotas.values():
            if isinstance(value, dict) and "quota" in value:
                return _coerce_float(value.get("quota"))
            return _coerce_float(value)

    return 0.0


def _get_tier_from_quota(daily_quota: float) -> str:
    if daily_quota < 200:
        return "free"
    if daily_quota == 200:
        return "early-access"
    if daily_quota == 300:
        return "base"
    if daily_quota == 2000:
        return "plus"
    if daily_quota == 5000:
        return "pro"
    if daily_quota > 5000:
        return "enterprise"
    if daily_quota >= 2500:
        return "pro"
    if daily_quota >= 1000:
        return "plus"
    if daily_quota >= 250:
        return "base"
    if daily_quota >= 100:
        return "early-access"
    return "free"


def _get_tier_label(tier: str, permissions_bitmask: int) -> str:
    if permissions_bitmask == ADMIN_PERMISSION_BITMASK:
        return "Admin"
    if permissions_bitmask != FREE_PERMISSION_BITMASK:
        return "Standard"

    return {
        "free": "Flex",
        "early-access": "Early-Access",
        "base": "Base",
        "plus": "Plus",
        "pro": "Pro",
        "enterprise": "Enterprise",
    }.get(tier, "Flex")


def _normalize_avatar_url(account: dict[str, Any]) -> str | None:
    for key in ("logo", "avatar_url", "profile_image_url"):
        value = account.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def _username_for(account: dict[str, Any], user: UserModel) -> str:
    for candidate in (
        account.get("username"),
        getattr(user, "username", None),
        getattr(user, "name", None),
    ):
        if isinstance(candidate, str) and candidate.strip():
            return candidate.strip()

    if getattr(user, "email", None):
        return user.email.split("@", 1)[0]

    return "Chutes User"


def _request_json(path: str, access_token: str) -> Any:
    response = requests.get(
        f"{CHUTES_API_BASE_URL}{path}",
        headers={"Authorization": f"Bearer {access_token}"},
        timeout=DEFAULT_TIMEOUT,
    )

    if response.status_code == status.HTTP_401_UNAUTHORIZED:
        raise PermissionError("access token rejected by Chutes API")

    if not response.ok:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Chutes API request failed for {path}",
        )

    return response.json()


def _refresh_oauth_session(
    oauth_session: OAuthSessionModel,
    db: Session,
) -> OAuthSessionModel:
    refresh_token = oauth_session.token.get("refresh_token")
    if not refresh_token:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Chutes OAuth session is missing a refresh token",
        )

    client_id = os.environ.get("CHUTES_OAUTH_CLIENT_ID", "").strip() or os.environ.get(
        "OAUTH_CLIENT_ID", ""
    ).strip()
    client_secret = os.environ.get("CHUTES_OAUTH_CLIENT_SECRET", "").strip() or os.environ.get(
        "OAUTH_CLIENT_SECRET", ""
    ).strip()

    if not client_id or not client_secret:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Chutes OAuth client credentials are not configured",
        )

    response = requests.post(
        f"{CHUTES_API_BASE_URL}/idp/token",
        data={
            "grant_type": "refresh_token",
            "client_id": client_id,
            "client_secret": client_secret,
            "refresh_token": refresh_token,
        },
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        timeout=DEFAULT_TIMEOUT,
    )

    if not response.ok:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Failed to refresh the Chutes OAuth session",
        )

    refreshed = response.json()
    access_token = refreshed.get("access_token")
    if not access_token:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Chutes OAuth refresh did not return an access token",
        )

    merged = dict(oauth_session.token)
    merged.update(refreshed)
    if "refresh_token" not in refreshed:
        merged["refresh_token"] = refresh_token
    if isinstance(refreshed.get("expires_in"), int):
        merged["expires_at"] = int(time.time()) + int(refreshed["expires_in"])

    updated = OAuthSessions.update_session_by_id(oauth_session.id, merged, db=db)
    if updated:
        return updated

    oauth_session.token = merged
    return oauth_session


def _current_oauth_session(user_id: str, db: Session) -> OAuthSessionModel | None:
    session = OAuthSessions.get_session_by_provider_and_user_id("oidc", user_id, db=db)
    if session:
        return session

    sessions = OAuthSessions.get_sessions_by_user_id(user_id, db=db)
    return sessions[0] if sessions else None


def _fetch_account_bundle(
    oauth_session: OAuthSessionModel,
    db: Session,
) -> tuple[OAuthSessionModel, dict[str, Any], Any, Any]:
    token = oauth_session.token.get("access_token")
    if not token:
        oauth_session = _refresh_oauth_session(oauth_session, db=db)
        token = oauth_session.token.get("access_token")

    try:
        account = _request_json("/users/me", token)
        quotas = _request_json("/users/me/quotas", token)
        live_quota = _request_json("/users/me/quota_usage/h", token)
        return oauth_session, account, quotas, live_quota
    except PermissionError:
        oauth_session = _refresh_oauth_session(oauth_session, db=db)
        refreshed_token = oauth_session.token.get("access_token")
        account = _request_json("/users/me", refreshed_token)
        quotas = _request_json("/users/me/quotas", refreshed_token)
        live_quota = _request_json("/users/me/quota_usage/h", refreshed_token)
        return oauth_session, account, quotas, live_quota


def get_chutes_account_summary(user: UserModel, db: Session) -> dict[str, Any]:
    oauth_session = _current_oauth_session(user.id, db=db)
    if not oauth_session:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No Chutes OAuth session is linked to this OpenWebUI user",
        )

    _, account, quotas, live_quota = _fetch_account_bundle(oauth_session, db=db)

    permissions_bitmask = int(account.get("permissions_bitmask") or 0)
    daily_quota = _extract_daily_quota(quotas)
    quota_limit = _coerce_float((live_quota or {}).get("quota")) or daily_quota
    quota_used = _coerce_float((live_quota or {}).get("used"))
    quota_remaining = max(quota_limit - quota_used, 0.0)
    quota_percentage = min((quota_used / quota_limit) * 100.0, 100.0) if quota_limit > 0 else 0.0

    tier = "standard" if permissions_bitmask not in (FREE_PERMISSION_BITMASK, ADMIN_PERMISSION_BITMASK) else _get_tier_from_quota(daily_quota)
    if permissions_bitmask == ADMIN_PERMISSION_BITMASK:
        tier = "admin"

    return {
        "username": _username_for(account, user),
        "avatarUrl": _normalize_avatar_url(account),
        "tier": tier,
        "tierLabel": _get_tier_label(tier, permissions_bitmask),
        "balanceUsd": round(_coerce_float(account.get("balance")), 2),
        "quota": {
            "used": round(quota_used, 2),
            "limit": round(quota_limit, 2),
            "remaining": round(quota_remaining, 2),
            "percentage": round(quota_percentage, 2),
        },
        "links": {
            "accountUrl": CHUTES_ACCOUNT_URL,
            "homeUrl": CHUTES_HOME_URL,
            "chatUrl": "/chat/",
            **({"n8nUrl": "/n8n/"} if N8N_ENABLED else {}),
        },
    }
