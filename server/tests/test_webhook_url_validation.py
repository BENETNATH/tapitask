from __future__ import annotations

import socket

import pytest
from app.config import settings
from app.events import validate_webhook_url
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


def fake_resolver(mapping: dict[str, list[str]]):
    """Injectable resolver: hostname -> [ip, ...]; unknown names raise
    (NXDOMAIN). No real DNS, no network."""

    def resolver(host: str):
        if host not in mapping:
            raise Exception("NXDOMAIN")
        return mapping[host]

    return resolver


@pytest.mark.asyncio
async def test_validator_rejects_internal(monkeypatch):
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", [])
    res = fake_resolver(
        {
            "loop.internal": ["127.0.0.1"],
            "meta.internal": ["169.254.169.254"],
            "lan10.internal": ["10.1.2.3"],
            "lan192.internal": ["192.168.0.7"],
            "lan172.internal": ["172.16.5.9"],
            "cgnat.internal": ["100.64.10.10"],
        }
    )
    # scheme: only http/https are considered (file://, gopher:// ... refused)
    assert (await validate_webhook_url("ftp://93.184.21.34/x", res))[0] is False
    assert (await validate_webhook_url("file:///etc/passwd", res))[0] is False
    # IP literals (IPv6 literals need brackets in the URL)
    for host in (
        "127.0.0.1",
        "169.254.169.254",
        "10.0.0.5",
        "192.168.1.1",
        "172.16.0.1",
        "0.2.3.4",
        "[::1]",
        "[fd00::1]",
        "[fe80::1]",
    ):
        assert (await validate_webhook_url(f"https://{host}/x", res))[0] is False, host
    # names resolving to internal ranges
    for name in (
        "loop.internal",
        "meta.internal",
        "lan10.internal",
        "lan192.internal",
        "lan172.internal",
        "cgnat.internal",
    ):
        assert (await validate_webhook_url(f"https://{name}/x", res))[0] is False, name
    # unresolvable name: not provably internal -> deferred to the delivery
    # check (which re-resolves and rejects internal targets)
    assert await validate_webhook_url("https://no-such-host.invalid/x", res) == (
        True,
        None,
    )


@pytest.mark.asyncio
async def test_validator_accepts_public_https_and_pins_ip(monkeypatch):
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", [])
    res = fake_resolver({"public.example": ["93.184.21.34"]})
    assert await validate_webhook_url("https://public.example/x", res) == (
        True,
        "93.184.21.34",
    )
    # public IP literal: no resolution needed
    assert await validate_webhook_url("https://93.184.21.34/x", res) == (
        True,
        "93.184.21.34",
    )


@pytest.mark.asyncio
async def test_webhook_creation_rejects_internal_url(client, monkeypatch):
    monkeypatch.setattr(settings, "WEBHOOK_ALLOWED_HOSTS", [])
    # the route's default resolver is mocked: no real DNS, no network
    monkeypatch.setattr(
        socket,
        "getaddrinfo",
        lambda host, port, *a, **k: [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.21.34", 0))
        ],
    )
    tokens = await register(client, "whval@example.com")
    h = auth_headers(tokens)
    list_id = (await client.post("/lists", json={"title": "W"}, headers=h)).json()["id"]

    for url in (
        "https://169.254.169.254/latest/meta-data",
        "https://127.0.0.1/x",
        "https://10.0.0.5/x",
        "https://[::1]/x",
    ):
        r = await client.post(f"/lists/{list_id}/hooks", json={"url": url}, headers=h)
        assert r.status_code == 400, (url, r.status_code, r.text)

    # a public URL is accepted (http kept for parity with the delivery
    # check — see validate_webhook_url shortcut note)
    r = await client.post(
        f"/lists/{list_id}/hooks",
        json={"url": "https://hooks.example.com/x"},
        headers=h,
    )
    assert r.status_code == 201, r.text
    r = await client.post(
        f"/lists/{list_id}/hooks", json={"url": "http://hooks.example.com/x"}, headers=h
    )
    assert r.status_code == 201, r.text
