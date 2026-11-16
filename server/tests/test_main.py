from __future__ import annotations

import pytest

from app import main


class FakeConn:
    def __init__(self, log):
        self.log = log

    async def execute(self, stmt):
        self.log.append(getattr(stmt, "text", str(stmt)))

    async def commit(self):
        self.log.append("commit")

    async def run_sync(self, fn):
        self.log.append("create_all")  # sans appeler fn (pas de vrai DB)


class FakeCtx:
    def __init__(self, conn):
        self.conn = conn

    async def __aenter__(self):
        return self.conn

    async def __aexit__(self, *exc):
        return False


class FakeEngine:
    dialect = type("D", (), {"name": "postgresql"})

    def __init__(self):
        self.log = []

    def connect(self):
        return FakeCtx(FakeConn(self.log))

    def begin(self):
        return FakeCtx(FakeConn(self.log))


@pytest.mark.asyncio
async def test_advisory_lock_held_during_init(monkeypatch):
    """Le lock advisory est session-scoped : un commit entre lock et unlock le
    libérait AVANT create_all — la serialisation inter-workers n'existait pas
    (audit run-2, main._init_schema)."""
    engine = FakeEngine()
    monkeypatch.setattr(main, "engine", engine)

    async def record(name):
        engine.log.append(name)

    monkeypatch.setattr(main, "_ensure_columns", lambda: record("ensure_columns"))
    monkeypatch.setattr(main, "_ensure_indexes", lambda: record("ensure_indexes"))

    await main._init_schema()

    log = engine.log
    lock = log.index("SELECT pg_advisory_lock(918273645)")
    create = log.index("create_all")
    unlock = log.index("SELECT pg_advisory_unlock(918273645)")
    assert lock < create < unlock
    assert "commit" not in log[lock:unlock], log
