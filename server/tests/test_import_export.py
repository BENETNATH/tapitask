"""F2/F3/F4 (spec 2026-11-25) : export/import JSON, Obsidian markdown, CSV.

Contrat verrouillé ici :
- JSON export = enveloppe {"tapitask": 1, "exported_at": ..., "lists": [...]}
  1:1 avec les modèles (tous les champs d'Item, y compris deleted).
- Import = TOUJOURS de nouvelles listes à nouveaux UUIDs (jamais merge) ;
  corps non conforme → 400 message uniforme ; assignee_id → null ;
  parent_id / recurrence_source_id remappés à l'intérieur de l'import.
- md : `# <titre>` + `- [ ]`/`- [x]` + ` (échéance YYYY-MM-DD)` (date UTC).
- CSV : header `liste;titre;fait;echeance;ordre`, échappement ;/"",
  Content-Disposition propre.
"""

from __future__ import annotations

import os

os.environ.setdefault("TEST_ENV", "1")
os.environ.setdefault("JWT_SECRET", "test-0123456789abcdef0123456789abcdef")
os.environ.setdefault("DATABASE_URL", "sqlite+aiosqlite:///:memory:")

import pytest
from app.main import app
from httpx import ASGITransport, AsyncClient

INVALID_IMPORT = "Invalid import format"

ITEM_FIELDS = {
    "id",
    "list_id",
    "parent_id",
    "label",
    "notes",
    "assignee_id",
    "done",
    "position",
    "recurrence",
    "due_date",
    "recurrence_source_id",
    "created_by",
    "created_at",
    "updated_at",
    "deleted",
}


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client: AsyncClient, email: str) -> dict:
    r = await client.post(
        "/auth/register", json={"email": email, "password": "LongPassw0rd!x"}
    )
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


async def make_list(client: AsyncClient, h: dict, title: str, **extra) -> str:
    r = await client.post("/lists", json={"title": title, **extra}, headers=h)
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def make_item(
    client: AsyncClient, h: dict, list_id: str, label: str, **extra
) -> dict:
    r = await client.post(
        f"/lists/{list_id}/items", json={"label": label, **extra}, headers=h
    )
    assert r.status_code == 201, r.text
    return r.json()[0]


# ---- F2 : export JSON -----------------------------------------------------


@pytest.mark.asyncio
async def test_export_json_single_list_full_fields(client):
    h = auth_headers(await register(client, "exp@example.com"))
    list_id = await make_list(client, h, "Courses", color="#ff0000", folder="achats")

    i1 = await make_item(
        client,
        h,
        list_id,
        "lait",
        recurrence="daily",
        due_date="2026-12-01T10:00:00Z",
        notes="gras",
    )
    await make_item(client, h, list_id, "sous-item", parent_id=i1["id"])
    # Compléter un item récurrent fait naître une occurrence (récurrence
    # source) — l'export doit la porter avec recurrence_source_id.
    r = await client.patch(
        f"/lists/{list_id}/items/{i1['id']}", json={"done": True}, headers=h
    )
    assert r.status_code == 200
    spawned = [i for i in r.json() if i["id"] != i1["id"]]
    assert len(spawned) == 1

    r = await client.get(f"/lists/{list_id}/export.json", headers=h)
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["tapitask"] == 1
    assert data["exported_at"]
    assert len(data["lists"]) == 1
    entry = data["lists"][0]
    assert entry["id"] == list_id
    assert entry["title"] == "Courses"
    assert entry["color"] == "#ff0000"
    assert entry["folder"] == "achats"
    items = entry["items"]
    assert len(items) == 3, "items complets : parent, sous-item, occurrence"
    for i in items:
        assert set(i.keys()) == ITEM_FIELDS, "1:1 avec le modèle Item"
    by_label = {i["label"]: i for i in items if i["label"] != "lait"}
    lait = [i for i in items if i["label"] == "lait"]
    assert len(lait) == 2, "le parent + son occurrence (même libellé)"
    source = next(i for i in lait if i["id"] == i1["id"])
    occ = next(i for i in lait if i["id"] != i1["id"])
    assert source["done"] is True
    assert source["recurrence"] == "daily"
    assert source["notes"] == "gras"
    assert source["due_date"].startswith("2026-12-01T10:00")
    assert by_label["sous-item"]["parent_id"] == i1["id"]
    assert occ["recurrence_source_id"] == i1["id"], (
        "l'occurrence porte l'id de son source"
    )
    assert occ["recurrence"] == "daily"
    assert occ["done"] is False


@pytest.mark.asyncio
async def test_export_json_scope_all_only_accessible_lists(client):
    ta = auth_headers(await register(client, "a@example.com"))
    tb = auth_headers(await register(client, "b@example.com"))
    await make_list(client, ta, "Liste A")  # possédée par A
    await make_list(client, tb, "Liste B")  # possédée par B, A n'y a pas accès
    l3 = await make_list(client, tb, "Liste C")  # B partage avec A
    r = await client.post(
        f"/lists/{l3}/members",
        json={"email": "a@example.com", "role": "editor"},
        headers=tb,
    )
    assert r.status_code == 201, r.text

    r = await client.get("/export.json?scope=all", headers=ta)
    assert r.status_code == 200, r.text
    titles = {e["title"] for e in r.json()["lists"]}
    assert titles == {"Liste A", "Liste C"}, (
        "l'exporteur ne voit que ses accès (possédées + memberships)"
    )

    r = await client.get("/export.json?scope=all", headers=tb)
    titles = {e["title"] for e in r.json()["lists"]}
    assert titles == {"Liste B", "Liste C"}


@pytest.mark.asyncio
async def test_export_foreign_list_denied(client):
    ha = auth_headers(await register(client, "own@example.com"))
    hb = auth_headers(await register(client, "other@example.com"))
    list_id = await make_list(client, ha, "Privée")
    for path in (
        f"/lists/{list_id}/export.json",
        f"/lists/{list_id}/export.md",
        f"/lists/{list_id}/export.csv",
    ):
        r = await client.get(path, headers=hb)
        assert r.status_code in (403, 404), (path, r.status_code)


@pytest.mark.asyncio
async def test_import_roundtrip_new_uuids(client):
    ha = auth_headers(await register(client, "src@example.com"))
    hb = auth_headers(await register(client, "dst@example.com"))
    list_id = await make_list(client, ha, "Roundtrip", color="#00ff00")
    parent = await make_item(client, ha, list_id, "parent")
    await make_item(client, ha, list_id, "enfant", parent_id=parent["id"])
    await make_item(
        client,
        ha,
        list_id,
        "récurrent",
        recurrence="weekly",
        due_date="2026-12-01T10:00:00Z",
    )

    r = await client.get(f"/lists/{list_id}/export.json", headers=ha)
    assert r.status_code == 200
    body = r.json()

    r = await client.post("/import", json=body, headers=hb)
    assert r.status_code == 201, r.text
    created = r.json()["lists"]
    assert len(created) == 1
    assert created[0]["title"] == "Roundtrip"
    assert created[0]["items"] == 3
    new_id = created[0]["id"]
    assert new_id != list_id, "l'import crée TOUJOURS de nouvelles listes"

    old_ids = {list_id} | {i["id"] for lst in body["lists"] for i in lst["items"]}
    r = await client.get(f"/lists/{new_id}/items", headers=hb)
    assert r.status_code == 200
    new_ids = {i["id"] for i in r.json()}
    assert new_ids.isdisjoint(old_ids), "nouveaux UUIDs partout à l'import"
    items = {i["label"]: i for i in r.json()}
    assert set(items) == {"parent", "enfant", "récurrent"}
    assert items["enfant"]["parent_id"] == items["parent"]["id"], (
        "parent_id remappé à l'intérieur de l'import"
    )
    assert items["récurrent"]["recurrence"] == "weekly"
    assert items["récurrent"]["due_date"].startswith("2026-12-01T10:00")
    for i in items.values():
        assert i["assignee_id"] is None, (
            "assignee_id (utilisateur d'un autre compte) → null à l'import"
        )
    # L'ancienne liste (compte A) est intacte — jamais d'écrasement.
    r = await client.get(f"/lists/{list_id}/items", headers=ha)
    assert {i["label"] for i in r.json()} == {"parent", "enfant", "récurrent"}


@pytest.mark.asyncio
async def test_import_invalid_body_400_uniform(client):
    h = auth_headers(await register(client, "imp@example.com"))
    for body in (
        "c'est pas du json",
        '{"lists": "pas une liste"}',
        '{"lists": [{"title": "ok", "items": [{"pas_de_label": true}]}]}',
        '{"lists": [{"title": "", "items": []}]}',
        '[{"title": "x"}]',
    ):
        r = await client.post(
            "/import", content=body, headers={**h, "Content-Type": "text/plain"}
        )
        assert r.status_code == 400, (body, r.status_code)
        assert r.json()["detail"] == INVALID_IMPORT, "message uniforme"


@pytest.mark.asyncio
async def test_import_json_duplicate_item_ids_400(client):
    """Deux items partageant le même id source → collision des nouveaux
    UUIDs (remappage 1:1) : corps non-conforme → 400 uniforme, pas de
    500 IntegrityError."""
    h = auth_headers(await register(client, "dup@example.com"))
    body = {
        "tapitask": 1,
        "exported_at": "2026-11-25T00:00:00Z",
        "lists": [
            {
                "id": "l1",
                "title": "L",
                "items": [
                    {"id": "i1", "label": "a", "done": False, "position": 0},
                    {"id": "i1", "label": "b", "done": False, "position": 1},
                ],
            }
        ],
    }
    r = await client.post("/import", json=body, headers=h)
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == INVALID_IMPORT


@pytest.mark.asyncio
async def test_import_cumulative_item_cap_400(client):
    """SEC-F2 : le plafond MAX_IMPORTED_ITEMS porte sur l'ENSEMBLE de la
    requête, pas seulement par liste — sans ça MAX_IMPORTED_LISTS ×
    MAX_IMPORTED_ITEMS items passeraient en une seule transaction."""
    from app.routers.import_export import MAX_IMPORTED_ITEMS

    h = auth_headers(await register(client, "impcum@example.com"))
    per_list = MAX_IMPORTED_ITEMS // 2 + 10  # chaque liste < max en solo
    body = {
        "lists": [
            {
                "title": f"L{i}",
                "items": [
                    {"label": f"item-{j}", "done": False, "position": j}
                    for j in range(per_list)
                ],
            }
            for i in range(3)  # total = 3 × per_list > MAX_IMPORTED_ITEMS
        ]
    }
    assert sum(len(e["items"]) for e in body["lists"]) > MAX_IMPORTED_ITEMS
    r = await client.post("/import", json=body, headers=h)
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == INVALID_IMPORT
    lists = (await client.get("/lists", headers=h)).json()
    assert lists == [], "aucune liste créée"


@pytest.mark.asyncio
async def test_import_requires_auth(client):
    r = await client.post("/import", json={"lists": []})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_import_scoped_key_refused_no_lists_created(client):
    """SEC-F1 : une clé API scopée à une liste ne peut PAS créer de liste
    via /import (Strix vuln-0002 — même garde que create_list)."""
    h = auth_headers(await register(client, "impscoped@example.com"))
    list_id = await make_list(client, h, "Scoped")
    r = await client.post(
        "/api-keys", json={"name": "scoped", "list_scope": list_id}, headers=h
    )
    assert r.status_code == 201, r.text
    kh = {"Authorization": f"Bearer {r.json()['key']}"}

    body = {
        "lists": [
            {
                "title": "Importée",
                "items": [{"label": "a", "done": False, "position": 0}],
            }
        ]
    }
    r = await client.post("/import", json=body, headers=kh)
    assert r.status_code == 403, r.text
    assert r.json()["detail"] == "API key scoped to another list"

    # AUCUNE liste créée (vérifiée avec un accès non scopé du même owner).
    lists = (await client.get("/lists", headers=h)).json()
    assert [e["title"] for e in lists] == ["Scoped"]


# ---- F3 : Obsidian markdown ------------------------------------------------


@pytest.mark.asyncio
async def test_export_md(client):
    h = auth_headers(await register(client, "md@example.com"))
    list_id = await make_list(client, h, "Notes")
    await make_item(client, h, list_id, "ouverte")
    done = await make_item(client, h, list_id, "faite")
    await client.patch(
        f"/lists/{list_id}/items/{done['id']}", json={"done": True}, headers=h
    )
    await make_item(
        client,
        h,
        list_id,
        "échéance",
        due_date="2026-12-01T23:30:00Z",
    )

    r = await client.get(f"/lists/{list_id}/export.md", headers=h)
    assert r.status_code == 200
    assert "text/markdown" in r.headers["content-type"]
    lines = r.text.splitlines()
    assert lines[0] == "# Notes"
    assert "- [ ] ouverte" in lines
    assert "- [x] faite" in lines
    # Convention propre : ` (échéance YYYY-MM-DD)` — date UTC.
    assert "- [ ] échéance (échéance 2026-12-01)" in lines


@pytest.mark.asyncio
async def test_import_md_h1_checkboxes_due(client):
    h = auth_headers(await register(client, "mdimp@example.com"))
    body = "# Ma Liste\n- [ ] première\n- [x] deuxième (échéance 2026-12-05)\n"
    r = await client.post(
        "/import", content=body, headers={**h, "Content-Type": "text/markdown"}
    )
    assert r.status_code == 201, r.text
    created = r.json()["lists"]
    assert created[0]["title"] == "Ma Liste"
    assert created[0]["items"] == 2
    r = await client.get(f"/lists/{created[0]['id']}/items", headers=h)
    items = {i["label"]: i for i in r.json()}
    assert items["première"]["done"] is False
    assert items["deuxième"]["done"] is True
    assert items["deuxième"]["due_date"].startswith("2026-12-05")


@pytest.mark.asyncio
async def test_import_md_no_h1_uses_name_then_default(client):
    ha = auth_headers(await register(client, "mdname@example.com"))
    hb = auth_headers(await register(client, "mdname2@example.com"))
    body = "texte sans H1\n- [ ] un item\n"
    r = await client.post(
        "/import?name=Sans%20Titre",
        content=body,
        headers={**ha, "Content-Type": "text/markdown"},
    )
    assert r.status_code == 201, r.text
    assert r.json()["lists"][0]["title"] == "Sans Titre"

    r = await client.post(
        "/import",
        content=body,
        headers={**hb, "Content-Type": "text/markdown"},
    )
    assert r.status_code == 201, r.text
    assert r.json()["lists"][0]["title"] == "Importée", (
        "sans H1 ni ?name= : titre par défaut documenté"
    )


@pytest.mark.asyncio
async def test_import_md_empty_and_garbage_ignored(client):
    h = auth_headers(await register(client, "mdgarb@example.com"))
    body = (
        "# L\n"
        "- [ ]\n"  # checkbox vide → ignorée
        "texte qui n'est pas une liste\n"
        "- [ ] valide\n"
        "- [x] (échéance 2026-11-25)\n"  # libellé vide après l'échéance → ignoré
    )
    r = await client.post(
        "/import", content=body, headers={**h, "Content-Type": "text/markdown"}
    )
    assert r.status_code == 201, r.text
    assert r.json()["lists"][0]["items"] == 1
    r = await client.get(f"/lists/{r.json()['lists'][0]['id']}/items", headers=h)
    assert [i["label"] for i in r.json()] == ["valide"]


# ---- F4 : CSV ---------------------------------------------------------------


def _csv_lines(r) -> list[str]:
    return r.text.splitlines()


@pytest.mark.asyncio
async def test_export_csv_list_with_escaping(client):
    h = auth_headers(await register(client, "csv@example.com"))
    list_id = await make_list(client, h, "C;D,E")
    await make_item(client, h, list_id, "simple")
    await make_item(client, h, list_id, "avec, virgule")
    await make_item(client, h, list_id, "avec; point-virgule")
    done = await make_item(client, h, list_id, "fait")
    await client.patch(
        f"/lists/{list_id}/items/{done['id']}", json={"done": True}, headers=h
    )
    await make_item(client, h, list_id, "daté", due_date="2026-12-01T10:00:00Z")

    r = await client.get(f"/lists/{list_id}/export.csv", headers=h)
    assert r.status_code == 200
    assert "text/csv" in r.headers["content-type"]
    cd = r.headers["content-disposition"]
    assert cd.startswith("attachment") and ".csv" in cd
    lines = _csv_lines(r)
    assert lines[0] == "liste;titre;fait;echeance;ordre"
    assert len(lines) == 6
    assert '"C;D,E";simple;0;;0' in lines
    assert any('"avec, virgule"' in line for line in lines)
    assert any('"avec; point-virgule"' in line for line in lines)
    assert '"C;D,E";fait;1;;3' in lines
    assert any(line.startswith('"C;D,E";daté;0;2026-12-01T10:00') for line in lines)


@pytest.mark.asyncio
async def test_export_csv_scope_all(client):
    ta = auth_headers(await register(client, "csva@example.com"))
    tb = auth_headers(await register(client, "csvb@example.com"))
    la = await make_list(client, ta, "Alpha")
    await make_item(client, ta, la, "a1")
    lb = await make_list(client, tb, "Beta")
    await make_item(client, tb, lb, "b1")
    r = await client.post(
        f"/lists/{lb}/members",
        json={"email": "csva@example.com", "role": "viewer"},
        headers=tb,
    )
    assert r.status_code == 201, r.text

    r = await client.get("/export.csv?scope=all", headers=ta)
    assert r.status_code == 200
    lines = _csv_lines(r)
    assert lines[0] == "liste;titre;fait;echeance;ordre"
    assert "Alpha;a1;0;;0" in lines
    assert "Beta;b1;0;;0" in lines


@pytest.mark.asyncio
async def test_export_csv_empty_list_header_only(client):
    h = auth_headers(await register(client, "csvempty@example.com"))
    list_id = await make_list(client, h, "Vide")
    r = await client.get(f"/lists/{list_id}/export.csv", headers=h)
    assert r.status_code == 200
    assert _csv_lines(r) == ["liste;titre;fait;echeance;ordre"]
