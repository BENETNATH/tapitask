from __future__ import annotations

import asyncio
import json
from uuid import UUID

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from sqlalchemy import select

from .db import SessionLocal
from .events import hub
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
    queue = hub.subscribe(user_id)
    try:
        while True:
            try:
                message = await asyncio.wait_for(queue.get(), timeout=30)
                await websocket.send_text(json.dumps(message))
            except asyncio.TimeoutError:
                await websocket.send_text(json.dumps({"kind": "ping"}))
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        hub.unsubscribe(user_id, queue)
