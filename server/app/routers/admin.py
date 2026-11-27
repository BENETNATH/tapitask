from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import Principal, require_admin
from ..models import ChangeLog, RefreshToken, User
from ..schemas import (
    AdminUserCreateIn,
    AdminUserOut,
    AdminUserPatch,
)
from ..security import hash_password

router = APIRouter(prefix="/admin/users", tags=["admin"])
audit_router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("", response_model=list[AdminUserOut])
async def list_users(
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(User).order_by(User.created_at))
    return [
        AdminUserOut(
            id=u.id,
            email=u.email,
            is_admin=u.is_admin,
            is_active=u.is_active,
            is_email_verified=u.is_email_verified,
            created_at=u.created_at,
        )
        for u in result.scalars()
    ]


@router.post("", response_model=AdminUserOut, status_code=status.HTTP_201_CREATED)
async def create_user(
    data: AdminUserCreateIn,
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    user = User(
        email=data.email.lower(),
        password_hash=hash_password(data.password),
        is_admin=data.is_admin,
    )
    session.add(user)
    try:
        await session.commit()
    except IntegrityError:
        raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")
    return AdminUserOut(
        id=user.id,
        email=user.email,
        is_admin=user.is_admin,
        is_active=user.is_active,
        is_email_verified=user.is_email_verified,
        created_at=user.created_at,
    )


@audit_router.get("/audit")
async def audit_log(
    limit: int = 100,
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Recent change-log entries (who did what, when)."""
    from sqlalchemy import select as sa_select

    result = await session.execute(
        sa_select(ChangeLog)
        .order_by(ChangeLog.server_time.desc())
        .limit(min(limit, 1000))
    )
    return [
        {
            "id": entry.id,
            "list_id": str(entry.list_id) if entry.list_id else None,
            "item_id": str(entry.item_id) if entry.item_id else None,
            "kind": entry.kind,
            "actor_id": str(entry.actor_id) if entry.actor_id else None,
            "server_time": entry.server_time.isoformat(),
        }
        for entry in result.scalars()
    ]


@router.patch("/{user_id}", response_model=AdminUserOut)
async def patch_user(
    user_id: UUID,
    data: AdminUserPatch,
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "User not found")
    if data.is_active is not None:
        if user.id == principal.user_id and data.is_active is False:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Cannot disable yourself")
        user.is_active = data.is_active
    if data.is_admin is not None:
        if user.id == principal.user_id and data.is_admin is False:
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST, "Cannot remove your own admin role"
            )
        user.is_admin = data.is_admin
    if data.password is not None:
        user.password_hash = hash_password(data.password)
        # S5 (prod4) : un reset de mdp par admin révoque les RefreshToken de
        # l'utilisateur — une session déjà ouverte (refresh token en cours)
        # ne doit plus pouvoir survivre au changement de mot de passe.
        await session.execute(
            delete(RefreshToken).where(RefreshToken.user_id == user.id)
        )
    await session.commit()
    return AdminUserOut(
        id=user.id,
        email=user.email,
        is_admin=user.is_admin,
        is_active=user.is_active,
        is_email_verified=user.is_email_verified,
        created_at=user.created_at,
    )


@router.delete("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def disable_user(
    user_id: UUID,
    principal: Principal = Depends(require_admin),
    session: AsyncSession = Depends(get_session),
):
    """Soft-disable: the account can no longer authenticate; data is kept."""
    user = await session.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "User not found")
    if user.id == principal.user_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Cannot disable yourself")
    user.is_active = False
    await session.commit()
    return None
