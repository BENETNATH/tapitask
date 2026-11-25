from __future__ import annotations

import asyncio
from datetime import datetime
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import PlainTextResponse
from sqlalchemy import func, insert, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from ..config import settings
from ..db import get_session
from ..deps import (
    Principal,
    accessible_list,
    get_principal,
    rate_limit_principal,
    require_write,
)
from ..events import fire_webhooks, notify_list, record_change, validate_webhook_url
from ..models import Checklist, Item, ListMember, Role, Webhook, new_id, utcnow
from ..schemas import (
    ChecklistIn,
    ChecklistOut,
    ItemIn,
    ItemOut,
    ItemPatch,
    ItemsBulkIn,
    SummaryOut,
    WebhookIn,
    WebhookOut,
)
from ..security import new_email_token
from . import import_export

router = APIRouter(prefix="/lists", tags=["lists"])

# Tâches webhooks en vol (C1.3) : sans référence forte, asyncio peut les
# garbage-collecter avant leur exécution.
_in_flight_webhooks: set[asyncio.Task] = set()


async def _validate_parent(
    session: AsyncSession,
    list_id: UUID,
    parent_id: UUID | None,
    exclude_item_id: UUID | None = None,
    missing_status: int = status.HTTP_404_NOT_FOUND,
) -> None:
    """2.3 (prod3) : validation du parent PARTAGÉE (add_item, patch_item,
    upsert sync). Le parent doit exister dans la MÊME liste, ne pas être
    supprimé, ne pas être l'item lui-même (cycle) et ne pas être déjà une
    sous-tâche (max 1 niveau).

    [missing_status] : add_item garde son 404 historique (« comportement
    inchangé », verrouillé par test_subtasks_two_levels_max) ; patch_item et
    le chemin sync renvoient 400 (contrat « sinon 400 » de la spec)."""
    if parent_id is None:
        return
    result = await session.execute(select(Item).where(Item.id == parent_id))
    parent = result.scalar_one_or_none()
    if parent is None or parent.list_id != list_id or parent.deleted:
        raise HTTPException(missing_status, "Parent item not found")
    if exclude_item_id is not None and parent_id == exclude_item_id:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "An item cannot be its own parent"
        )
    if parent.parent_id is not None:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "Sub-tasks are limited to one level"
        )


def _fire_and_forget(coro) -> None:
    t = asyncio.create_task(coro)
    _in_flight_webhooks.add(t)
    t.add_done_callback(_in_flight_webhooks.discard)


@router.get("", response_model=list[ChecklistOut])
async def my_lists(
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    # Une clé API scopée ne voit QUE sa liste — même règle que le delta-read
    # (sync._accessible_list_ids) et accessible_list (deps.py) (audit run-3).
    if principal.list_scope is not None:
        row = (
            await session.execute(
                select(Checklist).where(
                    Checklist.id == principal.list_scope, Checklist.deleted.is_(False)
                )
            )
        ).scalar_one_or_none()
        if row is None:
            return []
        if row.owner_id == principal.user_id:
            role = "owner"
        else:
            member = (
                await session.execute(
                    select(ListMember).where(
                        ListMember.list_id == row.id,
                        ListMember.user_id == principal.user_id,
                    )
                )
            ).scalar_one_or_none()
            if member is None:
                return []
            role = member.role.value
        return [
            ChecklistOut(
                id=row.id,
                owner_id=row.owner_id,
                title=row.title,
                updated_at=row.updated_at,
                role=role,
                color=row.color,
                folder=row.folder,
            )
        ]
    owned = await session.execute(
        select(Checklist)
        .where(Checklist.owner_id == principal.user_id, Checklist.deleted.is_(False))
        .order_by(Checklist.updated_at.desc())
    )
    result = [
        ChecklistOut(
            id=c.id,
            owner_id=c.owner_id,
            title=c.title,
            updated_at=c.updated_at,
            role="owner",
            color=c.color,
            folder=c.folder,
        )
        for c in owned.scalars()
    ]
    # S5 (prod4) : un propriétaire ayant accepté sa propre invitation garde
    # une ligne ListMember EN PLUS de owner_id → sans ce filtre la liste
    # apparaîtrait deux fois (owner + member).
    memberships = await session.execute(
        select(ListMember, Checklist)
        .join(Checklist, Checklist.id == ListMember.list_id)
        .where(
            ListMember.user_id == principal.user_id,
            Checklist.owner_id != principal.user_id,
            Checklist.deleted.is_(False),
        )
        .order_by(Checklist.updated_at.desc())
    )
    for member, checklist in memberships.all():
        result.append(
            ChecklistOut(
                id=checklist.id,
                owner_id=checklist.owner_id,
                title=checklist.title,
                updated_at=checklist.updated_at,
                role=member.role.value,
                color=checklist.color,
                folder=checklist.folder,
            )
        )
    return result


# ---- Export par liste (spec 2026-11-25 F2/F3/F4) --------------------------
# Les routeurs de format vivent dans import_export (helpers partagés) ; ici
# uniquement l'accès par liste (prefix /lists). Lecture seule : un membre
# viewer peut exporter ce qu'il peut lire.


@router.get("/{list_id}/export.json")
async def export_list_json(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    # 1:1 modèle : tous les items, y compris les lignes soft-deleted
    # (flag `deleted` conservé) — backup fidèle.
    items = await import_export._items_of(session, list_id, include_deleted=True)
    return import_export._envelope([(checklist, items)])


@router.get("/{list_id}/export.md")
async def export_list_md(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    items = await import_export._items_of(session, list_id, include_deleted=False)
    return PlainTextResponse(
        import_export._md_for_list(checklist.title, items),
        media_type="text/markdown",
    )


@router.get("/{list_id}/export.csv")
async def export_list_csv(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    items = await import_export._items_of(session, list_id, include_deleted=False)
    return import_export._csv_response(
        [(checklist, items)], import_export._csv_filename(checklist.title)
    )


@router.post("", response_model=ChecklistOut, status_code=status.HTTP_201_CREATED)
async def create_list(
    data: ChecklistIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    if principal.list_scope is not None:
        # A scoped key is bound to its single list: no creation outside it
        # (Strix vuln-0002).
        raise HTTPException(status.HTTP_403_FORBIDDEN, "API key scoped to another list")
    checklist = Checklist(
        owner_id=principal.user_id,
        title=data.title,
        color=data.color,
        folder=data.folder,
    )
    session.add(checklist)
    await session.commit()
    await record_change(
        session, list_id=checklist.id, checklist_id=checklist.id, kind="list.create"
    )
    await notify_list(
        checklist.id, {"kind": "list.create", "list_id": str(checklist.id)}
    )
    return ChecklistOut(
        id=checklist.id,
        owner_id=checklist.owner_id,
        title=checklist.title,
        updated_at=checklist.updated_at,
        role="owner",
        color=checklist.color,
        folder=checklist.folder,
    )


@router.get("/{list_id}/items", response_model=list[ItemOut])
async def list_items(
    list_id: UUID,
    unchecked_only: bool = Query(default=False),
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session)
    query = (
        select(Item)
        .where(Item.list_id == list_id, Item.deleted.is_(False))
        .order_by(Item.position, Item.created_at)
    )
    if unchecked_only:
        query = query.where(Item.done.is_(False))
    result = await session.execute(query)
    return [ItemOut.model_validate(i) for i in result.scalars()]


@router.post(
    "/{list_id}/items",
    response_model=list[ItemOut],
    status_code=status.HTTP_201_CREATED,
)
async def add_item(
    list_id: UUID,
    data: ItemIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    # Sub-tasks: max 2 levels (a sub-task cannot have a sub-task).
    await _validate_parent(session, list_id, data.parent_id)
    item = await _add_single(
        session,
        list_id,
        data.label,
        principal.user_id,
        parent_id=data.parent_id,
        recurrence=data.recurrence,
        due_date=data.due_date,
        notes=data.notes,
        assignee_id=data.assignee_id,
    )
    return [ItemOut.model_validate(item)]


@router.post(
    "/{list_id}/items/bulk",
    response_model=list[ItemOut],
    status_code=status.HTTP_201_CREATED,
)
async def add_items_bulk(
    list_id: UUID,
    data: ItemsBulkIn,
    principal: Principal = Depends(require_write),
    _rate_limited: Principal = Depends(rate_limit_principal),
    session: AsyncSession = Depends(get_session),
):
    """One item per line — designed for quick-add paste and agents."""
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    max_pos = await session.execute(
        select(func.coalesce(func.max(Item.position), -1)).where(
            Item.list_id == list_id
        )
    )
    # coalesce garantit non-None (`or -1` traitait 0 comme absent)
    position = max_pos.scalar() + 1
    lines = [line.strip() for line in data.text.splitlines() if line.strip()]
    if not lines:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "No non-empty lines")
    items = []
    for line in lines[:500]:
        item = Item(
            list_id=list_id, label=line, position=position, created_by=principal.user_id
        )
        session.add(item)
        items.append(item)
        position += 1
    await session.commit()
    out = []
    for item in items:
        await record_change(
            session, list_id=list_id, item_id=item.id, kind="item.upsert", commit=False
        )
        out.append(ItemOut.model_validate(item))
    await session.commit()
    await notify_list(
        list_id, {"kind": "items.added", "list_id": str(list_id), "count": len(out)}
    )
    return out


@router.patch("/{list_id}/items/{item_id}", response_model=list[ItemOut])
async def patch_item(
    list_id: UUID,
    item_id: UUID,
    data: ItemPatch,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    result = await session.execute(
        select(Item).where(
            Item.id == item_id, Item.list_id == list_id, Item.deleted.is_(False)
        )
    )
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Item not found")
    if data.updated_at is not None:
        from .sync import (  # import local : sync.py importe déjà lists (L15)
            _clamp_client_dt,
            _utc_naive,
        )

        client_ts = _clamp_client_dt(data.updated_at)
        if _utc_naive(client_ts) > _utc_naive(item.updated_at):
            item.updated_at = client_ts
    # Recurrence fires on the not-done -> done transition only: re-sending
    # done=true for an already completed item (client retry, agent calling
    # check twice) must not spawn another occurrence.
    newly_done = data.done is True and not item.done
    if data.label is not None:
        item.label = data.label
    if data.done is not None:
        item.done = data.done
    if data.position is not None:
        item.position = data.position
    # null = vider (C1.2) : le champ n'est appliqué que s'il est présent
    # dans le body — le défaut None de ItemPatch ne distingue pas « absent »
    # de « null » autrement que par model_fields_set.
    if "notes" in data.model_fields_set:
        item.notes = data.notes
    if "assignee_id" in data.model_fields_set:
        item.assignee_id = data.assignee_id
    if "due_date" in data.model_fields_set:
        item.due_date = data.due_date
    if "recurrence" in data.model_fields_set:
        item.recurrence = data.recurrence or "none"
    if "parent_id" in data.model_fields_set:
        # 2.3 (prod3) : le parent est validé comme partout ailleurs
        # (autre liste / supprimé / soi-même / sous-tâche → 400).
        await _validate_parent(
            session,
            list_id,
            data.parent_id,
            exclude_item_id=item_id,
            missing_status=400,
        )
        item.parent_id = data.parent_id
    if item.updated_at is None:
        item.updated_at = utcnow()
    await session.commit()
    # Recurrence: checking a recurring item spawns the next occurrence.
    spawned = None
    if newly_done and item.recurrence and item.recurrence != "none":
        spawned = await _spawn_next(session, item, principal.user_id)
    await record_change(session, list_id=list_id, item_id=item.id, kind="item.upsert")
    await notify_list(
        list_id, {"kind": "item.upsert", "list_id": str(list_id), "id": str(item.id)}
    )
    # C1.3 : fire-and-forget — une webhook lente ne retarde pas la réponse.
    _fire_and_forget(
        fire_webhooks(
            list_id,
            {
                "event": "item.checked" if data.done is True else "item.updated",
                "list_id": str(list_id),
                "item_id": str(item.id),
                "label": item.label,
                "recurrence": item.recurrence,
            },
        )
    )
    result = ItemOut.model_validate(item)
    if spawned is not None:
        return [result, ItemOut.model_validate(spawned)]
    return [result]


@router.delete("/{list_id}/items/{item_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_item(
    list_id: UUID,
    item_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    result = await session.execute(
        select(Item).where(
            Item.id == item_id, Item.list_id == list_id, Item.deleted.is_(False)
        )
    )
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Item not found")
    item.deleted = True
    item.updated_at = utcnow()
    await session.commit()
    await record_change(session, list_id=list_id, item_id=item.id, kind="item.delete")
    await notify_list(
        list_id, {"kind": "item.delete", "list_id": str(list_id), "id": str(item.id)}
    )
    return None


@router.delete("/{list_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_list(
    list_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    if checklist.owner_id != principal.user_id:
        raise HTTPException(
            status.HTTP_403_FORBIDDEN, "Only the owner can delete a list"
        )
    checklist.deleted = True
    checklist.updated_at = utcnow()
    await session.commit()
    await record_change(
        session, list_id=list_id, checklist_id=checklist.id, kind="list.delete"
    )
    await notify_list(list_id, {"kind": "list.delete", "list_id": str(list_id)})
    return None


@router.patch("/{list_id}", response_model=ChecklistOut)
async def rename_list(
    list_id: UUID,
    data: ChecklistIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist, member = await accessible_list(
        list_id, principal, session, min_role=Role.editor
    )
    checklist.title = data.title
    # null = vider (C1.2) : appliqué seulement si le champ est présent.
    if "color" in data.model_fields_set:
        checklist.color = data.color
    if "folder" in data.model_fields_set:
        checklist.folder = data.folder
    checklist.updated_at = utcnow()
    await session.commit()
    await record_change(
        session, list_id=list_id, checklist_id=checklist.id, kind="list.rename"
    )
    await notify_list(
        list_id, {"kind": "list.rename", "list_id": str(list_id), "title": data.title}
    )
    # 2.3 (prod3) : le rôle réel (owner pour le propriétaire, pas "member"
    # en dur) et le folder (omis avant le fix).
    role = "owner" if checklist.owner_id == principal.user_id else member.role.value
    return ChecklistOut(
        id=checklist.id,
        owner_id=checklist.owner_id,
        title=checklist.title,
        updated_at=checklist.updated_at,
        role=role,
        color=checklist.color,
        folder=checklist.folder,
    )


async def _add_single(
    session: AsyncSession,
    list_id: UUID,
    label: str,
    user_id: UUID,
    parent_id: UUID | None = None,
    recurrence: str = "none",
    due_date=None,
    notes: str | None = None,
    assignee_id: UUID | None = None,
) -> Item:
    max_pos = await session.execute(
        select(func.coalesce(func.max(Item.position), -1)).where(
            Item.list_id == list_id
        )
    )
    item = Item(
        list_id=list_id,
        label=label,
        notes=notes,
        assignee_id=assignee_id,
        # coalesce garantit non-None (`or -1` traitait 0 comme absent)
        position=max_pos.scalar() + 1,
        created_by=user_id,
        parent_id=parent_id,
        recurrence=recurrence,
        due_date=due_date,
    )
    session.add(item)
    await session.commit()
    await record_change(session, list_id=list_id, item_id=item.id, kind="item.upsert")
    await notify_list(
        list_id, {"kind": "item.upsert", "list_id": str(list_id), "id": str(item.id)}
    )
    return item


def _add_months(dt: datetime, months: int) -> datetime:
    """Calendar month arithmetic: 31 janv -> 28/29 févr, 31 mars -> 30 avr…"""
    total = dt.month - 1 + months
    year = dt.year + total // 12
    month = total % 12 + 1
    # Clamp the day to the target month's length (no spillover into the
    # following month like a plain +30 days would do).
    import calendar

    day = min(dt.day, calendar.monthrange(year, month)[1])
    return dt.replace(year=year, month=month, day=day)


async def _spawn_next(
    session: AsyncSession,
    item: Item,
    user_id: UUID,
    commit: bool = True,
    pending: list | None = None,
) -> Item | None:
    """Create the next occurrence of a recurring item (unchecked, next due date).

    Idempotent per source item: the occurrence records the id of the item it
    was spawned from, and a unique index allows only one. Completing the same
    item again (retry, concurrent request, uncheck + re-check) returns None
    instead of creating a duplicate. The spawned id is generated up front
    (new_id) so the changelog and the deferred notification carry the real id
    without an intermediate flush.

    commit=False (chemin sync) : pas de commit ni flush intermédiaires — le
    commit de fin de batch de l'appelant couvre la ligne ; `pending` collecte
    la notification au lieu de l'émettre (elle doit partir après ce commit).
    """
    from datetime import timedelta

    existing = await session.execute(
        select(Item.id).where(Item.recurrence_source_id == item.id).limit(1)
    )
    if existing.scalar_one_or_none() is not None:
        return None

    now = utcnow()
    due = item.due_date or now
    if item.recurrence == "daily":
        next_due = due + timedelta(days=1)
    elif item.recurrence == "weekly":
        next_due = due + timedelta(weeks=1)
    else:  # monthly: real calendar months, not a flat +30 days
        next_due = _add_months(due, 1)
    next_item = Item(
        id=new_id(),
        list_id=item.list_id,
        parent_id=item.parent_id,
        label=item.label,
        position=item.position + 1,
        created_by=user_id,
        recurrence=item.recurrence,
        due_date=next_due,
        recurrence_source_id=item.id,
    )
    if commit:
        session.add(next_item)
        try:
            await session.commit()
        except IntegrityError:
            # A concurrent completion won the race and already spawned it.
            await session.rollback()
            await session.refresh(item)  # rollback expired it; reload (async-safe)
            return None
    else:
        # Chemin sync (commit=False, C1.1d) : INSERT Core DEDANS un savepoint.
        # Pas de session.add : un objet ORM en attente au moment du
        # begin_nested() déclenche le snapshot-flush de toute la session sur
        # la transaction PARENT (SessionTransaction._take_snapshot) — un
        # conflit unique là-bas tuerait le batch entier. Un INSERT Core
        # échoue au plus dans le savepoint, annulé seul ; les écritures du
        # batch restent en attente et saines.
        try:
            async with session.begin_nested():
                await session.execute(
                    insert(Item).values(
                        id=next_item.id,
                        list_id=next_item.list_id,
                        parent_id=next_item.parent_id,
                        label=next_item.label,
                        notes=None,
                        assignee_id=None,
                        done=False,
                        position=next_item.position,
                        recurrence=next_item.recurrence,
                        due_date=next_item.due_date,
                        recurrence_source_id=next_item.recurrence_source_id,
                        created_by=next_item.created_by,
                        created_at=now,
                        updated_at=now,
                        deleted=False,
                    )
                )
        except IntegrityError:
            existing = await session.execute(
                select(Item.id).where(Item.recurrence_source_id == item.id).limit(1)
            )
            if existing.scalar_one_or_none() is None:
                raise  # autre contrainte unique : ce n'est pas cette race
            return None  # l'occurrence existe déjà (l'exécution concurrente a gagné)
    await record_change(
        session,
        list_id=item.list_id,
        item_id=next_item.id,
        kind="item.upsert",
        commit=commit,
    )
    if pending is not None:
        pending.append(
            (
                item.list_id,
                {
                    "kind": "item.upsert",
                    "list_id": str(item.list_id),
                    "id": str(next_item.id),
                },
            )
        )
    else:
        await notify_list(
            item.list_id,
            {
                "kind": "item.upsert",
                "list_id": str(item.list_id),
                "id": str(next_item.id),
            },
        )
    return next_item


@router.get("/{list_id}/summary", response_model=SummaryOut)
async def list_summary(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    """Compact digest — designed for agents and notifications."""
    await accessible_list(list_id, principal, session)
    checklist = (
        await session.execute(select(Checklist).where(Checklist.id == list_id))
    ).scalar_one()
    items = await unchecked_of(session, list_id)
    # 2.3 (prod3) : total = TOUS les items non supprimés de la liste
    # (avant le fix, total était == unchecked).
    total = (
        await session.execute(
            select(func.count()).where(Item.list_id == list_id, Item.deleted.is_(False))
        )
    ).scalar_one()
    return SummaryOut(
        list_id=list_id,
        title=checklist.title,
        total=total,
        unchecked=len(items),
        unchecked_labels=[i.label for i in items],
    )


async def unchecked_of(session, list_id):
    result = await session.execute(
        select(Item)
        .where(Item.list_id == list_id, Item.deleted.is_(False), Item.done.is_(False))
        .order_by(Item.position)
    )
    return list(result.scalars())


@router.delete("/{list_id}/done-items", status_code=status.HTTP_204_NO_CONTENT)
async def purge_done_items(
    list_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    """Archive: soft-delete every checked item of the list."""
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    result = await session.execute(
        select(Item).where(
            Item.list_id == list_id, Item.deleted.is_(False), Item.done.is_(True)
        )
    )
    now = utcnow()
    count = 0
    for item in result.scalars():
        item.deleted = True
        item.updated_at = now
        count += 1
    await session.commit()
    if count:
        await record_change(
            session, list_id=list_id, kind="item.purge", actor_id=principal.user_id
        )
        await notify_list(
            list_id, {"kind": "items.purged", "list_id": str(list_id), "count": count}
        )
        _fire_and_forget(
            fire_webhooks(
                list_id,
                {
                    "event": "items.purged",
                    "list_id": str(list_id),
                    "count": count,
                },
            )
        )
    return None


# ---- Webhooks ------------------------------------------------------------


@router.post(
    "/{list_id}/hooks", response_model=WebhookOut, status_code=status.HTTP_201_CREATED
)
async def create_hook(
    list_id: UUID,
    data: WebhookIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    # SSRF gate at creation (Strix vuln-0004); delivery re-checks it.
    # M3 (prod4) : validate_webhook_url est async (DNS via to_thread).
    allowed, _ = await validate_webhook_url(data.url)
    if not allowed:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Invalid webhook URL")
    # Plafond par liste (audit lot T) : borne le gather de fire_webhooks.
    count = (
        await session.execute(select(func.count()).where(Webhook.list_id == list_id))
    ).scalar_one()
    if count >= settings.WEBHOOKS_MAX_PER_LIST:
        raise HTTPException(
            status.HTTP_409_CONFLICT, "Plafond de webhooks atteint pour cette liste"
        )
    hook = Webhook(
        list_id=list_id,
        user_id=principal.user_id,
        url=data.url,
        secret=new_email_token(),
    )
    session.add(hook)
    await session.commit()
    return WebhookOut(id=hook.id, list_id=list_id, url=hook.url, secret=hook.secret)


@router.get("/{list_id}/hooks", response_model=list[WebhookOut])
async def list_hooks(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    result = await session.execute(select(Webhook).where(Webhook.list_id == list_id))
    # Le secret signe les livraisons : seul le propriétaire de la liste (et un
    # admin) peut le lire — un membre ou une clé API scopée ne doit pas pouvoir
    # l'exfiltrer.
    can_read_secret = principal.is_admin or (
        principal.list_scope is None and checklist.owner_id == principal.user_id
    )
    return [
        WebhookOut(
            id=h.id,
            list_id=h.list_id,
            url=h.url,
            secret=h.secret if can_read_secret else None,
        )
        for h in result.scalars()
    ]


@router.delete("/{list_id}/hooks/{hook_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_hook(
    list_id: UUID,
    hook_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    hook = await session.get(Webhook, hook_id)
    if hook is None or hook.list_id != list_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Hook not found")
    await session.delete(hook)
    await session.commit()
    return None
