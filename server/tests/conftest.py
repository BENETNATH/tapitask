from __future__ import annotations

import os

os.environ.setdefault("TEST_ENV", "1")
os.environ.setdefault("JWT_SECRET", "test-0123456789abcdef0123456789abcdef")
os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///:memory:")
# The webhook SSRF guard blocks loopback/private/metadata hosts by default.
# Tests that deliver to a real local listener (127.0.0.1) opt in explicitly.
os.environ.setdefault("WEBHOOK_ALLOWED_HOSTS", "127.0.0.1")

import pytest

from app.db import Base, engine
from app.routers import auth as auth_router
from app.routers import sharing as sharing_router


@pytest.fixture(autouse=True)
async def setup_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    auth_router._register_limiter.hits.clear()
    auth_router._login_limiter.hits.clear()
    auth_router._change_email_limiter.hits.clear()
    auth_router._verify_email_limiter.hits.clear()
    auth_router._failed_logins.clear()
    # 3.4 (prod3) : les tâches mail fire-and-forget de la boucle du test
    # précédent (pytest-asyncio : une boucle par test) ne s'exécuteront
    # jamais — les purger, sinon un drain asyncio.gather les attendrait
    # pour toujours.
    sharing_router._in_flight_emails.clear()
    yield
    # Chaque test a sa boucle asyncio (pytest-asyncio, scope function) mais
    # StaticPool partage UNE connexion aiosqlite entre les tests : le lock de
    # l'adaptateur SQLAlchemy se bind à la boucle du PREMIER test qui le
    # contende, et un test ultérieur à accès concurrent lèverait
    # "bound to a different event loop". Dispose force une connexion (et son
    # lock) fraîche par test — la base in-memory est recréée par create_all.
    await engine.dispose()
