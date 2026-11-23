from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from .config import settings
from .db import Base, SessionLocal, engine
from .models import User
from .mcp_http import router as mcp_router
from .routers import admin, apikeys, auth, lists, sharing, sync
from .security import hash_password
from .ws import router as ws_router

def read_server_version(path: Path | None = None) -> str:
    """Lecture de server/VERSION — "unknown" si absent/corrompu/vide
    (l'endpoint /version ne doit jamais répondre 500)."""
    p = path if path is not None else Path(__file__).resolve().parent.parent / "VERSION"
    try:
        v = p.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return "unknown"
    return v or "unknown"


# Une seule lecture à l'import : /version renvoie cette valeur, pas un
# re-lecture du fichier à chaque request.
SERVER_VERSION = read_server_version()


@asynccontextmanager
async def _lifespan(app: FastAPI):
    await _startup()
    yield


app = FastAPI(
    title="Tapitask API",
    version="0.1.0",
    description="Offline-first checklist sync server. OpenAPI spec: /openapi.json",
    lifespan=_lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)
app.add_middleware(GZipMiddleware, minimum_size=1024)


@app.exception_handler(RequestValidationError)
async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
    # 400 (not 422): clean rejection of malformed bodies — e.g. a U+0000 in
    # a user text field must never surface as a bare 500 (Strix hardening).
    return JSONResponse(status_code=400, content={"detail": jsonable_encoder(exc.errors())})

app.include_router(auth.router)
app.include_router(admin.router)
app.include_router(admin.audit_router)
app.include_router(lists.router)
app.include_router(sharing.router)
app.include_router(sync.router)
app.include_router(apikeys.router)
app.include_router(ws_router)
app.include_router(mcp_router)


@app.get("/health", include_in_schema=False)
async def health():
    return {"status": "ok"}


@app.get("/version", include_in_schema=False)
async def version():
    # Public (sans auth) : les clients en font l'appel au démarrage, avant
    # même d'avoir un token, pour décider si le serveur doit être mis à jour.
    return {"version": SERVER_VERSION}


async def ensure_admin_user() -> bool:
    """Create the default admin account from ADMIN_EMAIL/ADMIN_PASSWORD if set
    and not already present. Returns True if the account was created."""
    if not settings.ADMIN_EMAIL or not settings.ADMIN_PASSWORD:
        return False
    async with SessionLocal() as session:
        result = await session.execute(
            select(User).where(User.email == settings.ADMIN_EMAIL.lower())
        )
        if result.scalar_one_or_none() is not None:
            return False
        session.add(
            User(
                email=settings.ADMIN_EMAIL.lower(),
                password_hash=hash_password(settings.ADMIN_PASSWORD),
                is_admin=True,
            )
        )
        try:
            await session.commit()
            return True
        except IntegrityError:
            await session.rollback()
            return False


MIGRATIONS = [
    # (table, column, sqlite DDL, postgres DDL)
    ("users", "is_admin", "BOOLEAN NOT NULL DEFAULT 0", "BOOLEAN NOT NULL DEFAULT FALSE"),
    ("users", "is_active", "BOOLEAN NOT NULL DEFAULT 1", "BOOLEAN NOT NULL DEFAULT TRUE"),
    ("users", "is_email_verified", "BOOLEAN NOT NULL DEFAULT 1", "BOOLEAN NOT NULL DEFAULT TRUE"),
    ("users", "email_token", "VARCHAR(64)", "VARCHAR(64)"),
    ("users", "pending_email", "VARCHAR(320)", "VARCHAR(320)"),
    ("users", "totp_secret", "VARCHAR(64)", "VARCHAR(64)"),
    ("api_keys", "list_scope", "VARCHAR(36)", "UUID"),
    ("items", "parent_id", "VARCHAR(36)", "UUID"),
    ("items", "recurrence", "VARCHAR(10) NOT NULL DEFAULT 'none'", "VARCHAR(10) NOT NULL DEFAULT 'none'"),
    ("items", "due_date", "TIMESTAMP", "TIMESTAMP"),
    ("items", "due_day", "DATE", "DATE"),
    ("items", "completed_at", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE"),
    ("lists", "color", "VARCHAR(16)", "VARCHAR(16)"),
    ("lists", "folder", "VARCHAR(100)", "VARCHAR(100)"),
    ("users", "settings", "TEXT", "TEXT"),
    ("items", "notes", "TEXT", "TEXT"),
    ("items", "assignee_id", "VARCHAR(36)", "UUID"),
    ("items", "recurrence_source_id", "VARCHAR(36)", "UUID"),
]


def _is_postgres() -> bool:
    return engine.dialect.name == "postgresql"


async def _ensure_columns() -> None:
    """Lightweight migration: add missing columns to existing tables.
    Each statement runs in its own transaction — one failure never aborts
    the rest (critical with concurrent workers)."""
    from sqlalchemy import text

    for table, column, sqlite_ddl, pg_ddl in MIGRATIONS:
        ddl = pg_ddl if _is_postgres() else sqlite_ddl
        try:
            async with engine.begin() as conn:
                if _is_postgres():
                    await conn.execute(text(
                        f"ALTER TABLE {table} ADD COLUMN IF NOT EXISTS {column} {ddl}"))
                else:
                    await conn.execute(text(
                        f"ALTER TABLE {table} ADD COLUMN {column} {ddl}"))
        except Exception:
            pass  # column already exists (sqlite has no IF NOT EXISTS)


async def _create_schema() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    await _ensure_columns()
    await _ensure_indexes()


async def _init_schema() -> None:
    """create_all + migrations, serialized across workers.

    With multiple uvicorn workers, every worker runs the startup hook
    concurrently on a fresh database — two create_all racing on the same
    ENUM type crash one worker. A Postgres advisory lock makes exactly one
    worker initialize the schema; the others wait and then find everything
    in place (create_all is checkfirst). The lock is session-scoped and
    released on commit: it is therefore HELD on its own connection for the
    whole init — no commit between lock and unlock — so the serialization
    actually covers create_all + migrations. On SQLite (tests), no lock is
    needed."""
    from sqlalchemy import text

    if _is_postgres():
        async with engine.connect() as conn:
            await conn.execute(text("SELECT pg_advisory_lock(918273645)"))
            try:
                await _create_schema()
            finally:
                await conn.execute(text("SELECT pg_advisory_unlock(918273645)"))
                await conn.commit()
    else:
        await _create_schema()


async def _ensure_indexes() -> None:
    """Indexes backing the delta-sync filter (updated_at) — best-effort,
    idempotent (CREATE INDEX IF NOT EXISTS works on both dialects)."""
    from sqlalchemy import text

    for ddl in (
        "CREATE INDEX IF NOT EXISTS ix_items_updated_at ON items (updated_at)",
        "CREATE INDEX IF NOT EXISTS ix_lists_updated_at ON lists (updated_at)",
        # unique (list_id, user_id) on pre-constraint databases: repeated
        # joins must never create a duplicate membership row (Strix
        # hardening item); backstops the INSERT ... ON CONFLICT upserts.
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_list_members_list_user "
        "ON list_members (list_id, user_id)",
        # Recurrence idempotency: at most one occurrence spawned per source.
        "CREATE UNIQUE INDEX IF NOT EXISTS ux_items_recurrence_source "
        "ON items (recurrence_source_id)",
    ):
        try:
            async with engine.begin() as conn:
                await conn.execute(text(ddl))
        except Exception:
            pass


async def _startup() -> None:
    # The WebSocket hub is in-process: more than one uvicorn worker breaks
    # realtime silently (clients connect to a worker that never publishes
    # their events). Fail loudly rather than degrading quietly.
    workers = os.environ.get("WEB_CONCURRENCY") or os.environ.get("UVICORN_WORKERS")
    if workers and workers not in ("1", ""):
        import logging

        logging.getLogger("tapitask").error(
            "WEB_CONCURRENCY=%s : le hub WebSocket est in-process — "
            "le temps réel ne fonctionnera PAS avec plusieurs workers. "
            "Retirez --workers ou ajoutez Redis pub/sub dans app/events.py.",
            workers,
        )
    if os.environ.get("AUTO_CREATE_TABLES", "1") == "1":
        await _init_schema()
    await ensure_admin_user()
