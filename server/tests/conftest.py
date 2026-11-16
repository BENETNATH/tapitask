from __future__ import annotations

import os

os.environ.setdefault("JWT_SECRET", "test-secret")
os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///:memory:")
# The webhook SSRF guard blocks loopback/private/metadata hosts by default.
# Tests that deliver to a real local listener (127.0.0.1) opt in explicitly.
os.environ.setdefault("WEBHOOK_ALLOWED_HOSTS", "127.0.0.1")

import pytest

from app.db import Base, engine
from app.routers import auth as auth_router


@pytest.fixture(autouse=True)
async def setup_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    auth_router._register_limiter.hits.clear()
    auth_router._login_limiter.hits.clear()
    auth_router._failed_logins.clear()
    yield
