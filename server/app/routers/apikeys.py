from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import Principal, accessible_list, get_principal, require_write
from ..models import ApiKey
from ..schemas import ApiKeyIn, ApiKeyOut
from ..security import new_api_key

router = APIRouter(prefix="/api-keys", tags=["api-keys"])


@router.post("", status_code=status.HTTP_201_CREATED)
async def create_api_key(
    data: ApiKeyIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    if principal.list_scope is not None and data.list_scope != principal.list_scope:
        # Une clé scopée ne peut pas en créer une plus large (ni non scopée).
        raise HTTPException(status.HTTP_403_FORBIDDEN, "API key scoped to another list")
    if data.list_scope is not None:
        # Le scope doit pointer sur une liste que le caller accède réellement
        # (404 inconnu/supprimé/non-membre) — sinon on crée une clé qui lit
        # un delta qu'elle ne devrait pas atteindre (audit run-3).
        await accessible_list(data.list_scope, principal, session)
    raw, key_hash, key_prefix = new_api_key()
    api_key = ApiKey(
        user_id=principal.user_id,
        name=data.name,
        key_prefix=key_prefix,
        key_hash=key_hash,
        read_only=data.read_only,
        list_scope=data.list_scope,
    )
    session.add(api_key)
    await session.commit()
    return {
        "key": raw,
        "id": str(api_key.id),
        "name": api_key.name,
        "read_only": api_key.read_only,
        "note": "Store this key now, it will not be shown again",
    }


@router.get("", response_model=list[ApiKeyOut])
async def list_api_keys(
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(
        select(ApiKey)
        .where(ApiKey.user_id == principal.user_id, ApiKey.revoked.is_(False))
        .order_by(ApiKey.created_at.desc())
    )
    return [
        ApiKeyOut(
            id=k.id,
            name=k.name,
            key_prefix=k.key_prefix,
            read_only=k.read_only,
            list_scope=k.list_scope,
            created_at=k.created_at,
        )
        for k in result.scalars()
    ]


@router.delete("/{key_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_api_key(
    key_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(
        select(ApiKey).where(ApiKey.id == key_id, ApiKey.user_id == principal.user_id)
    )
    api_key = result.scalar_one_or_none()
    if api_key is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "API key not found")
    api_key.revoked = True
    await session.commit()
    return None
