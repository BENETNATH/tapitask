from __future__ import annotations

import asyncio
import json

from datetime import timedelta
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import settings
from ..events import hub
from ..db import get_session
from ..deps import Principal, RateLimiter, client_key, get_principal
from ..models import RefreshToken, User, utcnow
from ..schemas import (
    ChangeEmailIn,
    UserSettingsIn,
    LoginIn,
    RefreshIn,
    RegisterIn,
    TotpEnableIn,
    TotpSetupOut,
    TokenOut,
    UserOut,
    VerifyEmailIn,
)


async def _send_verification_email(to: str, token: str) -> None:
    """Best-effort async SMTP send; failures are logged, never blocking
    the event loop (asyncio.to_thread inside mailer.send_email)."""
    from ..mailer import send_email

    await send_email(
        to,
        "Tapitask — vérification de votre email",
        "Bienvenue sur Tapitask !\n\n"
        "Vérifiez votre adresse email avec ce code :\n\n"
        f"{token}\n\n"
        "Collez-le dans l'application (écran de connexion → « Vérifier mon email »).",
    )


async def _send_change_email(to: str, token: str) -> None:
    from ..mailer import send_email

    await send_email(
        to,
        "Tapitask — changement d'email",
        f"{to} a demandé le changement de l'adresse email de votre compte Tapitask. "
        "Si c'était vous, collez ce code dans l'application :\n\n"
        f"{token}\n\n"
        "Si ce n'était pas vous, ignorez ce message.",
    )
from ..security import (
    create_access_token,
    is_expired,
    new_email_token,
    new_totp_secret,
    totp_uri,
    verify_totp,
    create_refresh_token,
    decode_token,
    hash_password,
    token_fingerprint,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])

_login_limiter = RateLimiter(settings.RATE_LIMIT_PER_MINUTE)
_register_limiter = RateLimiter(5)
# Failed-login lockout: {key: (count, first_failure_monotonic)}.
# Entries expire after 15 minutes so an account is never locked forever
# and the dict cannot grow unbounded.
_FAILED_LOGINS_TTL = 900.0
_failed_logins: dict[str, tuple[int, float]] = {}


def _register_failed_login(key: str) -> None:
    import time

    now = time.monotonic()
    # Purge expired entries (cheap: bounded by distinct keys seen).
    for k in [k for k, (_, t) in _failed_logins.items() if now - t > _FAILED_LOGINS_TTL]:
        _failed_logins.pop(k, None)
    count, _ = _failed_logins.get(key, (0, now))
    _failed_logins[key] = (count + 1, now)


def _is_locked_out(key: str) -> bool:
    import time

    entry = _failed_logins.get(key)
    if entry is None:
        return False
    count, first = entry
    if time.monotonic() - first > _FAILED_LOGINS_TTL:
        _failed_logins.pop(key, None)
        return False
    return count >= 10


# Same status AND body for a fresh and a repeat register: the caller must
# never learn whether the account already exists (Strix vuln-0003).
_REGISTER_UNIFORM_MESSAGE = "Si ce compte existe, un email de vérification a été (re)envoyé."


@router.post("/register", response_model=TokenOut, status_code=status.HTTP_201_CREATED)
async def register(
    request: Request,
    data: RegisterIn,
    session: AsyncSession = Depends(get_session),
):
    await _register_limiter.check(f"reg:{client_key(request)}")
    email = data.email.lower()
    existing = (await session.execute(select(User).where(User.email == email))).scalar_one_or_none()
    if existing is not None:
        # Uniform reply: the tokens are INERT (sub maps to no account), so
        # the response looks identical to a fresh register on the wire but
        # grants nothing — the caller does not own this account.
        if settings.SMTP_ENABLED:
            existing.email_token = new_email_token()
            await session.commit()
            asyncio.create_task(_send_verification_email(existing.email, existing.email_token))
            raise HTTPException(status.HTTP_202_ACCEPTED, _REGISTER_UNIFORM_MESSAGE)
        return TokenOut(access_token=create_access_token(uuid4()),
                        refresh_token=create_refresh_token(uuid4()))
    user = User(email=email, password_hash=hash_password(data.password))
    if settings.SMTP_ENABLED:
        user.is_email_verified = False
        user.email_token = new_email_token()
    session.add(user)
    try:
        await session.commit()
    except IntegrityError:
        # lost the create race: answer exactly like a repeat register
        if settings.SMTP_ENABLED:
            raise HTTPException(status.HTTP_202_ACCEPTED, _REGISTER_UNIFORM_MESSAGE)
        return TokenOut(access_token=create_access_token(uuid4()),
                        refresh_token=create_refresh_token(uuid4()))
    if settings.SMTP_ENABLED:
        asyncio.create_task(_send_verification_email(user.email, user.email_token))
        raise HTTPException(status.HTTP_202_ACCEPTED, _REGISTER_UNIFORM_MESSAGE)
    return await _issue_tokens(session, user)


@router.post("/login", response_model=TokenOut)
async def login(
    request: Request,
    data: LoginIn,
    session: AsyncSession = Depends(get_session),
):
    key = f"login:{client_key(request)}"
    await _login_limiter.check(key)
    if _is_locked_out(key):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many failed attempts, try later")
    result = await session.execute(select(User).where(User.email == data.email.lower()))
    user = result.scalar_one_or_none()
    if user is not None and not user.is_active:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Account disabled")
    if user is not None and settings.SMTP_ENABLED and not user.is_email_verified:
        raise HTTPException(
            status.HTTP_428_PRECONDITION_REQUIRED,
            "Email non vérifié — utilisez « Vérifier mon email » avec le code reçu.",
        )
    if user is not None and user.totp_secret and not (
        data.totp_code and verify_totp(user.totp_secret, data.totp_code)
    ):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Code 2FA requis ou invalide")
    if user is None or not verify_password(user.password_hash, data.password):
        _register_failed_login(key)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")
    _failed_logins.pop(key, None)
    return await _issue_tokens(session, user)


@router.post("/refresh", response_model=TokenOut)
async def refresh(data: RefreshIn, session: AsyncSession = Depends(get_session)):
    try:
        payload = decode_token(data.refresh_token, "refresh")
    except Exception:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid refresh token")
    fingerprint = token_fingerprint(data.refresh_token)
    result = await session.execute(
        select(RefreshToken).where(RefreshToken.token_hash == fingerprint)
    )
    stored = result.scalar_one_or_none()
    if stored is None or stored.revoked or is_expired(stored.expires_at):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid refresh token")
    user_result = await session.execute(select(User).where(User.id == UUID(payload["sub"])))
    user = user_result.scalar_one_or_none()
    if user is None or not user.is_active:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid refresh token")
    stored.revoked = True
    await session.commit()
    return await _issue_tokens(session, user)


@router.get("/me", response_model=UserOut)
async def me(principal: Principal = Depends(get_principal), session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.id == principal.user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")
    try:
        settings = json.loads(user.settings) if user.settings else {}
    except Exception:
        settings = {}
    return UserOut(id=user.id, email=user.email, is_admin=user.is_admin, settings=settings,
                   pending_email=user.pending_email, totp=user.totp_secret is not None)


@router.patch("/me", response_model=UserOut)
async def update_settings(
    data: UserSettingsIn,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(User).where(User.id == principal.user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")
    user.settings = json.dumps(data.settings)
    await session.commit()
    return UserOut(
        id=user.id, email=user.email, is_admin=user.is_admin, settings=data.settings,
        pending_email=user.pending_email, totp=user.totp_secret is not None)


@router.post("/verify-email", status_code=status.HTTP_204_NO_CONTENT)
async def verify_email(data: VerifyEmailIn, session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.email_token == data.token))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Code de vérification invalide")
    if user.pending_email is not None:
        user.email = user.pending_email
        user.pending_email = None
    user.is_email_verified = True
    user.email_token = None
    await session.commit()
    return None


@router.post("/resend-verification", status_code=status.HTTP_204_NO_CONTENT)
async def resend_verification(
    request: Request,
    data: LoginIn,
    session: AsyncSession = Depends(get_session),
):
    await _login_limiter.check(f"resend:{client_key(request)}")
    result = await session.execute(select(User).where(User.email == data.email.lower()))
    user = result.scalar_one_or_none()
    # Un compte vérifié avec un changement d'email en attente doit pouvoir
    # se renvoyer le code (vers l'email en attente).
    if user is None or (user.is_email_verified and user.pending_email is None):
        return None
    user.email_token = new_email_token()
    await session.commit()
    asyncio.create_task(
        _send_verification_email(user.pending_email or user.email, user.email_token))
    return None


@router.post("/change-email", status_code=status.HTTP_202_ACCEPTED)
async def change_email(
    data: ChangeEmailIn,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(User).where(User.id == principal.user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")
    new_email = data.new_email.lower()
    if user.totp_secret and not (
        data.totp_code and verify_totp(user.totp_secret, data.totp_code)
    ):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Code 2FA requis ou invalide")
    if not verify_password(user.password_hash, data.password):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid credentials")
    if new_email == user.email:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Cet email est déjà le vôtre")
    existing = (
        await session.execute(select(User).where(User.email == new_email))
    ).scalar_one_or_none()
    if existing is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Cet email est déjà utilisé")
    if not settings.SMTP_ENABLED:
        raise HTTPException(
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "Vérification email indisponible (SMTP non configuré)")
    user.pending_email = new_email
    user.email_token = new_email_token()
    await session.commit()
    asyncio.create_task(_send_change_email(new_email, user.email_token))
    return None


@router.post("/totp/setup", response_model=TotpSetupOut)
async def totp_setup(
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    """Generate a TOTP secret (not yet active until /totp/enable with a valid code)."""
    result = await session.execute(select(User).where(User.id == principal.user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")
    secret = user.totp_secret or new_totp_secret()
    user.totp_secret = secret
    await session.commit()
    return TotpSetupOut(secret=secret, uri=totp_uri(secret, user.email))


@router.post("/totp/enable", status_code=status.HTTP_204_NO_CONTENT)
async def totp_enable(
    data: TotpEnableIn,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(User).where(User.id == principal.user_id))
    user = result.scalar_one_or_none()
    if user is None or not user.totp_secret:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "TOTP non initialisé (appelez /totp/setup)")
    if data.disable:
        user.totp_secret = None
        await session.commit()
        await hub.notify_users([user.id], {"kind": "totp.disabled"})
        return None
    if not verify_totp(user.totp_secret, data.code):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Code invalide")
    await hub.notify_users([user.id], {"kind": "totp.enabled"})
    return None


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(data: RefreshIn, session: AsyncSession = Depends(get_session)):
    fingerprint = token_fingerprint(data.refresh_token)
    result = await session.execute(
        select(RefreshToken).where(RefreshToken.token_hash == fingerprint)
    )
    stored = result.scalar_one_or_none()
    if stored is not None:
        stored.revoked = True
        await session.commit()
    return None


async def _issue_tokens(session: AsyncSession, user: User) -> TokenOut:
    refresh = create_refresh_token(user.id)
    session.add(
        RefreshToken(
            user_id=user.id,
            token_hash=token_fingerprint(refresh),
            expires_at=utcnow() + timedelta(seconds=settings.REFRESH_TOKEN_TTL),
        )
    )
    await session.commit()
    return TokenOut(access_token=create_access_token(user.id), refresh_token=refresh)
