from __future__ import annotations

import time
from collections import defaultdict, deque
from uuid import UUID

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .config import settings
from .db import get_session
from .models import ApiKey, Checklist, ListMember, Role, User
from .security import decode_token, hash_api_key

bearer = HTTPBearer(auto_error=False)


class Principal:
    def __init__(
        self,
        user_id: UUID,
        read_only: bool = False,
        via: str = "jwt",
        is_admin: bool = False,
        list_scope: UUID | None = None,
    ):
        self.user_id = user_id
        self.read_only = read_only
        self.via = via
        self.is_admin = is_admin
        self.list_scope = list_scope


class RateLimiter:
    """In-memory limiter, or Redis-backed (fixed window) when REDIS_URL is set,
    which makes it effective across multiple uvicorn workers."""

    _redis = None

    def __init__(self, max_requests: int, window_seconds: int = 60):
        self.max_requests = max_requests
        self.window = window_seconds
        self.hits: dict[str, deque[float]] = defaultdict(deque)
        if settings.REDIS_URL and RateLimiter._redis is None:
            try:
                import redis.asyncio as aioredis

                RateLimiter._redis = aioredis.from_url(
                    settings.REDIS_URL, decode_responses=True
                )
            except Exception:
                RateLimiter._redis = False
        self.redis = RateLimiter._redis

    async def check(self, key: str) -> None:
        if self.redis:
            try:
                bucket = f"rl:{key}:{int(time.time() // self.window)}"
                count = await self.redis.incr(bucket)
                if count == 1:
                    await self.redis.expire(bucket, self.window)
                if count > self.max_requests:
                    raise HTTPException(
                        status.HTTP_429_TOO_MANY_REQUESTS, "Too many requests"
                    )
                return
            except HTTPException:
                raise
            except Exception:
                # 3.3 (prod3) : Redis tombé → log + fallback mémoire pour
                # l'appel courant (MD-6) — jamais de 500 sur toute l'API.
                import logging

                logging.getLogger("tapitask").exception(
                    "rate-limit: Redis indisponible (%s) — fallback mémoire", key
                )
        # 3.3 (prod3) : fuite lente — les deque vides (fenêtre écoulée) ne
        # sont jamais retirés du dict (1 clé par IP/cible, indéfiniment).
        # Purge amortie : un passage de dict à chaque check seulement au-
        # delà de 10 000 entrées.
        if len(self.hits) > 10_000:
            for k in [k for k, q in self.hits.items() if not q]:
                self.hits.pop(k)
        now = time.monotonic()
        q = self.hits[key]
        while q and now - q[0] > self.window:
            q.popleft()
        if len(q) >= self.max_requests:
            raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "Too many requests")
        q.append(now)


def client_key(request: Request) -> str:
    """Identity used for rate-limiting / lockout buckets.

    Only trust X-Forwarded-For when the DIRECT peer is a configured trusted
    proxy (settings.TRUSTED_PROXIES). Otherwise fall back to the direct peer
    IP — a client must not be able to rotate a forged XFF header to reset the
    rate-limit/lockout counter on /auth/login or /auth/register.
    """
    peer = request.client.host if request.client else "unknown"
    trusted = settings.TRUSTED_PROXIES
    if trusted and peer in trusted:
        fwd = request.headers.get("x-forwarded-for")
        if fwd:
            return fwd.split(",")[0].strip() or peer
    return peer


async def get_principal(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    session: AsyncSession = Depends(get_session),
) -> Principal:
    if credentials is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing credentials")
    token = credentials.credentials
    if token.startswith("chk_"):
        result = await session.execute(
            select(ApiKey).where(
                ApiKey.key_hash == hash_api_key(token), ApiKey.revoked.is_(False)
            )
        )
        api_key = result.scalar_one_or_none()
        if api_key is None:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid API key")
        owner = await session.get(User, api_key.user_id)
        if owner is None or not owner.is_active:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Account disabled")
        principal = Principal(
            api_key.user_id,
            read_only=api_key.read_only,
            via="api_key",
            is_admin=owner.is_admin,
            list_scope=api_key.list_scope,
        )
    else:
        try:
            payload = decode_token(token, "access")
        except Exception:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid token")
        user = await session.get(User, UUID(payload["sub"]))
        if user is None or not user.is_active:
            raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Account disabled")
        principal = Principal(user.id, is_admin=user.is_admin)
    if (
        principal.read_only
        and request.method != "GET"
        and not request.url.path.startswith("/mcp/")
    ):
        # Global gate: a read-only credential is refused on every mutation
        # route (Strix vuln-0001). MCP is excluded on purpose: one POST
        # channel multiplexes read and write tools, guarded per tool in
        # mcp_http.
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Read-only credentials")
    return principal


async def require_admin(principal: Principal = Depends(get_principal)) -> Principal:
    if not principal.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Admin only")
    return principal


async def require_write(principal: Principal = Depends(get_principal)) -> Principal:
    if principal.read_only:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Read-only credentials")
    return principal


# Limiteur par principal pour les canaux écriture lourds (POST /sync, bulk
# items, MCP messages) (audit lot T) : un seul compte ne doit pas pouvoir
# inonder l'éventail de changements. Clé stable = identity du principal.
_principal_limiter = RateLimiter(settings.PRINCIPAL_RATE_LIMIT_PER_MINUTE)


def principal_key(principal: Principal) -> str:
    key = f"{principal.via}:{principal.user_id}"
    if principal.list_scope is not None:
        key += f":{principal.list_scope}"
    return key


async def rate_limit_principal(
    principal: Principal = Depends(get_principal),
) -> Principal:
    await _principal_limiter.check(principal_key(principal))
    return principal


async def accessible_list(
    list_id: UUID,
    principal: Principal,
    session: AsyncSession,
    min_role: Role = Role.viewer,
) -> tuple[Checklist, ListMember | None]:
    if principal.list_scope is not None and list_id != principal.list_scope:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "API key scoped to another list")
    result = await session.execute(
        select(Checklist).where(Checklist.id == list_id, Checklist.deleted.is_(False))
    )
    checklist = result.scalar_one_or_none()
    if checklist is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "List not found")
    if checklist.owner_id == principal.user_id:
        return checklist, None
    result = await session.execute(
        select(ListMember).where(
            ListMember.list_id == list_id, ListMember.user_id == principal.user_id
        )
    )
    member = result.scalar_one_or_none()
    if member is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "List not found")
    role_order = {Role.viewer: 0, Role.editor: 1, Role.owner: 2}
    if role_order[member.role] < role_order[min_role]:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Insufficient role")
    return checklist, member
