from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Protocol

from fastapi import Depends, Header, Request

from .config import Settings
from .errors import ApiError


@dataclass
class Principal:
    uid: str
    email: Optional[str] = None
    email_verified: bool = False


class TokenVerifier(Protocol):
    def verify(self, token: str) -> Principal: ...


class FirebaseVerifier:
    def __init__(self, project: Optional[str] = None) -> None:
        import firebase_admin
        from firebase_admin import credentials  # noqa: F401
        if not firebase_admin._apps:
            firebase_admin.initialize_app(options={"projectId": project} if project else None)

    def verify(self, token: str) -> Principal:
        from firebase_admin import auth
        try:
            d = auth.verify_id_token(token, check_revoked=True)
        except Exception:  # noqa: BLE001 - any failure is a 401; never echo the reason/token
            raise ApiError(401, "invalid_token", "Invalid or expired credentials")
        return Principal(uid=d["uid"], email=d.get("email"), email_verified=bool(d.get("email_verified")))


class DevVerifier:
    """`Bearer dev:<uid>` — local development and tests only. Construction fails in prod."""

    def __init__(self, settings: Settings) -> None:
        if settings.env == "prod":
            raise RuntimeError("dev auth is not permitted when ENV=prod")

    def verify(self, token: str) -> Principal:
        if not token.startswith("dev:") or len(token) < 5:
            raise ApiError(401, "invalid_token", "Invalid or expired credentials")
        return Principal(uid=token[4:], email_verified=True)


def build_verifier(settings: Settings) -> TokenVerifier:
    if settings.auth_mode == "dev":
        return DevVerifier(settings)
    return FirebaseVerifier(settings.gcp_project)


def current_user(request: Request, authorization: Optional[str] = Header(default=None)) -> Principal:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise ApiError(401, "missing_token", "Authentication required")
    principal = request.app.state.verifier.verify(authorization[7:].strip())
    request.state.uid = principal.uid
    request.app.state.limiter.check(principal.uid, "general", request.app.state.settings.rate_limit_per_min)
    return principal


def ai_limited(request: Request, user: Principal = Depends(current_user)) -> Principal:
    request.app.state.limiter.check(user.uid, "ai", request.app.state.settings.ai_rate_limit_per_min)
    return user
