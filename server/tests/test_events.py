from __future__ import annotations

import socket

import pytest
from httpx import ASGITransport, AsyncClient

from app.config import settings
from app.events import _webhook_host_allowed
from app.main import app


@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


async def register(client: AsyncClient, email: str = "a@example.com", password: str = "LongPassw0rd!x"):
    r = await client.post(
        "/auth/register", json={"email": email, "password": password}
    )
    assert r.status_code == 201, r.text
    return r.json()


def auth_headers(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


def _ga(ips):
    def fake(host, port):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 0)) for ip in ips]

    return fake


@pytest.mark.asyncio
async def test_cgnat_blocked(monkeypatch):
    """RFC 6598 (100.64.0.0/10) ni is_private ni is_global pour Python :
    il doit être bloqué comme les autres espaces non publics (audit run-2)."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", set())
    # borne basse
    assert _webhook_host_allowed("http://100.64.0.1/x") == (False, None)
    # borne haute
    assert _webhook_host_allowed("http://100.127.255.254/x") == (False, None)
    # public juste avant le CGNAT
    assert _webhook_host_allowed("http://100.63.255.255/x") == (True, "100.63.255.255")
    # public juste après le CGNAT
    assert _webhook_host_allowed("http://100.128.0.1/x") == (True, "100.128.0.1")


@pytest.mark.asyncio
async def test_cgnat_allowlist_opt_in(monkeypatch):
    """L'allowlist reste prioritaire : opt-in explicite conservé."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", {"100.64.0.1"})
    assert _webhook_host_allowed("http://100.64.0.1/x")[0] is True


@pytest.mark.asyncio
async def test_host_check_pins_first_allowed_ip(monkeypatch):
    """Le check résout UNE fois et renvoie l'IP épinglée (audit run-2,
    TOCTOU rebinding)."""
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", set())
    monkeypatch.setattr(socket, "getaddrinfo", _ga(["1.2.3.4"]))
    assert _webhook_host_allowed("http://good.example.invalid:8443/x") == (True, "1.2.3.4")

    monkeypatch.setattr(socket, "getaddrinfo", _ga(["10.0.0.5"]))
    assert _webhook_host_allowed("http://priv.example.invalid/x") == (False, None)

    # une seule adresse bloquée disqualifie l'hôte entier
    monkeypatch.setattr(socket, "getaddrinfo", _ga(["1.2.3.4", "10.0.0.5"]))
    assert _webhook_host_allowed("http://mixed.example.invalid/x") == (False, None)


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
    list_id = (await client.post("/lists", json={"title": "RB"}, headers=h)).json()["id"]
    r = await client.post(
        f"/lists/{list_id}/hooks",
        json={"url": "http://rebind.example.invalid:8443/x"}, headers=h,
    )
    assert r.status_code == 201
    item = (await client.post(
        f"/lists/{list_id}/items", json={"label": "x"}, headers=h)).json()[0]

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
        f"/lists/{list_id}/items/{item['id']}", json={"done": True}, headers=h)
    assert r.status_code == 200

    assert "1.2.3.4" in captured["url"], captured
    assert "127.0.0.1" not in captured["url"]
    assert captured["headers"].get("Host") == "rebind.example.invalid"
    assert calls == ["rebind.example.invalid"]  # résolu une seule fois
