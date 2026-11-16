from __future__ import annotations

import hashlib
import secrets
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
import pyotp
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

from .config import settings
from .models import utcnow

ph = PasswordHasher()


def hash_password(password: str) -> str:
    return ph.hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        ph.verify(password_hash, password)
        return True
    except VerifyMismatchError:
        return False


def _create_token(sub: str, kind: str, ttl: int, extra: dict[str, Any] | None = None) -> str:
    now = datetime.now(timezone.utc)
    payload: dict[str, Any] = {
        "sub": sub,
        "kind": kind,
        "jti": uuid.uuid4().hex,
        "iat": now,
        "exp": now + timedelta(seconds=ttl),
    }
    if extra:
        payload.update(extra)
    return jwt.encode(payload, settings.JWT_SECRET, algorithm="HS256")


def create_access_token(user_id: uuid.UUID) -> str:
    return _create_token(str(user_id), "access", settings.ACCESS_TOKEN_TTL)


def create_refresh_token(user_id: uuid.UUID) -> str:
    return _create_token(str(user_id), "refresh", settings.REFRESH_TOKEN_TTL)


def decode_token(token: str, expected_kind: str) -> dict[str, Any]:
    payload = jwt.decode(token, settings.JWT_SECRET, algorithms=["HS256"])
    if payload.get("kind") != expected_kind:
        raise jwt.InvalidTokenError("wrong token kind")
    return payload


def new_api_key() -> tuple[str, str, str]:
    """Return (plaintext_key, key_hash, key_prefix)."""
    raw = "chk_" + secrets.token_urlsafe(32)
    return raw, hash_api_key(raw), raw[:10]


def hash_api_key(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


def new_totp_secret() -> str:
    return pyotp.random_base32()


def totp_uri(secret: str, email: str) -> str:
    return pyotp.totp.TOTP(secret).provisioning_uri(name=email, issuer_name="Tapitask")


def verify_totp(secret: str, code: str) -> bool:
    try:
        return pyotp.TOTP(secret).verify(code.strip().replace(" ", ""), valid_window=1)
    except Exception:
        return False


def new_email_token() -> str:
    return secrets.token_urlsafe(32)


def token_fingerprint(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def is_expired(expires_at: datetime) -> bool:
    stored = expires_at.replace(tzinfo=None) if expires_at.tzinfo else expires_at
    return stored <= utcnow().replace(tzinfo=None)
