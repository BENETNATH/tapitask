from __future__ import annotations

import asyncio
import json
from uuid import UUID

from fastapi import APIRouter, WebSocket
from sqlalchemy import select

from .config import settings
from .db import SessionLocal
from .events import hub
from .models import User
from .security import decode_token

router = APIRouter()

# The access token travels in the FIRST MESSAGE after accept(), not in the
# query string — query strings end up in reverse-proxy access logs.


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    try:
        first = await asyncio.wait_for(websocket.receive_text(), timeout=10)
        data = json.loads(first)
        token = data.get("token") if isinstance(data, dict) else None
        if not token:
            raise ValueError("missing token")
        payload = decode_token(token, "access")
        user_id = UUID(payload["sub"])
    except Exception:
        await websocket.close(code=4401)
        return

    async def is_active() -> bool:
        # Le JWT reste valide après une désactivation admin : l'état du
        # compte est re-vérifié côté serveur (audit run-2).
        async with SessionLocal() as session:
            user = await session.get(User, user_id)
        return user is not None and user.is_active

    if not await is_active():
        await websocket.close(code=4401)
        return
    queue = hub.subscribe(user_id)
    try:
        while True:
            try:
                message = await asyncio.wait_for(
                    queue.get(), timeout=settings.WS_PING_INTERVAL)
                await websocket.send_text(json.dumps(message))
            except asyncio.TimeoutError:
                if not await is_active():
                    await websocket.close(code=4401)
                    return
                await websocket.send_text(json.dumps({"kind": "ping"}))
    except Exception:
        pass
    finally:
        hub.unsubscribe(user_id, queue)
