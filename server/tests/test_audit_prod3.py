"""Audit 2026-11-24 production 3 — tests serveur (1.5, 1.6, 2.3, 2.4, 3.3, 3.4).

Chaque test verrouille une propriété de la spec, pas le code : les baselines
existantes (test_api, test_events, test_lot_t_security…) restent les
proprioétaires des comportements non couverts ici."""

from __future__ import annotations

import asyncio
import datetime as dt
import uuid

import pytest
from app.config import settings
from app.main import app
from httpx import ASGITransport, AsyncClient


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client: AsyncClient, email: str, password: str = "LongPassw0rd!x"):
    r = await client.post("/auth/register", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _as_utc(value) -> dt.datetime:
    """Parse une date JSON et renvoie l'instant en UTC (naïf = supposé UTC)."""
    d = dt.datetime.fromisoformat(value)
    if d.tzinfo is None:
        d = d.replace(tzinfo=dt.timezone.utc)
    return d.astimezone(dt.timezone.utc)


# ---- 1.5 : horodatages aware → UTC ----------------------------------------


@pytest.mark.asyncio
async def test_sync_push_plus02_datetime_stored_as_utc(client):
    """1.5 / MD-1 : un timestamp entrant +02:00 est converti en UTC — pas de
    décalage de 2 h au stockage (avant le fix : tz retirée SANS conversion)."""
    tokens = await register(client, "utc15@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "T"}, headers=h)).json()["id"]

    r = await client.post("/sync", json={"events": []}, headers=h)
    server_time = _as_utc(r.json()["server_time"])

    # now - 4 s (dans la tolérance d'horloge ±5 s → pas de clamp), exprimé
    # en +02:00. Le moment instantané en UTC ne bouge pas.
    instant = server_time - dt.timedelta(seconds=4)
    plus02 = instant.astimezone(dt.timezone(dt.timedelta(hours=2)))
    ev = {
        "id": str(uuid.uuid4()),
        "list_id": list_id,
        "kind": "item.upsert",
        "label": "x",
        "done": False,
        "position": 1,
        "updated_at": plus02.isoformat(),
    }
    r = await client.post("/sync", json={"events": [ev]}, headers=h)
    assert r.status_code == 200 and r.json()["rejected"] == []

    items = (await client.get(f"/lists/{list_id}/items", headers=h)).json()
    stored = _as_utc(items[0]["updated_at"])
    # Avant le fix : stored == instant + 2 h.
    assert abs((stored - instant).total_seconds()) < 1, (
        f"stored={stored.isoformat()} instant={instant.isoformat()}"
    )


@pytest.mark.asyncio
async def test_sync_lww_aware_timestamps_compare_cleanly(client):
    """1.5 : un upsert plus ancien (exprimé +02:00) ne bat pas l'état
    existant — les comparaisons LWW mélangent plus jamais naïf/aware."""
    tokens = await register(client, "utc15b@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "T"}, headers=h)).json()["id"]
    item_id = str(uuid.uuid4())

    r = await client.post("/sync", json={"events": []}, headers=h)
    server_time = _as_utc(r.json()["server_time"])

    first = {
        "id": item_id,
        "list_id": list_id,
        "kind": "item.upsert",
        "label": "nouveau",
        "done": False,
        "position": 1,
        "updated_at": (server_time - dt.timedelta(seconds=1)).isoformat(),
    }
    r = await client.post("/sync", json={"events": [first]}, headers=h)
    assert r.json()["rejected"] == []

    older = (server_time - dt.timedelta(seconds=10)).astimezone(
        dt.timezone(dt.timedelta(hours=2))
    )
    second = {
        "id": item_id,
        "list_id": list_id,
        "kind": "item.upsert",
        "label": "ancien",
        "done": False,
        "position": 1,
        "updated_at": older.isoformat(),
    }
    r = await client.post("/sync", json={"events": [second]}, headers=h)
    assert r.status_code == 200 and r.json()["rejected"] == []

    items = (await client.get(f"/lists/{list_id}/items", headers=h)).json()
    assert items[0]["label"] == "nouveau"


# ---- 1.6 : login ordre/lockout + TOTP token + verify-email ----------------


async def _enable_totp(client, h: dict) -> dict:
    import pyotp

    setup = (await client.post("/auth/totp/setup", headers=h)).json()
    r = await client.post(
        "/auth/totp/enable",
        json={"code": pyotp.TOTP(setup["secret"]).now(), "token": setup["token"]},
        headers=h,
    )
    assert r.status_code == 204, r.text
    return setup


@pytest.mark.asyncio
async def test_login_bad_password_uniform_401_and_counted(client):
    """1.6 : mdp faux avec un compte TOTP actif → 401 « Invalid credentials »
    (pas d'oracle 2FA) + compté dans le lockout."""
    from app.routers import auth as auth_router

    tokens = await register(client, "lg16a@example.com")
    h = auth_headers(tokens)
    await _enable_totp(client, h)

    before = sum(c for c, _ in auth_router._failed_logins.values())
    r = await client.post(
        "/auth/login", json={"email": "lg16a@example.com", "password": "WrongPassw0rd!"}
    )
    assert r.status_code == 401
    assert r.json()["detail"] == "Invalid credentials"
    after = sum(c for c, _ in auth_router._failed_logins.values())
    assert after >= before + 1, (
        "l'échec mdp d'un compte TOTP doit compter dans le lockout"
    )


@pytest.mark.asyncio
async def test_login_totp_failure_counted_in_lockout(client):
    """1.6 : mdp bon + TOTP mauvais → 401 + compté (avant le fix : échec
    TOTP jamais compté → contournement du lockout par TOTP)."""
    from app.routers import auth as auth_router

    tokens = await register(client, "lg16b@example.com")
    h = auth_headers(tokens)
    await _enable_totp(client, h)

    before = sum(c for c, _ in auth_router._failed_logins.values())
    r = await client.post(
        "/auth/login",
        json={
            "email": "lg16b@example.com",
            "password": "LongPassw0rd!x",
            "totp_code": "000000",
        },
    )
    assert r.status_code == 401
    after = sum(c for c, _ in auth_router._failed_logins.values())
    assert after >= before + 1


@pytest.mark.asyncio
async def test_totp_setup_persists_nothing(client):
    """1.6 / MD-2 : setup ne persiste plus totp_secret — sans enable, le
    compte ne reste pas verrouillé par un secret jamais activé."""
    tokens = await register(client, "ts16@example.com")
    h = auth_headers(tokens)
    r = await client.post("/auth/totp/setup", headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["secret"] and body["uri"] and body["token"]

    me = (await client.get("/auth/me", headers=h)).json()
    assert me["totp"] is False
    # login sans code toujours possible
    r = await client.post(
        "/auth/login", json={"email": "ts16@example.com", "password": "LongPassw0rd!x"}
    )
    assert r.status_code == 200


@pytest.mark.asyncio
async def test_totp_enable_requires_own_valid_token(client):
    """1.6 / MD-2 : enable sans token → 400 ; token d'UN AUTRE compte → 400."""
    tokens = await register(client, "te16a@example.com")
    h = auth_headers(tokens)
    setup = (await client.post("/auth/totp/setup", headers=h)).json()

    import pyotp

    r = await client.post(
        "/auth/totp/enable", json={"code": pyotp.TOTP(setup["secret"]).now()}, headers=h
    )
    assert r.status_code == 400

    other = await register(client, "te16b@example.com")
    h2 = auth_headers(other)
    setup2 = (await client.post("/auth/totp/setup", headers=h2)).json()
    r = await client.post(
        "/auth/totp/enable",
        json={"code": pyotp.TOTP(setup["secret"]).now(), "token": setup2["token"]},
        headers=h,
    )
    assert r.status_code == 400
    # le compte A reste non-activé
    assert (await client.get("/auth/me", headers=h)).json()["totp"] is False


@pytest.mark.asyncio
async def test_totp_disable_requires_valid_code(client):
    """1.6 / MD-2 : disable exige un code TOTP valide contre le secret
    courant (pas le mdp)."""
    import pyotp

    tokens = await register(client, "td16@example.com")
    h = auth_headers(tokens)
    setup = await _enable_totp(client, h)

    r = await client.post(
        "/auth/totp/enable", json={"code": "000000", "disable": True}, headers=h
    )
    assert r.status_code == 400
    assert (await client.get("/auth/me", headers=h)).json()["totp"] is True

    r = await client.post(
        "/auth/totp/enable",
        json={"code": pyotp.TOTP(setup["secret"]).now(), "disable": True},
        headers=h,
    )
    assert r.status_code == 204
    assert (await client.get("/auth/me", headers=h)).json()["totp"] is False


@pytest.mark.asyncio
async def test_verify_email_rate_limited(client):
    """1.6 / MD-3 : /verify-email borné à 5/min par clé client → 429 au 6e."""
    from app.db import SessionLocal
    from app.models import User
    from app.routers import auth as auth_router
    from sqlalchemy import select

    await register(client, "ve16@example.com")
    async with SessionLocal() as s:
        user = (
            await s.execute(select(User).where(User.email == "ve16@example.com"))
        ).scalar_one()
        user.email_token = "token-verify-16"
        await s.commit()

    for i in range(5):
        r = await client.post("/auth/verify-email", json={"token": "token-verify-16"})
        assert r.status_code in (204, 404), r.text
    r = await client.post("/auth/verify-email", json={"token": "autre"})
    assert r.status_code == 429
    assert auth_router._verify_email_limiter.max_requests == 5


@pytest.mark.asyncio
async def test_verify_email_expired_token_rejected(client):
    """1.6 / MD-3 : email_token > 24 h → 400 « expiré » ; token frais → 204."""
    from app.db import SessionLocal
    from app.models import User, utcnow
    from sqlalchemy import select

    await register(client, "ve16b@example.com")
    async with SessionLocal() as s:
        user = (
            await s.execute(select(User).where(User.email == "ve16b@example.com"))
        ).scalar_one()
        user.email_token = "token-old"
        user.email_token_created_at = utcnow() - dt.timedelta(hours=25)
        await s.commit()

    r = await client.post("/auth/verify-email", json={"token": "token-old"})
    assert r.status_code == 400, r.text

    async with SessionLocal() as s:
        user = (
            await s.execute(select(User).where(User.email == "ve16b@example.com"))
        ).scalar_one()
        user.email_token = "token-fresh"
        user.email_token_created_at = utcnow()
        await s.commit()

    r = await client.post("/auth/verify-email", json={"token": "token-fresh"})
    assert r.status_code == 204


# ---- 2.3 : parent_id & réponses lists.py ----------------------------------


async def _list_with_items(client, h: dict, n: int = 1) -> tuple[str, list[dict]]:
    list_id = (await client.post("/lists", json={"title": "T"}, headers=h)).json()["id"]
    items = []
    for i in range(n):
        r = await client.post(
            f"/lists/{list_id}/items", json={"label": f"i{i}"}, headers=h
        )
        items.append(r.json()[0])
    return list_id, items


@pytest.mark.asyncio
async def test_patch_item_parent_validation(client):
    """2.3 : patch_item parent inexistant / autre liste / soi-même /
    sous-tâche → 400 ; parent valide → 200."""
    tokens = await register(client, "p23@example.com")
    h = auth_headers(tokens)
    list_id, [item] = await _list_with_items(client, h)
    parent = (
        await client.post(f"/lists/{list_id}/items", json={"label": "p"}, headers=h)
    ).json()[0]
    child = (
        await client.post(
            f"/lists/{list_id}/items",
            json={"label": "c", "parent_id": parent["id"]},
            headers=h,
        )
    ).json()[0]
    other = (await client.post("/lists", json={"title": "U"}, headers=h)).json()["id"]
    foreign_parent = (
        await client.post(f"/lists/{other}/items", json={"label": "x"}, headers=h)
    ).json()[0]

    url = f"/lists/{list_id}/items/{item['id']}"
    r = await client.patch(url, json={"parent_id": str(uuid.uuid4())}, headers=h)
    assert r.status_code == 400, "parent inexistant"
    r = await client.patch(url, json={"parent_id": foreign_parent["id"]}, headers=h)
    assert r.status_code == 400, "parent dans une autre liste"
    r = await client.patch(url, json={"parent_id": item["id"]}, headers=h)
    assert r.status_code == 400, "soi-même (cycle)"
    r = await client.patch(url, json={"parent_id": child["id"]}, headers=h)
    assert r.status_code == 400, "parent déjà sous-tâche"
    r = await client.patch(url, json={"parent_id": parent["id"]}, headers=h)
    assert r.status_code == 200
    assert r.json()[0]["parent_id"] == parent["id"]


@pytest.mark.asyncio
async def test_sync_upsert_parent_validation_rejected(client):
    """2.3 : le chemin sync applique la MÊME validation — événement rejeté
    (pas d'erreur 500, l'outbox du client est purgé proprement)."""
    tokens = await register(client, "s23@example.com")
    h = auth_headers(tokens)
    list_id, [item] = await _list_with_items(client, h)

    ev = {
        "id": item["id"],
        "list_id": list_id,
        "kind": "item.upsert",
        "label": "i0",
        "done": False,
        "position": 1,
        "parent_id": str(uuid.uuid4()),
        "updated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    r = await client.post("/sync", json={"events": [ev]}, headers=h)
    assert r.status_code == 200
    assert r.json()["rejected"] == [item["id"]]


@pytest.mark.asyncio
async def test_rename_list_owner_role_and_folder(client):
    """2.3 : rename_list — le propriétaire voit role « owner » (pas
    « member » en dur) et le folder (omis avant le fix)."""
    tokens = await register(client, "rn23@example.com")
    h = auth_headers(tokens)
    list_id = (
        await client.post(
            "/lists", json={"title": "Avant", "folder": "Travail"}, headers=h
        )
    ).json()["id"]
    r = await client.patch(f"/lists/{list_id}", json={"title": "Après"}, headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["role"] == "owner"
    assert body["folder"] == "Travail"
    assert body["title"] == "Après"


@pytest.mark.asyncio
async def test_list_summary_total_counts_checked_items(client):
    """2.3 : total = TOUS les items non supprimés (avant le fix : total ==
    unchecked, les items cochés n'existaient plus)."""
    tokens = await register(client, "ls23@example.com")
    h = auth_headers(tokens)
    list_id, items = await _list_with_items(client, h, n=3)
    for it in items[:2]:
        r = await client.patch(
            f"/lists/{list_id}/items/{it['id']}", json={"done": True}, headers=h
        )
        assert r.status_code == 200
    r = await client.get(f"/lists/{list_id}/summary", headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["total"] == 3
    assert body["unchecked"] == 1
    assert body["unchecked_labels"] == [items[2]["label"]]


# ---- 2.4 : webhooks — schéma d'abord, trust_env=False ---------------------


@pytest.mark.asyncio
async def test_webhook_non_http_scheme_with_allowed_host_rejected(monkeypatch):
    """2.4 : le schéma http(s) est vérifié AVANT le bypass
    WEBHOOK_ALLOWED_HOSTS — un file:// sur un host « autorisé » est refusé.
    (prod4 : validate_webhook_url est async — DNS via to_thread, M3.)"""
    from app.events import validate_webhook_url

    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", ["internal.example.com"])
    allowed, _ = await validate_webhook_url("file://internal.example.com/evil")
    assert not allowed
    # et un http:// légitime passe toujours
    allowed, _ = await validate_webhook_url("http://internal.example.com/hook")
    assert allowed


@pytest.mark.asyncio
async def test_webhook_delivery_client_trust_env_false(client, monkeypatch):
    """2.4 : le client de livraison est construit avec trust_env=False —
    HTTP_PROXY/HTTPS_PROXY de l'hôte ne doit pas détourner le POST."""
    import httpx

    from app import events

    captured: dict = {}

    class CapturingClient:
        def __init__(self, *args, **kwargs):
            captured.update(kwargs)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def post(self, url, **kwargs):
            raise RuntimeError("aucun réseau réel dans ce test")

    monkeypatch.setattr(httpx, "AsyncClient", CapturingClient)

    from app.db import SessionLocal
    from app.models import Webhook

    tokens = await register(client, "wk24@example.com")
    h = auth_headers(tokens)
    list_id = uuid.UUID(
        (await client.post("/lists", json={"title": "T"}, headers=h)).json()["id"]
    )
    user_id = uuid.UUID((await client.get("/auth/me", headers=h)).json()["id"])
    # webhook sur un host autorisé (pas de résolution réseau nécessaire)
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", ["internal.example.com"])
    async with SessionLocal() as s:
        s.add(
            Webhook(
                list_id=list_id,
                user_id=user_id,
                url="http://internal.example.com/hook",
                secret="s",
            )
        )
        await s.commit()

    await events.fire_webhooks(list_id, {"event": "x"})
    assert captured.get("trust_env") is False, captured


# ---- 3.3 : RateLimiter — purge, fallback Redis, parsing proxies -----------


@pytest.mark.asyncio
async def test_rate_limiter_purges_empty_keys():
    """3.3 : les deque vides ne restent pas en dict indéfiniment — purge
    amortie au-delà de 10 000 entrées (fuite lente, 1 clé par IP/cible)."""
    import time
    from collections import deque

    from app.deps import RateLimiter

    rl = RateLimiter(5)
    for i in range(10_001):
        rl.hits[f"k{i}"] = deque()
    rl.hits["live"] = deque([time.monotonic()])
    await rl.check("fresh")
    # les clés vides sont parties, les clés vivantes restent
    assert "k0" not in rl.hits and "k10000" not in rl.hits
    assert "live" in rl.hits and "fresh" in rl.hits


@pytest.mark.asyncio
async def test_rate_limiter_redis_down_falls_back_to_memory():
    """3.3 / MD-6 : Redis tombé → log + fallback mémoire pour l'appel
    courant (jamais de 500 sur toute l'API)."""
    from app.deps import RateLimiter

    class Boom:
        async def incr(self, key):
            raise ConnectionError("redis down")

    rl = RateLimiter(5)
    rl.redis = Boom()
    await rl.check("x")  # ne lève pas
    assert "x" in rl.hits, "fallback mémoire pour l'appel courant"
    # le fallback mémoire applique la même limite
    for _ in range(4):
        await rl.check("x")
    with pytest.raises(Exception) as e:
        await rl.check("x")
    assert "429" in str(e.value.status_code)


def test_trusted_proxies_csv_parsing():
    """3.3 / MD-6 : "" → [], espaces stripés, vides intermédiaires écartés
    (avant le fix : "" → [""] et "a, b" → " b" jamais égal au peer)."""
    from app.config import _parse_csv, settings

    assert _parse_csv("") == []
    assert _parse_csv(None) == []
    assert _parse_csv("10.0.0.1, 10.0.0.2 ,") == ["10.0.0.1", "10.0.0.2"]
    assert _parse_csv("  10.0.0.1  ") == ["10.0.0.1"]
    # valeur effective en test (env non définie) : vide, pas [""]
    assert settings.TRUSTED_PROXIES == []


# ---- 3.4 : partage — l'email ne bloque plus la requête --------------------


@pytest.mark.asyncio
async def test_invite_email_is_fire_and_forget(client, monkeypatch):
    """3.4 : la requête répond SANS attendre le relais SMTP — un relais
    lent (10-20 s) ne doit plus geler la création d'invitation."""
    from app.routers import sharing

    sent: list[str] = []

    async def slow_send(to, subject, body):
        await asyncio.sleep(0.4)
        sent.append(to)

    monkeypatch.setattr(sharing, "send_email", slow_send)

    tokens = await register(client, "sh34@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "T"}, headers=h)).json()["id"]
    r = await client.post(
        f"/lists/{list_id}/invites",
        json={"hours": 24, "email": "invited@example.com"},
        headers=h,
    )
    assert r.status_code == 201
    assert sent == [], "la réponse a attendu le relais SMTP (lent)"
    await asyncio.sleep(0.6)
    assert sent == ["invited@example.com"], "l'email best-effort doit bien partir"
