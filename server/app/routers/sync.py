from __future__ import annotations

from datetime import datetime, timedelta
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import or_, select
from sqlalchemy.exc import DataError, IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import Principal, accessible_list, rate_limit_principal, require_write
from ..events import record_change, notify_list
from ..models import Checklist, Item, ListMember, Role, utcnow
from ..schemas import SyncChange, SyncIn, SyncOut, validate_sync_event
from .lists import _spawn_next

router = APIRouter(prefix="/sync", tags=["sync"])


def _naive(dt: datetime) -> datetime:
    return dt.replace(tzinfo=None) if dt.tzinfo is not None else dt


# Un horodatage client plus de 5 s dans le futur est une horloge cassée,
# pas un événement futur : le clamp serveur protège l'ordre LWW et le
# curseur du delta (audit run-2).
SYNC_CLOCK_TOLERANCE = timedelta(seconds=5)


def _clamp_client_dt(dt: datetime) -> datetime:
    dt = _naive(dt)
    now = _naive(utcnow())
    # Symétrique (audit lot T) : un horodatage très antérieur au serveur est
    # aussi une horloge cassée — sans clamp, un item scellé dans le passé
    # resterait invisible au delta des autres clients.
    return now if dt > now + SYNC_CLOCK_TOLERANCE or dt < now - SYNC_CLOCK_TOLERANCE else dt


@router.post("", response_model=SyncOut)
async def sync(
    data: SyncIn,
    principal: Principal = Depends(require_write),
    _rate_limited: Principal = Depends(rate_limit_principal),
    session: AsyncSession = Depends(get_session),
):
    """Delta sync: apply client events (last-write-wins), return server changes since `since`.

    Events are applied ONE BY ONE: a single invalid event (list already
    deleted server-side, lost access…) is reported in `rejected` and skipped,
    never aborting the whole batch — otherwise one poisoned event would
    block the client's outbox forever."""
    rejected: list = []
    pending_notifies: list[tuple[UUID, dict]] = []
    for event in data.events:
        try:
            # Un savepoint par événement : un événement refusé ne rollback
            # que lui-même, jamais les écritures des événements précédents.
            async with session.begin_nested():
                validate_sync_event(event)
                await _apply_event(session, event, principal, pending_notifies)
        except HTTPException:
            # Business rejection ONLY (403/404 from accessible_list: unknown
            # or deleted list, lost access). The event is reported so the
            # client drops it from its outbox.
            rejected.append(event.id)
        except (ValueError, DataError, IntegrityError):
            # Event malformé (C1.1b) ou conflit unique en base : un tel
            # event ne réussira JAMAIS → rejeté, pas de retry (un 500
            # laisserait l'outbox du client bloqué en boucle).
            rejected.append(event.id)
        # Infrastructure errors (DB connection lost, timeout, deadlock…) are
        # NOT caught: the request fails with 500 and the client retries the
        # whole batch — never silently purging data.
    # Un seul commit de fin de batch (cadence : plus d'un commit par
    # événement) ; les notifications partent après, lues en session fraîche.
    await session.commit()
    for list_id, payload in pending_notifies:
        await notify_list(list_id, payload)
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


async def _apply_event(session: AsyncSession, event, principal, pending_notifies: list) -> None:
    if event.kind == "list.create":
        await _apply_list_create(session, event, principal, pending_notifies)
        return
    if event.kind == "list.delete":
        # Delete requires OWNER (checked below); viewer access is enough to
        # reach the check itself.
        checklist, _ = await accessible_list(event.list_id, principal, session)
        if checklist.owner_id != principal.user_id:
            return
        checklist.deleted = True
        checklist.updated_at = _clamp_client_dt(event.updated_at)
        await record_change(
            session, list_id=event.list_id, checklist_id=checklist.id, kind="list.delete",
            commit=False)
        pending_notifies.append(
            (event.list_id, {"kind": "list.delete", "list_id": str(event.list_id)}))
        return
    # ALL other write kinds require the EDITOR role — same authorization as
    # the equivalent REST endpoints. A viewer pushing item.upsert, item.delete
    # or list.rename through the sync path is rejected (403 -> rejected id).
    checklist, _ = await accessible_list(
        event.list_id, principal, session, min_role=Role.editor)
    if event.kind == "item.upsert":
        await _apply_item_upsert(session, event, principal, pending_notifies)
    elif event.kind == "item.delete":
        await _apply_item_delete(session, event, principal, pending_notifies)
    elif event.kind == "list.rename":
        checklist.title = event.label or checklist.title
        checklist.updated_at = _clamp_client_dt(event.updated_at)


async def _accessible_list_ids(principal: Principal, session: AsyncSession) -> list[UUID]:
    # A scoped key sees only its list - and only if the principal still has
    # canonical access to it (same rule as accessible_list, deps.py).
    if principal.list_scope is not None:
        row = (await session.execute(
            select(Checklist.id).where(
                Checklist.id == principal.list_scope,
                Checklist.deleted.is_(False),
                or_(
                    Checklist.owner_id == principal.user_id,
                    Checklist.id.in_(
                        select(ListMember.list_id).where(ListMember.user_id == principal.user_id)
                    ),
                ),
            ))).first()
        return [row[0]] if row is not None else []
    owned = await session.execute(select(Checklist.id).where(Checklist.owner_id == principal.user_id))
    ids = [lid for (lid,) in owned.all()]
    shared = await session.execute(
        select(ListMember.list_id).where(ListMember.user_id == principal.user_id)
    )
    ids += [lid for (lid,) in shared.all()]
    return ids


async def _apply_list_create(session: AsyncSession, event, principal, pending_notifies: list) -> None:
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
        # Title : jamais vidé (NOT NULL) — label absent garde l'ancien.
        if event.label and event.label != existing.title:
            existing.title = event.label
            changed = True
        # null = vider : le client envoie l'état complet de la liste (C1.2).
        if event.color != existing.color:
            existing.color = event.color
            changed = True
        if event.folder != existing.folder:
            existing.folder = event.folder
            changed = True
        if changed:
            existing.updated_at = _clamp_client_dt(event.updated_at)
            pending_notifies.append(
                (event.list_id, {"kind": "list.rename", "id": str(event.list_id)}))
        return
    stamp = _clamp_client_dt(event.updated_at)
    checklist = Checklist(
        id=event.id,
        owner_id=principal.user_id,
        title=event.label or "Liste",
        color=event.color,
        folder=event.folder,
        created_at=stamp,
        updated_at=stamp,
    )
    session.add(checklist)
    await record_change(
        session, list_id=checklist.id, checklist_id=checklist.id,
        kind="list.create", actor_id=principal.user_id,
        commit=False,
    )
    pending_notifies.append((checklist.id, {"kind": "list.create", "id": str(checklist.id)}))


async def _apply_item_upsert(session: AsyncSession, event, principal, pending_notifies: list) -> None:
    stamp = _clamp_client_dt(event.updated_at)
    result = await session.execute(select(Item).where(Item.id == event.id))
    item = result.scalar_one_or_none()
    newly_done = False
    if item is None:
        # A1 : label vide (None ou espaces) sur un item NOUVEAU → rejet
        # (400 → rejected → outbox purgé) au lieu d'un IntegrityError 500
        # (colonne NOT NULL) qui bloquerait l'outbox en boucle.
        if event.label is None or not event.label.strip():
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "empty label")
        item = Item(id=event.id, list_id=event.list_id, created_at=stamp)
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
        if item.updated_at is not None and (
            _naive(item.updated_at) >= stamp
            # Horloge client trop en arrière : événement périmé — le clamp
            # symétrique (lot T) ne doit pas le faire gagner sur l'état
            # existant (LWW, spec §3.5).
            or _naive(event.updated_at) < _naive(utcnow()) - SYNC_CLOCK_TOLERANCE
        ):
            return
    newly_done = bool(event.done) and not bool(item.done)
    item.list_id = event.list_id
    # Label : jamais vidé (NOT NULL) — un label absent/vide garde l'ancien.
    if event.label is not None and event.label.strip():
        item.label = event.label
    item.done = event.done if event.done is not None else item.done
    item.position = event.position if event.position is not None else item.position
    # null = retirer : le client envoie l'état complet de l'item
    # (C1.2) — assignment explicite, plus de `event.X or item.X`.
    item.parent_id = event.parent_id
    item.recurrence = event.recurrence if event.recurrence is not None else "none"
    item.due_date = event.due_date
    item.notes = event.notes
    item.assignee_id = event.assignee_id
    item.updated_at = stamp
    # Recurrence: checking a recurring item from the app goes through the
    # outbox (item.upsert done=true), so the next occurrence must be spawned
    # here too — not only in PATCH /items/{id}.
    if newly_done and item.recurrence and item.recurrence != "none":
        await _spawn_next(session, item, principal.user_id,
                          commit=False, pending=pending_notifies)
    await record_change(
        session, list_id=event.list_id, item_id=item.id, kind="item.upsert",
        commit=False,
    )
    pending_notifies.append((event.list_id, {"kind": "item.upsert", "id": str(event.id)}))


async def _apply_item_delete(session: AsyncSession, event, principal, pending_notifies: list) -> None:
    stamp = _clamp_client_dt(event.updated_at)
    result = await session.execute(select(Item).where(Item.id == event.id))
    item = result.scalar_one_or_none()
    if item is None or _naive(item.updated_at) >= stamp \
            or _naive(event.updated_at) < _naive(utcnow()) - SYNC_CLOCK_TOLERANCE:
        return
    # The actor must have editor access to the list the item actually lives in
    # (not just the event's target list), otherwise a forged item.delete with a
    # global item id could soft-delete items in lists the actor cannot access.
    if item.list_id != event.list_id:
        await accessible_list(item.list_id, principal, session, min_role=Role.editor)
    item.deleted = True
    item.updated_at = stamp
    await record_change(session, list_id=event.list_id, item_id=item.id, kind="item.delete",
                        commit=False)
    pending_notifies.append((event.list_id, {"kind": "item.delete", "id": str(event.id)}))
