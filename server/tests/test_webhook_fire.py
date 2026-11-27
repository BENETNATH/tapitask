"""Audit C1.3 — webhooks :
(a) SNI : un fetch https épinglé sur l'IP du hostname doit présenter le
    hostname d'origine en SNI / hostname de vérification, sinon le
    certificat de l'hôte n'est jamais reconnu et la livraison échoue ;
(b) fire-and-forget : une webhook lente ou en défaut ne doit ni retarder
    la réponse API ni la faire échouer (patch_item, purge_done_items).
"""

from __future__ import annotations

import asyncio
import socket
import ssl
import subprocess
import time

import pytest
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


@pytest.fixture(scope="module")
def tls_certs(tmp_path_factory):
    d = tmp_path_factory.mktemp("certs")
    cert, key = d / "cert.pem", d / "key.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-keyout",
            str(key),
            "-out",
            str(cert),
            "-days",
            "2",
            "-subj",
            "/CN=hooks.test.invalid",
            "-addext",
            "subjectAltName=DNS:hooks.test.invalid",
        ],
        check=True,
        capture_output=True,
    )
    return cert, key


async def _tls_server(cert, key) -> tuple:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(str(cert), str(key))
    received: dict = {}

    async def handler(reader, writer):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = await reader.read(4096)
            if not chunk:
                break
            data += chunk
        head, _, rest = data.partition(b"\r\n\r\n")
        head = head.decode("latin1")
        content_length = 0
        for line in head.split("\r\n"):
            if line.lower().startswith("content-length:"):
                content_length = int(line.split(":", 1)[1].strip())
        while len(rest) < content_length:
            rest += await reader.read(4096)
        received["head"] = head
        received["body"] = rest[:content_length].decode("utf-8", "replace")
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()
        writer.close()

    server = await asyncio.start_server(handler, "127.0.0.1", 0, ssl=ctx)
    port = server.sockets[0].getsockname()[1]
    return server, port, received


@pytest.mark.asyncio
async def test_pinned_ip_https_delivery_presents_origin_sni(
    client, tls_certs, monkeypatch
):
    """Le fetch part vers l'IP épinglée (netloc) mais SNI + vérification du
    certificat portent sur le hostname d'origine : sans ça, https vers un
    hostname résolu en IP ne fonctionne jamais."""
    import app.events as ev
    import httpx

    cert, key = tls_certs
    server, port, received = await _tls_server(cert, key)
    try:
        # Pas de DNS dans le test : création du hook sans résolution.
        monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [])

        # La validation SSRF est simulée : épinglé sur le serveur local.
        # (prod4 : _webhook_host_allowed est async — M3, DNS via to_thread.)
        async def _fake_host_allowed(url):
            return (True, "127.0.0.1")

        monkeypatch.setattr(ev, "_webhook_host_allowed", _fake_host_allowed)

        original_client = httpx.AsyncClient

        class _VerifiedClient(original_client):
            def __init__(self, *a, **kw):
                kw["verify"] = str(cert)
                super().__init__(*a, **kw)

        monkeypatch.setattr(httpx, "AsyncClient", _VerifiedClient)

        tokens = await register(client, "sni@example.com")
        h = auth_headers(tokens)
        lid = (await client.post("/lists", json={"title": "S"}, headers=h)).json()["id"]
        r = await client.post(
            f"/lists/{lid}/hooks",
            json={"url": f"https://hooks.test.invalid:{port}/x"},
            headers=h,
        )
        assert r.status_code == 201, r.text
        item = (
            await client.post(f"/lists/{lid}/items", json={"label": "x"}, headers=h)
        ).json()[0]
        r = await client.patch(
            f"/lists/{lid}/items/{item['id']}", json={"done": True}, headers=h
        )
        assert r.status_code == 200, r.text

        async def wait_delivery():
            for _ in range(100):
                if received:
                    return
                await asyncio.sleep(0.02)
            raise AssertionError("webhook https jamais livrée (SNI/hostname)")

        await wait_delivery()
    finally:
        server.close()
        await server.wait_closed()

    head = received["head"]
    assert "Host: hooks.test.invalid" in head, head
    assert "item.checked" in received["body"]
    assert "X-Tapitask-Signature" in head


@pytest.mark.asyncio
async def test_patch_item_not_blocked_by_slow_webhook(client, monkeypatch):
    import app.routers.lists as lists_router

    called = asyncio.Event()

    async def slow_fire(*a, **k):
        await asyncio.sleep(0.5)
        called.set()

    monkeypatch.setattr(lists_router, "fire_webhooks", slow_fire)

    tokens = await register(client, "ffo@example.com")
    h = auth_headers(tokens)
    lid = (await client.post("/lists", json={"title": "F"}, headers=h)).json()["id"]
    item = (
        await client.post(f"/lists/{lid}/items", json={"label": "t"}, headers=h)
    ).json()[0]

    t0 = time.monotonic()
    r = await client.patch(
        f"/lists/{lid}/items/{item['id']}", json={"done": True}, headers=h
    )
    elapsed = time.monotonic() - t0
    assert r.status_code == 200, r.text
    assert elapsed < 0.4, f"réponse retardée par la webhook lente ({elapsed:.2f}s)"
    assert not called.is_set(), "la webhook doit tourner APRÈS la réponse"
    await asyncio.wait_for(called.wait(), timeout=2)


@pytest.mark.asyncio
async def test_purge_done_items_not_blocked_by_slow_webhook(client, monkeypatch):
    import app.routers.lists as lists_router

    called = asyncio.Event()

    async def slow_fire(*a, **k):
        await asyncio.sleep(0.5)
        called.set()

    monkeypatch.setattr(lists_router, "fire_webhooks", slow_fire)

    tokens = await register(client, "ffop@example.com")
    h = auth_headers(tokens)
    lid = (await client.post("/lists", json={"title": "P"}, headers=h)).json()["id"]
    item = (
        await client.post(f"/lists/{lid}/items", json={"label": "t"}, headers=h)
    ).json()[0]
    await client.patch(
        f"/lists/{lid}/items/{item['id']}", json={"done": True}, headers=h
    )

    t0 = time.monotonic()
    r = await client.delete(f"/lists/{lid}/done-items", headers=h)
    elapsed = time.monotonic() - t0
    assert r.status_code == 204, r.text
    assert elapsed < 0.4, f"réponse retardée par la webhook lente ({elapsed:.2f}s)"
    assert not called.is_set(), "la webhook doit tourner APRÈS la réponse"
    await asyncio.wait_for(called.wait(), timeout=2)
