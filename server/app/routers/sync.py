from __future__ import annotations

from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import Principal, accessible_list, get_principal, require_write
from ..events import record_change, notify_list
from ..models import ChangeLog, Checklist, Item, ListMember, Role, utcnow
from ..schemas import SyncChange, SyncIn, SyncOut
from .lists import _spawn_next

router = APIRouter(prefix="/sync", tags=["sync"])


def _naive(dt: datetime) -> datetime:
    return dt.replace(tzinfo=None) if dt.tzinfo is not None else dt


@router.post("", response_model=SyncOut)
async def sync(
    data: SyncIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    """Delta sync: apply client events (last-write-wins), return server changes since `since`.

    Events are applied ONE BY ONE: a single invalid event (list already
    deleted server-side, lost access…) is reported in `rejected` and skipped,
    never aborting the whole batch — otherwise one poisoned event would
    block the client's outbox forever."""
    rejected: list = []
    for event in data.events:
        try:
            await _apply_event(session, event, principal)
        except HTTPException:
            # Business rejection ONLY (403/404 from accessible_list: unknown
            # or deleted list, lost access). The event is reported so the
            # client drops it from its outbox.
            await session.rollback()
            rejected.append(event.id)
        # Infrastructure errors (DB connection lost, timeout, deadlock…) are
        # NOT caught: the request fails with 500 and the client retries the
        # whole batch — never silently purging data.
    accessible = await _accessible_list_ids(principal, session)
    changes: list[SyncChange] = []
    if data.since is not None:
        # Delta filter pushed into SQL (indexed updated_at comparison) —
        # no more loading every accessible list to filter in Python.
        since = _naive(data.since)
        result = await session.execute(
            select(Checklist)
            .where(Checklist.id.in_(accessible), Checklist.updated_at > since)
            .order_by(Checklist.updated_at)
        )
        for checklist in result.scalars():
            changes.append(
                SyncChange(
                    kind="list.delete" if checklist.deleted else "list.sync",
                    id=checklist.id,
                    list_id=checklist.id,
                    label=checklist.title,
                    color=checklist.color,
                    folder=checklist.folder,
                    updated_at=checklist.updated_at,
                )
            )
        result = await session.execute(
            select(Item)
            .where(Item.list_id.in_(accessible), Item.updated_at > since)
            .order_by(Item.updated_at)
        )
        for item in result.scalars():
            changes.append(
                SyncChange(
                    kind="item.delete" if item.deleted else "item.upsert",
                    id=item.id,
                    list_id=item.list_id,
                    label=item.label,
                    done=item.done,
                    position=item.position,
                    parent_id=item.parent_id,
                    recurrence=item.recurrence,
                    due_date=item.due_date,
                    notes=item.notes,
                    assignee_id=item.assignee_id,
                    updated_at=item.updated_at,
                    deleted=item.deleted,
                )
            )
    else:
        # First sync (no `since`): return the lists themselves so a fresh
        # device materialises its lists before their items.
        result = await session.execute(
            select(Checklist)
            .where(Checklist.id.in_(accessible), Checklist.deleted.is_(False))
            .order_by(Checklist.updated_at)
        )
        for checklist in result.scalars():
            changes.append(
                SyncChange(
                    kind="list.sync",
                    id=checklist.id,
                    list_id=checklist.id,
                    label=checklist.title,
                    color=checklist.color,
                    folder=checklist.folder,
                    updated_at=checklist.updated_at,
                )
            )
        result = await session.execute(
            select(Item).where(Item.list_id.in_(accessible), Item.deleted.is_(False))
        )
        for item in result.scalars():
            changes.append(
                SyncChange(
                    kind="item.upsert",
                    id=item.id,
                    list_id=item.list_id,
                    label=item.label,
                    done=item.done,
                    position=item.position,
                    parent_id=item.parent_id,
                    recurrence=item.recurrence,
                    due_date=item.due_date,
                    notes=item.notes,
                    assignee_id=item.assignee_id,
                    updated_at=item.updated_at,
                )
            )
    now = utcnow()
    return SyncOut(server_time=now, changes=changes, rejected=rejected)


async def _apply_event(session: AsyncSession, event, principal) -> None:
    if event.kind == "list.create":
        await _apply_list_create(session, event, principal)
        return
    if event.kind == "list.delete":
        # Delete requires OWNER (checked below); viewer access is enough to
        # reach the check itself.
        checklist, _ = await accessible_list(event.list_id, principal, session)
        if checklist.owner_id != principal.user_id:
            return
        checklist.deleted = True
        checklist.updated_at = _naive(event.updated_at)
        await session.commit()
        await record_change(
            session, list_id=event.list_id, checklist_id=checklist.id, kind="list.delete")
        await notify_list(event.list_id, {"kind": "list.delete", "list_id": str(event.list_id)})
        return
    # ALL other write kinds require the EDITOR role — same authorization as
    # the equivalent REST endpoints. A viewer pushing item.upsert, item.delete
    # or list.rename through the sync path is rejected (403 -> rejected id).
    checklist, _ = await accessible_list(
        event.list_id, principal, session, min_role=Role.editor)
    if event.kind == "item.upsert":
        await _apply_item_upsert(session, event, principal)
    elif event.kind == "item.delete":
        await _apply_item_delete(session, event, principal)
    elif event.kind == "list.rename":
        checklist.title = event.label or checklist.title
        checklist.updated_at = _naive(event.updated_at)
        await session.commit()


async def _accessible_list_ids(principal: Principal, session: AsyncSession) -> list[UUID]:
    # Une clé API scopée ne voit QUE sa liste — sinon le delta-sync
    # exposerait toutes les listes du propriétaire (audit run-2).
    if principal.list_scope is not None:
        row = (await session.execute(
            select(Checklist.id).where(Checklist.id == principal.list_scope))).first()
        return [row[0]] if row is not None else []
    owned = await session.execute(select(Checklist.id).where(Checklist.owner_id == principal.user_id))
    ids = [lid for (lid,) in owned.all()]
    shared = await session.execute(
        select(ListMember.list_id).where(ListMember.user_id == principal.user_id)
    )
    ids += [lid for (lid,) in shared.all()]
    return ids


async def _apply_list_create(session: AsyncSession, event, principal) -> None:
    """A list created offline arrives here; create it if the server doesn't know it yet."""
    result = await session.execute(select(Checklist).where(Checklist.id == event.id))
    existing = result.scalar_one_or_none()
    if existing is not None:
        # Ownership: a list id is known to every member (it travels through
        # /sync). A member — viewer or even editor — must NEVER be able to
        # rename/recolor someone else's list via a forged list.create event.
        if existing.owner_id != principal.user_id:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "Not the list owner")
        changed = False
        if event.label and event.label != existing.title:
            existing.title = event.label
            changed = True
        if event.color is not None and event.color != existing.color:
            existing.color = event.color
            changed = True
        if event.folder is not None and event.folder != existing.folder:
            existing.folder = event.folder
            changed = True
        if changed:
            existing.updated_at = _naive(event.updated_at)
            await session.commit()
            await notify_list(event.list_id, {"kind": "list.rename", "id": str(event.list_id)})
        return
    checklist = Checklist(
        id=event.id,
        owner_id=principal.user_id,
        title=event.label or "Liste",
        color=event.color,
        folder=event.folder,
        created_at=_naive(event.updated_at),
        updated_at=_naive(event.updated_at),
    )
    session.add(checklist)
    await session.commit()
    await record_change(
        session, list_id=checklist.id, checklist_id=checklist.id,
        kind="list.create", actor_id=principal.user_id,
    )
    await notify_list(checklist.id, {"kind": "list.create", "id": str(checklist.id)})


async def _apply_item_upsert(session: AsyncSession, event, principal) -> None:
    result = await session.execute(select(Item).where(Item.id == event.id))
    item = result.scalar_one_or_none()
    newly_done = False
    if item is None:
        item = Item(id=event.id, list_id=event.list_id, created_at=event.updated_at)
        session.add(item)
    else:
        # Re-parenting guard: the actor must have editor access to the list
        # the item CURRENTLY belongs to, not just to the target list that
        # _apply_event already checked. Without this, any editor could move an
        # arbitrary item (fetched by its global id) into a list they control —
        # a cross-tenant read + corruption primitive.
        if item.list_id != event.list_id:
            await accessible_list(
                item.list_id, principal, session, min_role=Role.editor)
    if item.updated_at is not None and _naive(item.updated_at) >= _naive(event.updated_at):
        return
    newly_done = bool(event.done) and not bool(item.done)
    item.list_id = event.list_id
    item.label = event.label or item.label
    item.done = event.done if event.done is not None else item.done
    item.position = event.position if event.position is not None else item.position
    item.parent_id = event.parent_id or item.parent_id
    item.recurrence = event.recurrence or item.recurrence
    item.due_date = event.due_date or item.due_date
    item.notes = event.notes if event.notes is not None else item.notes
    item.assignee_id = event.assignee_id or item.assignee_id
    item.updated_at = _naive(event.updated_at)
    await session.commit()
    # Recurrence: checking a recurring item from the app goes through the
    # outbox (item.upsert done=true), so the next occurrence must be spawned
    # here too — not only in PATCH /items/{id}.
    if newly_done and item.recurrence and item.recurrence != "none":
        await _spawn_next(session, item, principal.user_id)
    await record_change(
        session, list_id=event.list_id, item_id=item.id, kind="item.upsert"
    )
    await notify_list(event.list_id, {"kind": "item.upsert", "id": str(event.id)})


async def _apply_item_delete(session: AsyncSession, event, principal) -> None:
    result = await session.execute(select(Item).where(Item.id == event.id))
    item = result.scalar_one_or_none()
    if item is None or _naive(item.updated_at) >= _naive(event.updated_at):
        return
    # The actor must have editor access to the list the item actually lives in
    # (not just the event's target list), otherwise a forged item.delete with a
    # global item id could soft-delete items in lists the actor cannot access.
    if item.list_id != event.list_id:
        await accessible_list(item.list_id, principal, session, min_role=Role.editor)
    item.deleted = True
    item.updated_at = _naive(event.updated_at)
    await session.commit()
    await record_change(session, list_id=event.list_id, item_id=item.id, kind="item.delete")
    await notify_list(event.list_id, {"kind": "item.delete", "id": str(event.id)})
