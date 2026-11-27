from __future__ import annotations

import asyncio
import socket
import uuid

import pytest
from app.config import settings
from app.events import _webhook_host_allowed, record_change
from app.main import app
from httpx import ASGITransport, AsyncClient


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(
    client: AsyncClient, email: str = "a@example.com", password: str = "LongPassw0rd!x"
):
    r = await client.post("/auth/register", json={"email": email, "password": password})
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _ga(ips):
    def fake(host, port):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0)) for ip in ips]

    return fake


def _ga6(ips):
    def fake(host, port):
        return [(socket.AF_INET6, socket.SOCK_STREAM, 6, "", (ip, 0)) for ip in ips]

    return fake


@pytest.mark.asyncio
async def test_record_change_commit_parameter():
    """spec §1 : record_change(commit=False) ne fait aucun commit — la ligne
    simplement addée et devient persistée par un commit ultérieur sur la
    même session. Défaut (True) : le commit se fait immédiatement
    (call-sites REST/MCP inchangés)."""
    from app.db import engine
    from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

    counts = {"n": 0}

    class SpySession(AsyncSession):
        async def commit(self):
            counts["n"] += 1
            return await super().commit()

    spy = async_sessionmaker(engine, expire_on_commit=False, class_=SpySession)

    async with spy() as s:
        await record_change(s, list_id=uuid.uuid4(), kind="item.upsert", commit=False)
    assert counts["n"] == 0

    async with spy() as s2:
        await s2.commit()  # commit ultérieur sur la session : la ligne part
    assert counts["n"] == 1

    before = counts["n"]
    async with spy() as s3:
        await record_change(s3, list_id=uuid.uuid4(), kind="item.upsert")
    assert counts["n"] == before + 1  # défaut : commit par appel


@pytest.mark.asyncio
async def test_cgnat_blocked(monkeypatch):
    """RFC 6598 (100.64.0.0/10) ni is_private ni is_global pour Python :
    il doit être bloqué comme les autres espaces non publics (audit run-2)."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", set())
    # borne basse
    assert await _webhook_host_allowed("http://100.64.0.1/x") == (False, None)
    # borne haute
    assert await _webhook_host_allowed("http://100.127.255.254/x") == (False, None)
    # public juste avant le CGNAT
    assert await _webhook_host_allowed("http://100.63.255.255/x") == (
        True,
        "100.63.255.255",
    )
    # public juste après le CGNAT
    assert await _webhook_host_allowed("http://100.128.0.1/x") == (True, "100.128.0.1")


@pytest.mark.asyncio
async def test_cgnat_allowlist_opt_in(monkeypatch):
    """L'allowlist reste prioritaire : opt-in explicite conservé."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", {"100.64.0.1"})
    assert (await _webhook_host_allowed("http://100.64.0.1/x"))[0] is True


@pytest.mark.asyncio
async def test_host_check_pins_first_allowed_ip(monkeypatch):
    """Le check résout UNE fois et renvoie l'IP épinglée (audit run-2,
    TOCTOU rebinding)."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", set())
    monkeypatch.setattr(socket, "getaddrinfo", _ga(["1.2.3.4"]))
    assert await _webhook_host_allowed("http://good.example.invalid:8443/x") == (
        True,
        "1.2.3.4",
    )

    monkeypatch.setattr(socket, "getaddrinfo", _ga(["10.0.0.5"]))
    assert await _webhook_host_allowed("http://priv.example.invalid/x") == (False, None)

    # une seule adresse bloquée disqualifie l'hôte entier
    monkeypatch.setattr(socket, "getaddrinfo", _ga(["1.2.3.4", "10.0.0.5"]))
    assert await _webhook_host_allowed("http://mixed.example.invalid/x") == (
        False,
        None,
    )


@pytest.mark.asyncio
async def test_webhook_dns_rebinding_is_pinned(client, monkeypatch):
    """Rebinding : le check voit 1.2.3.4, une 2e résolution verrait
    127.0.0.1 — le fetch doit partir vers l'IP épinglée, pas re-résoudre."""
    import httpx

    calls = []

    def fake_getaddrinfo(host, port, *args, **kwargs):
        calls.append(host)
        ip = "1.2.3.4" if len(calls) == 1 else "127.0.0.1"
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0))]

    tokens = await register(client, "rebind@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "RB"}, headers=h)).json()[
        "id"
    ]
    r = await client.post(
        f"/lists/{list_id}/hooks",
        json={"url": "http://rebind.example.invalid:8443/x"},
        headers=h,
    )
    assert r.status_code == 201
    item = (
        await client.post(f"/lists/{list_id}/items", json={"label": "x"}, headers=h)
    ).json()[0]

    # posé après la setup : le client de test est un httpx.AsyncClient lui-même
    captured = {}

    async def fake_post(self, url, **kwargs):
        captured["url"] = url
        captured["headers"] = dict(kwargs.get("headers") or {})
        return httpx.Response(200)

    monkeypatch.setattr(socket, "getaddrinfo", fake_getaddrinfo)
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", ["1.2.3.4"])
    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)
    r = await client.patch(
        f"/lists/{list_id}/items/{item['id']}", json={"done": True}, headers=h
    )
    assert r.status_code == 200

    # C1.3 : la livraison est fire-and-forget — elle tourne après la réponse.
    for _ in range(100):
        if captured:
            break
        await asyncio.sleep(0.02)

    assert "1.2.3.4" in captured["url"], captured
    assert "127.0.0.1" not in captured["url"]
    assert captured["headers"].get("Host") == "rebind.example.invalid"
    assert calls == ["rebind.example.invalid"]  # résolu une seule fois


# ---- M3 (prod4) : DNS non bloquant + CGNAT v4-mappé + rejet explicite -----


@pytest.mark.asyncio
async def test_cgnat_v4_mapped_blocked(monkeypatch):
    """M3 : un CGNAT/privé en v4-mappé (::ffff:a.b.c.d) est déplié en IPv4
    et rejeté comme le v4 pur (avant le fix : is_global IPv6 → accepté).
    Un public v4-mappé reste accepté (pinned = l'IPv4 déplié)."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", set())
    monkeypatch.setattr(socket, "getaddrinfo", _ga6(["::ffff:100.64.0.1"]))
    assert await _webhook_host_allowed("http://cgnat-mapped.invalid/x") == (False, None)
    monkeypatch.setattr(socket, "getaddrinfo", _ga6(["::ffff:10.0.0.5"]))
    assert await _webhook_host_allowed("http://priv-mapped.invalid/x") == (False, None)
    monkeypatch.setattr(socket, "getaddrinfo", _ga6(["::ffff:1.2.3.4"]))
    assert await _webhook_host_allowed("http://pub-mapped.invalid/x") == (
        True,
        "1.2.3.4",
    )


@pytest.mark.asyncio
async def test_dns_goes_through_to_thread(monkeypatch):
    """M3 : le DNS (socket.getaddrinfo) passe par asyncio.to_thread — le
    worker uvicorn unique n'est pas bloqué par un DNS lent."""
    import asyncio

    through_to_thread = []
    real_to_thread = asyncio.to_thread

    async def spy_to_thread(func, *args, **kwargs):
        through_to_thread.append(func)
        return await real_to_thread(func, *args, **kwargs)

    monkeypatch.setattr(asyncio, "to_thread", spy_to_thread)
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", set())
    monkeypatch.setattr(socket, "getaddrinfo", _ga(["93.184.21.34"]))
    ok, pinned = await _webhook_host_allowed("http://dns-spy.invalid/x")
    assert ok is True and pinned == "93.184.21.34"
    assert socket.getaddrinfo in through_to_thread, "le DNS doit passer par to_thread"


@pytest.mark.asyncio
async def test_unresolvable_host_is_rejected_at_delivery(monkeypatch):
    """M3 : host non résolvable → rejet explicite (aucune notification
    n'est envoyée)."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", set())

    def nxdomain(host, port):
        raise socket.gaierror("Name or service not known")

    monkeypatch.setattr(socket, "getaddrinfo", nxdomain)
    assert await _webhook_host_allowed("http://nope.invalid/x") == (False, None)
