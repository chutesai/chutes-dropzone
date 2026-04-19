from __future__ import annotations

import logging
from typing import Any

from sqlalchemy.orm import Session

from open_webui.models.oauth_sessions import OAuthSessionModel, OAuthSessions

log = logging.getLogger(__name__)


def get_preferred_oauth_session(
    user_id: str,
    db: Session | None = None,
    provider: str = "oidc",
) -> OAuthSessionModel | None:
    session = OAuthSessions.get_session_by_provider_and_user_id(provider, user_id, db=db)
    if session:
        return session

    sessions = OAuthSessions.get_sessions_by_user_id(user_id, db=db) or []
    if not sessions:
        return None

    return max(
        sessions,
        key=lambda item: (
            int(getattr(item, "updated_at", 0) or 0),
            int(getattr(item, "created_at", 0) or 0),
        ),
    )


def get_user_oauth_access_token(
    user_id: str,
    db: Session | None = None,
    provider: str = "oidc",
) -> str:
    session = get_preferred_oauth_session(user_id, db=db, provider=provider)
    if session and isinstance(session.token, dict):
        return session.token.get("access_token", "")
    return ""


async def get_request_oauth_token(
    request,
    user,
    db: Session | None = None,
    provider: str = "oidc",
) -> dict[str, Any] | None:
    if not user:
        return None

    oauth_manager = getattr(getattr(request.app, "state", None), "oauth_manager", None)
    oauth_session_id = request.cookies.get("oauth_session_id")

    if oauth_manager and oauth_session_id:
        try:
            oauth_token = await oauth_manager.get_oauth_token(user.id, oauth_session_id)
            if oauth_token:
                return oauth_token
        except Exception as exc:
            log.error("Error getting OAuth token from cookie session: %s", exc)

    try:
        session = get_preferred_oauth_session(user.id, db=db, provider=provider)
    except Exception as exc:
        log.error("Error loading fallback OAuth session: %s", exc)
        return None

    if not session:
        return None

    if oauth_manager:
        try:
            oauth_token = await oauth_manager.get_oauth_token(user.id, session.id)
            if oauth_token:
                return oauth_token
        except Exception as exc:
            log.error("Error getting OAuth token from stored session: %s", exc)

    if isinstance(session.token, dict):
        return session.token

    return None
