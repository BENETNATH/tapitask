"""Spec §B.1 — endpoint GET /version public + fichier server/VERSION.

R-B1 : 200 {"version": <contenu du fichier>} sans token ; une route
       protégée reste 401 (pas de percée d'auth).
R-B2 : fichier absent/corrompu → 200 {"version": "unknown"} (pas de 500).
"""

from __future__ import annotations

from pathlib import Path

import pytest
from app.main import app
from httpx import ASGITransport, AsyncClient

from app import main

REPO_ROOT = Path(__file__).resolve().parents[2]
VERSION_FILE = REPO_ROOT / "server" / "VERSION"


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.mark.asyncio
async def test_version_public_no_auth(client):
    # R-B1 : public, sans token.
    r = await client.get("/version")
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"version"}
    # La valeur = le contenu du fichier de VERSION du repo (lecture unique
    # à l'import — vérifiée ici contre le fichier réel, pas un littéral).
    assert body["version"] == VERSION_FILE.read_text(encoding="utf-8").strip()
    assert body["version"] == main.SERVER_VERSION


@pytest.mark.asyncio
async def test_protected_route_still_401(client):
    # R-B1 : l'endpoint public n'a pas percé l'auth globale.
    r = await client.get("/lists")
    assert r.status_code == 401


def test_dockerfile_ships_version_file():
    # L'image doit embarquer VERSION, sinon /version répond "unknown"
    # (le Dockerfile ne copie que app/ — un COPY manquant est silencieux).
    dockerfile = REPO_ROOT / "server" / "Dockerfile"
    assert "COPY VERSION ." in dockerfile.read_text(encoding="utf-8")


def test_version_read_missing_file(tmp_path):
    # R-B2 : fichier absent → "unknown" (pas d'exception, donc pas de 500).
    assert main.read_server_version(tmp_path / "nope" / "VERSION") == "unknown"


def test_version_read_corrupt_file(tmp_path):
    # R-B2 : fichier corrompu (non UTF-8) → "unknown".
    bad = tmp_path / "VERSION"
    bad.write_bytes(b"\xff\xfe\x00garbage")
    assert main.read_server_version(bad) == "unknown"


def test_version_read_empty_file(tmp_path):
    empty = tmp_path / "VERSION"
    empty.write_text("", encoding="utf-8")
    assert main.read_server_version(empty) == "unknown"


def test_version_read_strips_content(tmp_path):
    good = tmp_path / "VERSION"
    good.write_text("0.3.0\n", encoding="utf-8")
    assert main.read_server_version(good) == "0.3.0"
