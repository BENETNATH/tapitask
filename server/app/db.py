from __future__ import annotations

from collections.abc import AsyncIterator

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy.pool import StaticPool

from .config import settings


class Base(DeclarativeBase):
    pass


def create_sqlite_engine(url: str):
    """Engine SQLite.

    `:memory:` (tests) : StaticPool — une seule connexion partagée,
    comportement inchangé.

    Fichier (D-3, spec 2026-11-25) : pool par défaut (un pool statique sur
    fichier serait une régression en concurrence) + PRAGMA au connect :
    journal_mode=WAL (lecteurs non bloquants) et busy_timeout=10 s
    (attente d'écrivain plutôt que SQLITE_BUSY).
    """
    if ":memory:" in url:
        return create_async_engine(
            url,
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
    engine = create_async_engine(url, connect_args={"check_same_thread": False})

    @event.listens_for(engine.sync_engine, "connect")
    def _sqlite_pragmas(dbapi_connection, connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA journal_mode=WAL")
        cursor.execute("PRAGMA busy_timeout=10000")
        cursor.close()

    return engine


if settings.DATABASE_URL.startswith("sqlite"):
    engine = create_sqlite_engine(settings.DATABASE_URL)
else:
    engine = create_async_engine(settings.DATABASE_URL, pool_pre_ping=True)

SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
