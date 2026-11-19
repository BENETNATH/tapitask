"""MCP over HTTP/SSE — lets remote agents use Tapitask without SSH/stdio.

Wire format: the MCP 2024-11-05 HTTP+SSE transport. GET /mcp/sse opens one
session per connection and first sends an `endpoint` event naming the URL to
POST to (/mcp/messages?sessionId=...); each reply goes back on the stream of
the session that sent the request.
"""
from __future__ import annotations

import asyncio
import json
import uuid
from dataclasses import dataclass
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession

from .db import get_session
from .deps import Principal, accessible_list, get_principal
from .models import Role
from .schemas import ApiKeyIn

router = APIRouter(prefix="/mcp", tags=["mcp"])

TOOLS = [
    {
        "name": "list_lists",
        "description": "List the checklists the account can access.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_list",
        "description": "Get the items of a list. Set unchecked_only to focus on remaining work.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "list_id": {"type": "string"},
                "unchecked_only": {"type": "boolean", "default": False},
            },
            "required": ["list_id"],
        },
    },
    {
        "name": "get_summary",
        "description": "Compact text digest of a list (what remains to be done).",
        "inputSchema": {
            "type": "object",
            "properties": {"list_id": {"type": "string"}},
            "required": ["list_id"],
        },
    },
    {
        "name": "add_items",
        "description": "Add items to a list. One line in `text` = one item.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "list_id": {"type": "string"},
                "text": {"type": "string", "description": "One item per line"},
            },
            "required": ["list_id", "text"],
        },
    },
    {
        "name": "check_item",
        "description": "Check (or uncheck) an item by id.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "list_id": {"type": "string"},
                "item_id": {"type": "string"},
                "done": {"type": "boolean", "default": True},
            },
            "required": ["list_id", "item_id"],
        },
    },
]

TOOL_NAMES = {t["name"] for t in TOOLS}

REPLY_TIMEOUT = 5.0  # seconds to wait for room on a saturated stream


def _tool_result(text: str, is_error: bool = False) -> dict[str, Any]:
    """A tools/call result. A tool that ran but failed (access refused, item
    missing, bad id value) is reported here with isError, not as a JSON-RPC
    error: MCP keeps JSON-RPC errors for protocol failures, and clients show
    isError results to the model as an ordinary tool outcome."""
    result: dict[str, Any] = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


@dataclass
class _Session:
    user_id: str
    queue: asyncio.Queue


# One entry per open SSE connection (not per user): two agents on the same
# account each get their own replies, and one disconnecting never tears down
# the other's stream.
_sessions: dict[str, _Session] = {}


def _resolve_session(session_id: str | None, principal: Principal) -> _Session | None:
    user_id = str(principal.user_id)
    if session_id is not None:
        session = _sessions.get(session_id)
        # Another user's session id is answered exactly like an unknown one.
        return session if session is not None and session.user_id == user_id else None
    # Clients written before sessionId existed: newest stream of this user.
    for session in reversed(list(_sessions.values())):
        if session.user_id == user_id:
            return session
    return None


@router.get("/sse")
async def sse(request: Request, principal: Principal = Depends(get_principal)):
    session_id = uuid.uuid4().hex
    q: asyncio.Queue = asyncio.Queue(maxsize=100)
    _sessions[session_id] = _Session(user_id=str(principal.user_id), queue=q)
    endpoint = f"{request.scope.get('root_path', '')}/mcp/messages?sessionId={session_id}"

    async def event_stream():
        try:
            # MCP 2024-11-05: the first event tells the client where to POST.
            yield f"event: endpoint\ndata: {endpoint}\n\n"
            # Kept for clients written against the original bridge.
            yield f"event: session\ndata: {json.dumps({'sessionId': session_id})}\n\n"
            while True:
                if await request.is_disconnected():
                    break
                try:
                    message = await asyncio.wait_for(q.get(), timeout=15)
                    yield f"event: message\ndata: {json.dumps(message)}\n\n"
                except asyncio.TimeoutError:
                    yield ": ping\n\n"
        finally:
            _sessions.pop(session_id, None)

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@router.post("/messages")
async def messages(
    payload: dict[str, Any],
    sessionId: str | None = None,  # noqa: N803 — name fixed by the MCP spec
    principal: Principal = Depends(get_principal),
):
    """Handle one JSON-RPC message; the reply goes out on the session's SSE
    stream, tagged with the request's id.

    Delivery is checked BEFORE anything runs: with no open stream (or a
    saturated one) the POST fails immediately, so the client gets an error
    at once instead of a tool side effect plus a reply nobody receives."""
    session = _resolve_session(sessionId, principal)
    if session is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND,
                            "No open MCP session: connect to GET /mcp/sse first")
    if session.queue.full():
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                            "MCP session backlog full: read the SSE stream")

    # JSON-RPC notification (no "id" member): never answered — a reply would
    # carry id null and could not be correlated with anything.
    is_notification = "id" not in payload
    message: dict[str, Any] = {"jsonrpc": "2.0", "id": payload.get("id")}
    method = payload.get("method")
    if method == "initialize":
        message["result"] = {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "tapitask-mcp", "version": "0.1.0"},
        }
    elif method == "tools/list":
        message["result"] = {"tools": TOOLS}
    elif method == "tools/call":
        # Protocol failures (malformed params, unknown tool, missing argument,
        # unexpected server fault) are JSON-RPC errors; a known tool that runs
        # and fails returns an isError result.
        params = payload.get("params")
        arguments = params.get("arguments") if isinstance(params, dict) else None
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            message["error"] = {"code": -32602,
                                "message": "Invalid params: 'name' is required"}
        elif params["name"] not in TOOL_NAMES:
            message["error"] = {"code": -32602,
                                "message": f"Unknown tool: {params['name']}"}
        elif arguments is not None and not isinstance(arguments, dict):
            message["error"] = {"code": -32602,
                                "message": "Invalid params: 'arguments' must be an object"}
        else:
            try:
                result = await _call_tool(principal, params["name"], arguments or {})
                message["result"] = _tool_result(result)
            except KeyError as e:
                message["error"] = {"code": -32602,
                                    "message": f"Invalid params: missing {e}"}
            except HTTPException as e:
                message["result"] = _tool_result(
                    f"HTTP {e.status_code}: {e.detail}", is_error=True)
            except ValueError as e:
                message["result"] = _tool_result(str(e), is_error=True)
            except Exception as e:
                message["error"] = {"code": -32603, "message": str(e)}
    elif is_notification:
        return {"status": "ok"}  # notifications/initialized, cancelled, ...
    else:
        message["error"] = {"code": -32601, "message": f"Unknown method {method}"}

    if is_notification:
        return {"status": "ok"}
    try:
        await asyncio.wait_for(session.queue.put(message), timeout=REPLY_TIMEOUT)
    except asyncio.TimeoutError:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                            "MCP session backlog full: reply not delivered")
    return {"status": "ok"}


async def _call_tool(principal: Principal, name: str, args: dict[str, Any]) -> str:
    from uuid import UUID

    from .db import SessionLocal
    from .models import Checklist, Item, ListMember
    from sqlalchemy import select

    def _uuid(value: str) -> UUID:
        return UUID(value)

    async with SessionLocal() as session:
        if name == "list_lists":
            # list_lists is already scoped to owned + shared lists; no per-list
            # gate needed.
            owned = await session.execute(
                select(Checklist).where(
                    Checklist.owner_id == principal.user_id, Checklist.deleted.is_(False))
            )
            rows = [
                {"id": str(c.id), "title": c.title, "role": "owner"}
                for c in owned.scalars()
            ]
            shared = await session.execute(
                select(ListMember, Checklist)
                .join(Checklist, Checklist.id == ListMember.list_id)
                .where(ListMember.user_id == principal.user_id, Checklist.deleted.is_(False))
            )
            rows += [
                {"id": str(c.id), "title": c.title, "role": m.role.value}
                for m, c in shared.all()
            ]
            return json.dumps(rows)
        if name == "get_summary":
            # A principal may only summarise a list it can access (owner,
            # member, or within an API key's list_scope).
            await accessible_list(_uuid(args["list_id"]), principal, session)
            result = await session.execute(
                select(Checklist).where(Checklist.id == _uuid(args["list_id"]))
            )
            checklist = result.scalar_one_or_none()
            items = await session.execute(
                select(Item).where(
                    Item.list_id == _uuid(args["list_id"]),
                    Item.deleted.is_(False), Item.done.is_(False),
                ).order_by(Item.position)
            )
            labels = [i.label for i in items.scalars()]
            title = checklist.title if checklist else "?"
            return f"{title} — {len(labels)} à faire : " + ", ".join(labels)
        if name == "get_list":
            await accessible_list(_uuid(args["list_id"]), principal, session)
            flag = args.get("unchecked_only", False)
            query = select(Item).where(
                Item.list_id == _uuid(args["list_id"]), Item.deleted.is_(False)
            ).order_by(Item.position)
            if flag:
                query = query.where(Item.done.is_(False))
            items = await session.execute(query)
            return json.dumps(
                [
                    {"id": str(i.id), "label": i.label, "done": i.done,
                     "recurrence": i.recurrence}
                    for i in items.scalars()
                ]
            )
        if name == "add_items":
            # Write tool: editor role on the target list, and read-only
            # principals (scoped API keys) must be refused.
            if principal.read_only:
                raise HTTPException(status.HTTP_403_FORBIDDEN, "Read-only credentials")
            await accessible_list(_uuid(args["list_id"]), principal, session, min_role=Role.editor)
            from .routers.lists import _add_single
            from .events import record_change, notify_list
            lines = [l.strip() for l in args["text"].splitlines() if l.strip()]
            created = []
            for line in lines[:500]:
                item = await _add_single(session, _uuid(args["list_id"]), line, principal.user_id)
                created.append(str(item.id))
            return json.dumps({"created": created})
        if name == "check_item":
            result = await session.execute(
                select(Item).where(
                    Item.id == _uuid(args["item_id"]), Item.deleted.is_(False))
            )
            item = result.scalar_one_or_none()
            if item is None:
                raise ValueError("item not found")
            # Write tool: editor access to the item's REAL list, and read-only
            # principals refused (authorizes the list the item belongs to, not
            # a caller-supplied list_id).
            if principal.read_only:
                raise HTTPException(status.HTTP_403_FORBIDDEN, "Read-only credentials")
            await accessible_list(item.list_id, principal, session, min_role=Role.editor)
            done = args.get("done", True)
            if not isinstance(done, bool):
                raise ValueError("'done' must be a boolean")
            from .events import notify_list, record_change
            from .models import utcnow
            from .routers.lists import _spawn_next
            # Same semantics as REST PATCH and sync: the next occurrence of a
            # recurring item is spawned on the not-done -> done transition,
            # and _spawn_next is idempotent per source item.
            newly_done = done and not item.done
            item.done = done
            item.updated_at = utcnow()
            await session.commit()
            spawned = None
            if newly_done and item.recurrence and item.recurrence != "none":
                spawned = await _spawn_next(session, item, principal.user_id)
            await record_change(session, list_id=item.list_id, item_id=item.id,
                                kind="item.upsert")
            await notify_list(item.list_id, {"kind": "item.upsert",
                                             "list_id": str(item.list_id),
                                             "id": str(item.id)})
            out = {"id": str(item.id), "done": item.done}
            if spawned is not None:
                out["next_occurrence"] = {
                    "id": str(spawned.id),
                    "due_date": spawned.due_date.isoformat() if spawned.due_date else None,
                }
            return json.dumps(out)
    raise ValueError(f"Unknown tool: {name}")
