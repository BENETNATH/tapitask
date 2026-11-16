from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import Principal, accessible_list, get_principal, require_write
from ..models import Checklist, Item, ListMember, Role, utcnow
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
from ..events import record_change, notify_list, fire_webhooks
from ..models import Webhook
from ..security import new_email_token

router = APIRouter(prefix="/lists", tags=["lists"])


@router.get("", response_model=list[ChecklistOut])
async def my_lists(
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    owned = await session.execute(
        select(Checklist).where(Checklist.owner_id == principal.user_id, Checklist.deleted.is_(False))
        .order_by(Checklist.updated_at.desc())
    )
    result = [
        ChecklistOut(
            id=c.id, owner_id=c.owner_id, title=c.title, updated_at=c.updated_at,
            role="owner", color=c.color, folder=c.folder
        )
        for c in owned.scalars()
    ]
    memberships = await session.execute(
        select(ListMember, Checklist)
        .join(Checklist, Checklist.id == ListMember.list_id)
        .where(ListMember.user_id == principal.user_id, Checklist.deleted.is_(False))
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


@router.post("", response_model=ChecklistOut, status_code=status.HTTP_201_CREATED)
async def create_list(
    data: ChecklistIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist = Checklist(owner_id=principal.user_id, title=data.title, color=data.color, folder=data.folder)
    session.add(checklist)
    await session.commit()
    await record_change(session, list_id=checklist.id, checklist_id=checklist.id, kind="list.create")
    await notify_list(checklist.id, {"kind": "list.create", "list_id": str(checklist.id)})
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
    filter_done: bool | None = Query(default=None, alias="filter"),
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
    return [ItemOut(**_item_out(i)) for i in result.scalars()]


@router.post("/{list_id}/items", response_model=list[ItemOut], status_code=status.HTTP_201_CREATED)
async def add_item(
    list_id: UUID,
    data: ItemIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    # Sub-tasks: max 2 levels (a sub-task cannot have a sub-task).
    if data.parent_id is not None:
        parent = await session.get(Item, data.parent_id)
        if parent is None or parent.list_id != list_id or parent.deleted:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Parent item not found")
        if parent.parent_id is not None:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Sub-tasks are limited to one level")
    item = await _add_single(session, list_id, data.label, principal.user_id,
                             parent_id=data.parent_id, recurrence=data.recurrence,
                             due_date=data.due_date, notes=data.notes,
                             assignee_id=data.assignee_id)
    return [ItemOut(**_item_out(item))]


@router.post("/{list_id}/items/bulk", response_model=list[ItemOut], status_code=status.HTTP_201_CREATED)
async def add_items_bulk(
    list_id: UUID,
    data: ItemsBulkIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    """One item per line — designed for quick-add paste and agents."""
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    max_pos = await session.execute(
        select(func.coalesce(func.max(Item.position), -1)).where(Item.list_id == list_id)
    )
    position = (max_pos.scalar() or -1) + 1
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
        await record_change(session, list_id=list_id, item_id=item.id, kind="item.upsert")
        out.append(ItemOut(**_item_out(item)))
    await session.commit()
    await notify_list(list_id, {"kind": "items.added", "list_id": str(list_id), "count": len(out)})
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
        select(Item).where(Item.id == item_id, Item.list_id == list_id, Item.deleted.is_(False))
    )
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Item not found")
    if data.updated_at is not None and (
        (data.updated_at.tzinfo is None) == (item.updated_at.tzinfo is None)
        and data.updated_at > item.updated_at
    ):
        item.updated_at = data.updated_at
    if data.label is not None:
        item.label = data.label
    if data.done is not None:
        item.done = data.done
    if data.position is not None:
        item.position = data.position
    if data.notes is not None:
        item.notes = data.notes
    if data.assignee_id is not None:
        item.assignee_id = data.assignee_id
    if data.due_date is not None:
        item.due_date = data.due_date
    if data.recurrence is not None:
        item.recurrence = data.recurrence
    if item.updated_at is None:
        item.updated_at = utcnow()
    await session.commit()
    # Recurrence: checking a recurring item spawns the next occurrence.
    spawned = None
    if data.done is True and item.recurrence and item.recurrence != "none":
        spawned = await _spawn_next(session, item, principal.user_id)
    await record_change(session, list_id=list_id, item_id=item.id, kind="item.upsert")
    await notify_list(list_id, {"kind": "item.upsert", "list_id": str(list_id), "id": str(item.id)})
    await fire_webhooks(session, list_id, {
        "event": "item.checked" if data.done is True else "item.updated",
        "list_id": str(list_id), "item_id": str(item.id), "label": item.label,
        "recurrence": item.recurrence,
    })
    result = ItemOut(**_item_out(item))
    if spawned is not None:
        return [result, ItemOut(**_item_out(spawned))]
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
        select(Item).where(Item.id == item_id, Item.list_id == list_id, Item.deleted.is_(False))
    )
    item = result.scalar_one_or_none()
    if item is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Item not found")
    item.deleted = True
    item.updated_at = utcnow()
    await session.commit()
    await record_change(session, list_id=list_id, item_id=item.id, kind="item.delete")
    await notify_list(list_id, {"kind": "item.delete", "list_id": str(list_id), "id": str(item.id)})
    return None


@router.delete("/{list_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_list(
    list_id: UUID,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session)
    if checklist.owner_id != principal.user_id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Only the owner can delete a list")
    checklist.deleted = True
    checklist.updated_at = utcnow()
    await session.commit()
    await record_change(session, list_id=list_id, checklist_id=checklist.id, kind="list.delete")
    await notify_list(list_id, {"kind": "list.delete", "list_id": str(list_id)})
    return None


@router.patch("/{list_id}", response_model=ChecklistOut)
async def rename_list(
    list_id: UUID,
    data: ChecklistIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    checklist, _ = await accessible_list(list_id, principal, session, min_role=Role.editor)
    checklist.title = data.title
    if data.color is not None:
        checklist.color = data.color
    if data.folder is not None:
        checklist.folder = data.folder
    checklist.updated_at = utcnow()
    await session.commit()
    await record_change(session, list_id=list_id, checklist_id=checklist.id, kind="list.rename")
    await notify_list(list_id, {"kind": "list.rename", "list_id": str(list_id), "title": data.title})
    return ChecklistOut(
        id=checklist.id,
        owner_id=checklist.owner_id,
        title=checklist.title,
        updated_at=checklist.updated_at,
        role="member",
        color=checklist.color,
    )


async def _add_single(session: AsyncSession, list_id: UUID, label: str, user_id: UUID,
                      parent_id: UUID | None = None, recurrence: str = "none",
                      due_date=None, notes: str | None = None,
                      assignee_id: UUID | None = None) -> Item:
    max_pos = await session.execute(
        select(func.coalesce(func.max(Item.position), -1)).where(Item.list_id == list_id)
    )
    item = Item(
        list_id=list_id,
        label=label,
        notes=notes,
        assignee_id=assignee_id,
        position=(max_pos.scalar() or -1) + 1,
        created_by=user_id,
        parent_id=parent_id,
        recurrence=recurrence,
        due_date=due_date,
    )
    session.add(item)
    await session.commit()
    await record_change(session, list_id=list_id, item_id=item.id, kind="item.upsert")
    await notify_list(list_id, {"kind": "item.upsert", "list_id": str(list_id), "id": str(item.id)})
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


async def _spawn_next(session: AsyncSession, item: Item, user_id: UUID) -> Item:
    """Create the next occurrence of a recurring item (unchecked, next due date)."""
    from datetime import timedelta

    now = utcnow()
    due = item.due_date or now
    if item.recurrence == "daily":
        next_due = due + timedelta(days=1)
    elif item.recurrence == "weekly":
        next_due = due + timedelta(weeks=1)
    else:  # monthly: real calendar months, not a flat +30 days
        next_due = _add_months(due, 1)
    next_item = Item(
        list_id=item.list_id,
        parent_id=item.parent_id,
        label=item.label,
        position=item.position + 1,
        created_by=user_id,
        recurrence=item.recurrence,
        due_date=next_due,
    )
    session.add(next_item)
    await session.commit()
    await record_change(session, list_id=item.list_id, item_id=next_item.id, kind="item.upsert")
    await notify_list(item.list_id, {"kind": "item.upsert", "list_id": str(item.list_id), "id": str(next_item.id)})
    return next_item


def _item_out(item: Item) -> dict:
    return {
        "id": item.id,
        "list_id": item.list_id,
        "parent_id": item.parent_id,
        "label": item.label,
        "done": item.done,
        "position": item.position,
        "recurrence": item.recurrence,
        "due_date": item.due_date,
        "notes": item.notes,
        "assignee_id": item.assignee_id,
        "updated_at": item.updated_at,
    }


@router.get("/{list_id}/summary", response_model=SummaryOut)
async def list_summary(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    """Compact digest — designed for agents and notifications."""
    await accessible_list(list_id, principal, session)
    checklist = (await session.execute(
        select(Checklist).where(Checklist.id == list_id))).scalar_one()
    items = await unchecked_of(session, list_id)
    return SummaryOut(
        list_id=list_id,
        title=checklist.title,
        total=len(items),
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
        select(Item).where(Item.list_id == list_id, Item.deleted.is_(False), Item.done.is_(True))
    )
    now = utcnow()
    count = 0
    for item in result.scalars():
        item.deleted = True
        item.updated_at = now
        count += 1
    await session.commit()
    if count:
        await record_change(session, list_id=list_id, kind="item.purge", actor_id=principal.user_id)
        await notify_list(list_id, {"kind": "items.purged", "list_id": str(list_id), "count": count})
        await fire_webhooks(session, list_id, {
            "event": "items.purged", "list_id": str(list_id), "count": count,
        })
    return None


# ---- Webhooks ------------------------------------------------------------


@router.post("/{list_id}/hooks", response_model=WebhookOut, status_code=status.HTTP_201_CREATED)
async def create_hook(
    list_id: UUID,
    data: WebhookIn,
    principal: Principal = Depends(require_write),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session, min_role=Role.editor)
    hook = Webhook(list_id=list_id, user_id=principal.user_id,
                   url=data.url, secret=new_email_token())
    session.add(hook)
    await session.commit()
    return WebhookOut(id=hook.id, list_id=list_id, url=hook.url, secret=hook.secret)


@router.get("/{list_id}/hooks", response_model=list[WebhookOut])
async def list_hooks(
    list_id: UUID,
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    await accessible_list(list_id, principal, session)
    result = await session.execute(select(Webhook).where(Webhook.list_id == list_id))
    return [WebhookOut(id=h.id, list_id=h.list_id, url=h.url, secret=h.secret)
            for h in result.scalars()]


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
