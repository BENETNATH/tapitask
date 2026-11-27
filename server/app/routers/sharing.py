from __future__ import annotations

import asyncio
from datetime import timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import engine, get_session
from ..deps import Principal, accessible_list, get_principal, require_write
from ..events import hub
from ..mailer import send_email, user_wants_email
from ..models import Invite, ListMember, Role, User, utcnow
from ..schemas import InviteIn, InviteOut, MemberIn, MemberRoleIn
from ..security import is_expired

router = APIRouter(prefix="/lists", tags=["sharing"])

# 3.4 (prod3) : tâches mail en vol — sans référence forte, asyncio peut les
# garbage-collecter avant exécution (même motif que _in_flight_webhooks, C1.3).
_in_flight_emails: set[asyncio.Task] = set()


def _spawn_email(to: str, subject: str, body: str) -> None:
    """Fire-and-forget (contrat 3.4) : le partage ne doit pas bloquer la
    requête sur un relais SMTP lent (10-20 s). `send_email` est best-effort
    (_sync_send avale ses exceptions) ; on loggue si malgré tout ça lève."""

    async def _run() -> None:
        try:
            await send_email(to, subject, body)
        except Exception:
            import logging

            logging.getLogger("tapitask.mail").exception(
                "email de partage a échoué vers %s", to
            )

    task = asyncio.create_task(_run())
    _in_flight_emails.add(task)
    task.add_done_callback(_in_flight_emails.discard)


async def _upsert_member(
    session: AsyncSession, list_id: UUID, user_id: UUID, role: Role
) -> None:
    """INSERT ... ON CONFLICT (list_id, user_id): a repeat join updates the
    role in place instead of duplicating the row (Strix hardening item).
    Old databases without the unique constraint get the index from the
    schema migration in main._ensure_indexes."""
    if engine.dialect.name == "postgresql":
        from sqlalchemy.dialects.postgresql import insert
    else:
        from sqlalchemy.dialects.sqlite import insert
    stmt = insert(ListMember).values(list_id=list_id, user_id=user_id, role=role)
    stmt = stmt.on_conflict_do_update(
        index_elements=["list_id", "user_id"], set_={"role": stmt.excluded.role}
    )
    await session.execute(stmt)


@router.post(
    "/{list_id}/invites", response_model=InviteOut, status_code=status.HTTP_201_CREATED
)
async def create_invite(
    list_id: UUID,
    data: InviteIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    """Share-link model (product decision, spec J6): the invite binds to the
    one-time high-entropy code only — the redeeming account is NOT linked to
    the optional `email` field, which is a notification hint, not an identity
    check."""
    checklist, _ = await accessible_list(list_id, principal, session)
    if checklist.owner_id != principal.user_id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only the owner can invite")
    invite = Invite(
        list_id=list_id,
        expires_at=utcnow() + timedelta(hours=data.hours),
    )
    session.add(invite)
    await session.commit()
    # Best-effort email so the invitee receives the code out of band —
    # fire-and-forget (3.4) : la requête répond sans attendre le relais SMTP.
    if data.email:
        _spawn_email(
            data.email,
            "Tapitask — code d'invitation",
            f"Vous êtes invité(e) à rejoindre la liste « {checklist.title} » sur Tapitask.\n\n"
            f"Code d'invitation : {invite.id}\n"
            f"Valable {data.hours} heures. Collez-le dans l'application "
            "(écran de connexion → « J'ai un code d'invitation »).",
        )
    return InviteOut(invite_id=invite.id, list_id=list_id)


@router.post("/invites/{invite_id}/accept", status_code=status.HTTP_204_NO_CONTENT)
async def accept_invite(
    invite_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(Invite).where(Invite.id == invite_id))
    invite = result.scalar_one_or_none()
    if (
        invite is None
        or invite.accepted_by is not None
        or is_expired(invite.expires_at)
    ):
        raise HTTPException(
            status.HTTP_404_NOT_FOUND, "Invite not found or already used"
        )
    existing = (
        await session.execute(
            select(ListMember).where(
                ListMember.list_id == invite.list_id,
                ListMember.user_id == principal.user_id,
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        raise HTTPException(status.HTTP_409_CONFLICT, "Already a member of this list")
    invite.accepted_by = principal.user_id
    await _upsert_member(session, invite.list_id, principal.user_id, invite.role)
    await session.commit()
    await hub.notify_users(
        [principal.user_id], {"kind": "list.shared", "list_id": str(invite.list_id)}
    )
    return None


@router.post("/{list_id}/members", status_code=status.HTTP_201_CREATED)
async def add_member(
    list_id: UUID,
    data: MemberIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    if checklist.owner_id != principal.user_id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only the owner can add members")
    result = await session.execute(select(User).where(User.email == data.email.lower()))
    user = result.scalar_one_or_none()
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No account with this email")
    await _upsert_member(session, list_id, user.id, Role(data.role))
    await session.commit()
    await hub.notify_users([user.id], {"kind": "list.shared", "list_id": str(list_id)})
    if user_wants_email(user.settings):
        _spawn_email(
            user.email,
            f"Tapitask — « {checklist.title} » partagée avec vous",
            f"Bonjour,\n\n"
            f"La liste « {checklist.title} » a été partagée avec vous "
            f"(rôle : {data.role}).\nOuvrez Tapitask pour la consulter.",
        )
    return {"user_id": str(user.id), "role": data.role}


@router.get("/{list_id}/members")
async def list_members(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session)
    result = await session.execute(
        select(ListMember, User.email)
        .join(User, User.id == ListMember.user_id)
        .where(ListMember.list_id == list_id)
    )
    members = [
        {"user_id": str(member.user_id), "email": email, "role": member.role.value}
        for member, email in result.all()
    ]
    return members


@router.patch("/{list_id}/members/{user_id}", response_model=None)
async def change_member_role(
    list_id: UUID,
    user_id: UUID,
    payload: MemberRoleIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    if checklist.owner_id != principal.user_id:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "Only the owner can change roles"
        )
    result = await session.execute(
        select(ListMember).where(
            ListMember.list_id == list_id, ListMember.user_id == user_id
        )
    )
    member = result.scalar_one_or_none()
    if member is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Not a member")
    if payload.role == Role.owner:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "There must be exactly one owner"
        )
    member.role = payload.role
    await session.commit()
    await hub.notify_users(
        [user_id],
        {"kind": "list.shared", "list_id": str(list_id), "role": payload.role.value},
    )
    return {"user_id": str(user_id), "email": None, "role": payload.role.value}


@router.delete("/{list_id}/members/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_member(
    list_id: UUID,
    user_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    if checklist.owner_id != principal.user_id:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "Only the owner can remove members"
        )
    result = await session.execute(
        select(ListMember).where(
            ListMember.list_id == list_id, ListMember.user_id == user_id
        )
    )
    member = result.scalar_one_or_none()
    if member is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Not a member")
    await session.delete(member)
    await session.commit()
    await hub.notify_users(
        [user_id], {"kind": "list.unshared", "list_id": str(list_id)}
    )
    return None
