"""F2/F3/F4 (spec 2026-11-25) : export/import JSON, Obsidian markdown, CSV.

Routes top-level (sans prefix) :
- GET /export.json?scope=all — listes possédées + memberships
- GET /export.csv?scope=all
- POST /import?name=<facultatif> — body JSON (enveloppe tapitask) ou
  markdown Obsidian (détection : 1er caractère non blanc « - [ »)

Les exports par liste vivent dans routers/lists.py (prefix /lists).

Décisions documentées (spec §D-4/D-5) :
- L'import crée TOUJOURS de nouvelles listes à nouveaux UUIDs (jamais de
  merge ni d'écrasement) : les IDs servent au sync/LWW côté client, les
  réutiliser d'un compte à l'autre casserait la convergence.
- assignee_id / created_by → null à l'import (utilisateur d'un autre
  compte) ; parent_id / recurrence_source_id sont remappés à l'intérieur
  de l'import (une référence en dehors → 400).
- Les exports excluent membres/webhooks/ChangeLog/tokens : une migration
  de listes entre comptes reste possible, les invitations non.
- L'export JSON est 1:1 avec les modèles : TOUS les items de la liste
  (y compris les lignes soft-deleted, flag `deleted` conservé à l'import) ;
  md/CSV exportent les items non supprimés uniquement.
- La convention d'échéance markdown ` (échéance YYYY-MM-DD)` utilise la
  DATE UTC du datetime stocké.
- md sans H1 : titre = ?name= (nom de fichier) sinon « Importée ».
- Aucune syntaxe Obsidian native n'est parsée (hors périmètre, D-5).
"""

from __future__ import annotations

import json
import re
import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ..db import get_session
from ..deps import (
    Principal,
    get_principal,
    rate_limit_principal,
    require_write,
)
from ..events import notify_list, record_change
from ..models import Checklist, Item, ListMember, new_id, utcnow

router = APIRouter(tags=["import-export"])

INVALID_IMPORT = "Invalid import format"

# Bornes d'import (DoS) : l'import est un canal écriture lourd ; un body
# géant ne doit pas pouvoir inonder la base.
MAX_IMPORTED_LISTS = 100
MAX_IMPORTED_ITEMS = 5000

_ITEM_LABELS = re.compile(r"^\s*- \[( |x|X)\]\s*(.+)$")
_H1 = re.compile(r"^#\s+(.+)$")
_DUE = re.compile(r"\s*\(échéance (\d{4})-(\d{2})-(\d{2})\)\s*$")


def _utc(dt: datetime | None) -> datetime | None:
    """SQLite rend les datetimes naive (supposés UTC) ; PG les rend aware.
    Une seule forme (aware UTC) pour les sorties d'export."""
    if dt is None:
        return None
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)


def _parse_uuid(value: Any, field: str) -> uuid.UUID | None:
    if value is None:
        return None
    if isinstance(value, uuid.UUID):
        return value
    if not isinstance(value, str):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    try:
        return uuid.UUID(value)
    except ValueError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT) from None


def _parse_optional_str(
    value: Any, field: str, max_len: int | None = None
) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or (value and "\x00" in value):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    if max_len is not None and len(value) > max_len:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    return value


def _parse_due(value: Any) -> datetime | None:
    """due_date : str ISO 8601 (export JSON) ou datetime (parseur md).
    Naive → supposé UTC. Toute autre forme → 400."""
    if value is None:
        return None
    if isinstance(value, datetime):
        dt = value
    elif isinstance(value, str):
        try:
            dt = datetime.fromisoformat(value)
        except ValueError:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT) from None
    else:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    return dt if dt.tzinfo is not None else dt.replace(tzinfo=timezone.utc)


def _item_payload(item: Item) -> dict[str, Any]:
    """Tous les champs réels de Item (1:1 modèle — spec F2)."""
    return {
        "id": str(item.id),
        "list_id": str(item.list_id),
        "parent_id": str(item.parent_id) if item.parent_id is not None else None,
        "label": item.label,
        "notes": item.notes,
        "assignee_id": str(item.assignee_id) if item.assignee_id is not None else None,
        "done": item.done,
        "position": item.position,
        "recurrence": item.recurrence,
        "due_date": _utc(item.due_date).isoformat()
        if item.due_date is not None
        else None,
        "recurrence_source_id": (
            str(item.recurrence_source_id)
            if item.recurrence_source_id is not None
            else None
        ),
        "created_by": str(item.created_by) if item.created_by is not None else None,
        "created_at": _utc(item.created_at).isoformat()
        if item.created_at is not None
        else None,
        "updated_at": _utc(item.updated_at).isoformat()
        if item.updated_at is not None
        else None,
        "deleted": item.deleted,
    }


async def _items_of(
    session: AsyncSession, list_id: uuid.UUID, include_deleted: bool
) -> list[Item]:
    query = (
        select(Item)
        .where(Item.list_id == list_id)
        .order_by(Item.position, Item.created_at)
    )
    if not include_deleted:
        query = query.where(Item.deleted.is_(False))
    return list((await session.execute(query)).scalars())


def _list_payload(checklist: Checklist, items: list[Item]) -> dict[str, Any]:
    return {
        "id": str(checklist.id),
        "title": checklist.title,
        "color": checklist.color,
        "folder": checklist.folder,
        "items": [_item_payload(i) for i in items],
    }


def _envelope(checklists_items: list[tuple[Checklist, list[Item]]]) -> dict[str, Any]:
    return {
        "tapitask": 1,
        "exported_at": utcnow().isoformat(),
        "lists": [_list_payload(c, items) for c, items in checklists_items],
    }


async def _accessible_lists(
    session: AsyncSession, principal: Principal
) -> list[Checklist]:
    """Listes visibles par le principal (export scope=all) : possédées +
    memberships — mêmes règles que GET /lists (clé API scopée incluse,
    memberships du propriétaire exclus : pas de doublon owner+member)."""
    if principal.list_scope is not None:
        row = (
            await session.execute(
                select(Checklist).where(
                    Checklist.id == principal.list_scope,
                    Checklist.deleted.is_(False),
                )
            )
        ).scalar_one_or_none()
        if row is None:
            return []
        if row.owner_id == principal.user_id:
            return [row]
        member = (
            await session.execute(
                select(ListMember).where(
                    ListMember.list_id == row.id,
                    ListMember.user_id == principal.user_id,
                )
            )
        ).scalar_one_or_none()
        return [row] if member is not None else []
    owned = (
        (
            await session.execute(
                select(Checklist).where(
                    Checklist.owner_id == principal.user_id,
                    Checklist.deleted.is_(False),
                )
            )
        )
        .scalars()
        .all()
    )
    members = (
        (
            await session.execute(
                select(Checklist)
                .join(ListMember, ListMember.list_id == Checklist.id)
                .where(
                    ListMember.user_id == principal.user_id,
                    Checklist.owner_id != principal.user_id,
                    Checklist.deleted.is_(False),
                )
            )
        )
        .scalars()
        .all()
    )
    return [*owned, *members]


async def _export_lists(
    session: AsyncSession, principal: Principal
) -> list[tuple[Checklist, list[Item]]]:
    pairs: list[tuple[Checklist, list[Item]]] = []
    for checklist in await _accessible_lists(session, principal):
        items = await _items_of(session, checklist.id, include_deleted=False)
        pairs.append((checklist, items))
    return pairs


def _due_suffix(due: datetime | None) -> str:
    """Convention D-5 : ` (échéance YYYY-MM-DD)` — date UTC."""
    if due is None:
        return ""
    return f" (échéance {_utc(due).date().isoformat()})"


def _md_for_list(title: str, items: list[Item]) -> str:
    lines = [f"# {title}"]
    for item in items:
        box = "x" if item.done else " "
        lines.append(f"- [{box}] {item.label}{_due_suffix(item.due_date)}")
    return "\n".join(lines) + "\n"


_CSV_SEP = ";"


def _csv_field(value: str) -> str:
    """Échappement CSV (séparateur `;` — convention Excel FR, D-6) :
    un champ contenant ; ou , ou " ou un retour à la ligne est mis entre
    guillemets doubles, les " internes doublés."""
    if any(c in value for c in (_CSV_SEP, ",", '"', "\n", "\r")):
        return '"' + value.replace('"', '""') + '"'
    return value


def _csv_filename(title: str | None) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (title or "").lower()).strip("-")
    return f"tapitask-{slug or 'list'}.csv"


def _csv_content(pairs: list[tuple[Checklist, list[Item]]]) -> str:
    lines = ["liste;titre;fait;echeance;ordre"]
    for checklist, items in pairs:
        for item in items:
            due = _utc(item.due_date)
            lines.append(
                ";".join(
                    [
                        _csv_field(checklist.title),
                        _csv_field(item.label),
                        "1" if item.done else "0",
                        due.isoformat() if due is not None else "",
                        str(item.position),
                    ]
                )
            )
    return "\n".join(lines) + "\n"


def _csv_response(pairs: list[tuple[Checklist, list[Item]]], filename: str) -> Response:
    return Response(
        content=_csv_content(pairs),
        media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# ---- Routes ----------------------------------------------------------------


@router.get("/export.json")
async def export_all_json(
    scope: str = Query(default="all"),
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    if scope != "all":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "scope must be 'all'")
    return _envelope(await _export_lists(session, principal))


@router.get("/export.csv")
async def export_all_csv(
    scope: str = Query(default="all"),
    principal: Principal = Depends(get_principal),
    session: AsyncSession = Depends(get_session),
):
    if scope != "all":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "scope must be 'all'")
    return _csv_response(await _export_lists(session, principal), "tapitask-all.csv")


def _validate_json_lists(data: Any) -> list[dict[str, Any]]:
    """JSON parsé → listes d'entrées valides (validité stricte, message
    uniforme 400)."""
    if not isinstance(data, dict) or not isinstance(data.get("lists"), list):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    entries = data["lists"]
    if len(entries) > MAX_IMPORTED_LISTS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
    total_items = 0
    for entry in entries:
        if not isinstance(entry, dict):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        title = entry.get("title")
        if not isinstance(title, str) or not title.strip() or len(title) > 200:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        color = entry.get("color")
        if color is not None and (
            not isinstance(color, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", color)
        ):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        folder = entry.get("folder")
        if folder is not None and (not isinstance(folder, str) or len(folder) > 100):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        items = entry.get("items", [])
        if not isinstance(items, list) or len(items) > MAX_IMPORTED_ITEMS:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        total_items += len(items)
        if total_items > MAX_IMPORTED_ITEMS:
            # Plafond sur l'ENSEMBLE de la requête, pas seulement par
            # liste (SEC-F2) : sans ça, MAX_IMPORTED_LISTS × MAX_IMPORTED_ITEMS
            # items passent en une seule transaction.
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        seen_ids: set[str] = set()
        for it in items:
            if not isinstance(it, dict):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            # Id source dupliqué → le remappage 1:1 créerait deux items
            # au même UUID (IntegrityError) : corps non-conforme → 400.
            raw_id = it.get("id")
            if isinstance(raw_id, str) and raw_id:
                if raw_id in seen_ids:
                    raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
                seen_ids.add(raw_id)
            label = it.get("label")
            if (
                not isinstance(label, str)
                or not label.strip()
                or len(label) > 2000
                or "\x00" in label
            ):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            recurrence = it.get("recurrence", "none")
            if recurrence not in ("none", "daily", "weekly", "monthly"):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            if not isinstance(it.get("done", False), bool):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            if not isinstance(it.get("deleted", False), bool):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            position = it.get("position", 0)
            if not isinstance(position, int) or isinstance(position, bool):
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            notes = _parse_optional_str(it.get("notes"), "notes")
            if notes is not None and len(notes) > 5000:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            _parse_uuid(it.get("parent_id"), "parent_id")
            _parse_uuid(it.get("recurrence_source_id"), "recurrence_source_id")
            _parse_due(it.get("due_date"))
    return entries


def _build_items(entries: list[dict[str, Any]], now: datetime) -> list[Item]:
    """Toutes les lignes Item de l'import : nouveaux UUIDs, parent_id /
    recurrence_source_id remappés, assignee_id / created_by → null."""
    items: list[Item] = []
    total = 0
    for entry in entries:
        raw = entry["items"]
        total += len(raw)
        if total > MAX_IMPORTED_ITEMS:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
        id_map = {
            str(raw.get("id")): new_id()
            for raw in raw
            if isinstance(raw.get("id"), str)
        }
        for raw in raw:
            parent = _parse_uuid(raw.get("parent_id"), "parent_id")
            if parent is not None and str(parent) not in id_map:
                # Parent hors de l'import (autre liste / inconnu) :
                # non conforme (l'export tapitask ne produit jamais ça).
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            source = _parse_uuid(
                raw.get("recurrence_source_id"), "recurrence_source_id"
            )
            if source is not None and str(source) not in id_map:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)
            items.append(
                Item(
                    id=id_map.get(str(raw.get("id"))) or new_id(),
                    list_id=None,  # posée après le flush de la liste
                    parent_id=id_map.get(str(parent)) if parent is not None else None,
                    label=raw["label"],
                    notes=_parse_optional_str(raw.get("notes"), "notes"),
                    assignee_id=None,
                    done=raw.get("done", False),
                    position=raw.get("position", 0),
                    recurrence=raw.get("recurrence", "none"),
                    due_date=_parse_due(raw.get("due_date")),
                    recurrence_source_id=(
                        id_map.get(str(source)) if source is not None else None
                    ),
                    created_by=None,
                    created_at=now,
                    updated_at=now,
                    deleted=raw.get("deleted", False),
                )
            )
    return items


def _parse_md(body: str, name: str | None) -> dict[str, Any]:
    """Markdown Obsidian → une entrée d'import (D-5). Titre = 1er H1,
    sinon ?name= (nom de fichier), sinon « Importée ». Les lignes non
    checkbox sont ignorées ; une checkbox sans libellé (y compris après
    suppression de l'échéance) est ignorée sans casser les items valides.
    Seule la convention propre ` (échéance YYYY-MM-DD)` est parsée."""
    title: str | None = None
    items: list[dict[str, Any]] = []
    for line in body.splitlines():
        if title is None:
            m = _H1.match(line)
            if m:
                title = m.group(1).strip()
                continue
        m = _ITEM_LABELS.match(line)
        if not m:
            continue
        done = m.group(1) in ("x", "X")
        label = m.group(2)
        due = None
        dm = _DUE.search(label)
        if dm:
            label = label[: dm.start()]
            try:
                due = datetime(
                    int(dm.group(1)),
                    int(dm.group(2)),
                    int(dm.group(3)),
                    tzinfo=timezone.utc,
                )
            except ValueError:
                due = None
        label = label.strip()
        if not label:
            continue
        items.append(
            {"label": label, "done": done, "due_date": due, "position": len(items)}
        )
    final_title = (title or name or "Importée").strip()[:200] or "Importée"
    return {"title": final_title, "items": items}


@router.post("/import", status_code=status.HTTP_201_CREATED)
async def import_data(
    request: Request,
    name: str | None = Query(default=None, max_length=200),
    principal: Principal = Depends(require_write),
    _rate_limited: Principal = Depends(rate_limit_principal),
    session: AsyncSession = Depends(get_session),
):
    if principal.list_scope is not None:
        # A scoped key is bound to its single list: no creation outside
        # it (Strix vuln-0002 — même garde que create_list).
        raise HTTPException(status.HTTP_403_FORBIDDEN, "API key scoped to another list")
    # Corps brut : JSON (enveloppe tapitask) ou markdown Obsidian — le
    # content-type est indifférent, la détection porte sur le contenu :
    # corps VALIDE JSON → import JSON ; sinon → markdown (couvre le
    # premier caractère « - [ » de la spec ET les fichiers avec H1).
    body = (await request.body()).decode("utf-8", "replace")
    try:
        data = json.loads(body)
        entries = _validate_json_lists(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        entries = [_parse_md(body, name)]
    if not entries or (len(entries) == 1 and not entries[0]["items"]):
        # Rien à importer (enveloppe JSON vide, ou corps non-JSON sans
        # aucune checkbox valide) : pas de liste créée, message uniforme.
        raise HTTPException(status.HTTP_400_BAD_REQUEST, INVALID_IMPORT)

    now = utcnow()
    created: list[tuple[Checklist, int]] = []
    for entry in entries:
        checklist = Checklist(
            owner_id=principal.user_id,
            title=entry["title"],
            color=entry.get("color"),
            folder=entry.get("folder"),
            created_at=now,
            updated_at=now,
        )
        session.add(checklist)
        await session.flush()  # id de la liste pour les items
        items = _build_items([entry], now)
        for item in items:
            item.list_id = checklist.id
            session.add(item)
        created.append((checklist, len(items)))
    await session.commit()
    for checklist, count in created:
        await record_change(
            session,
            list_id=checklist.id,
            checklist_id=checklist.id,
            kind="list.create",
            actor_id=principal.user_id,
        )
        await notify_list(
            checklist.id,
            {"kind": "list.create", "list_id": str(checklist.id), "count": count},
        )
    return {
        "lists": [{"id": str(c.id), "title": c.title, "items": n} for c, n in created]
    }
