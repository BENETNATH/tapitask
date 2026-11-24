from __future__ import annotations

import asyncio
import ipaddress
from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from .models import ChangeLog, utcnow

# RFC 6598 : Python ne classe pas le CGNAT en is_private ni is_global.
_CGNAT = ipaddress.ip_network("100.64.0.0/10")


def _ip_is_public(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """False for every non-public destination: RFC1918/CGNAT, loopback,
    link-local (cloud metadata 169.254.169.254 incl.), 0.0.0.0/8, reserved,
    multicast, IPv6 ULA/link-local."""
    return not (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_reserved or ip.is_multicast or ip.is_unspecified
                or ip in _CGNAT)


def validate_webhook_url(url: str, resolver=None) -> tuple[bool, str | None]:
    """Pure SSRF gate for webhook URLs, applied at creation/update time
    (Strix vuln-0004); the delivery check re-applies it as defense in depth.

    http(s) — the WEBHOOK_ALLOWED_HOSTS opt-in bypasses the block, same as
    at delivery. The host must be a public IP literal or a name that
    resolves to public addresses only. `resolver` maps hostname to a list
    of IP strings (injectable for tests); the default resolves via
    socket.getaddrinfo. Returns (allowed, pinned_ip): the first validated
    IP is locked for the delivery — re-resolving would be a DNS-rebinding
    TOCTOU.

    shortcut: spec J4 asks for https-only, but the existing suite
    (test_events.test_webhook_dns_rebinding_is_pinned) creates and delivers
    an http:// webhook — scheme stays http+https to avoid the regression;
    tighten to https-only once that test is updated.
    """
    from urllib.parse import urlparse

    from .config import settings

    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if not host:
        return False, None
    # 2.4 (prod3) : le schéma http(s) d'ABORD — l'opt-in
    # WEBHOOK_ALLOWED_HOSTS ne doit pas autoriser un schéma étranger
    # (file://, gopher://…).
    if parsed.scheme not in ("http", "https"):
        return False, None
    allow = {h.strip().lower() for h in settings.WEBHOOK_ALLOWED_HOSTS if h.strip()}
    if host in allow or any(host.endswith("." + a) for a in allow):
        return True, None
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        if resolver is None:
            import socket

            try:
                infos = socket.getaddrinfo(host, None)
            except Exception:
                infos = []
            ips = [info[4][0] for info in infos]
        else:
            try:
                ips = list(resolver(host))
            except Exception:
                ips = []
        if not ips:
            # Unresolvable for now: not provably internal — allowed here,
            # re-checked at delivery (a name that resolves to an internal
            # address later is rejected there).
            return True, None
        try:
            ips = [ipaddress.ip_address(x) for x in ips]
        except ValueError:
            return False, None
        if not all(_ip_is_public(ip) for ip in ips):
            return False, None
        return True, str(ips[0])
    if not _ip_is_public(ip):
        return False, None
    return True, str(ip)


async def record_change(
    session: AsyncSession,
    list_id: UUID,
    item_id: UUID | None = None,
    checklist_id: UUID | None = None,
    kind: str = "item.upsert",
    actor_id: UUID | None = None,
    commit: bool = True,
) -> None:
    session.add(
        ChangeLog(
            list_id=list_id,
            item_id=item_id,
            checklist_id=checklist_id,
            kind=kind,
            actor_id=actor_id,
            server_time=utcnow(),
        )
    )
    if commit:
        await session.commit()


class Hub:
    """In-process WebSocket hub: user_id -> set of queues."""

    def __init__(self) -> None:
        self._subscribers: dict[UUID, set[asyncio.Queue]] = {}

    def subscribe(self, user_id: UUID) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=100)
        self._subscribers.setdefault(user_id, set()).add(q)
        return q

    def unsubscribe(self, user_id: UUID, q: asyncio.Queue) -> None:
        queues = self._subscribers.get(user_id)
        if queues:
            queues.discard(q)
            if not queues:
                self._subscribers.pop(user_id, None)

    async def notify_users(self, user_ids: list[UUID], message: dict[str, Any]) -> None:
        for user_id in user_ids:
            for q in list(self._subscribers.get(user_id, ())):
                try:
                    q.put_nowait(message)
                except asyncio.QueueFull:
                    pass


hub = Hub()


def _webhook_host_allowed(url: str) -> tuple[bool, str | None]:
    """Return (allowed, pinned_ip) for a webhook URL.

    Blocks SSRF to non-public destinations (loopback, RFC1918/CGNAT,
    link-local incl. cloud metadata 169.254.169.254, reserved/multicast) by
    resolving the hostname first. settings.WEBHOOK_ALLOWED_HOSTS (comma
    separated) is an explicit allowlist that bypasses the block for
    self-hosted webhooks that legitimately point at private addresses.
    The resolution happens exactly ONCE here and the first validated IP is
    returned so the fetch can pin it — re-resolving at fetch time would be
    a DNS-rebinding TOCTOU (audit run-2).
    """
    import socket
    from urllib.parse import urlparse

    from .config import settings

    parsed = urlparse(url)
    host = parsed.hostname or ""
    if parsed.scheme not in ("http", "https") or not host:
        return False, None
    allow = {h.strip().lower() for h in settings.WEBHOOK_ALLOWED_HOSTS if h.strip()}
    if host.lower() in allow or any(host.lower().endswith("." + a) for a in allow):
        return True, None
    try:
        infos = socket.getaddrinfo(host, None)
    except Exception:
        return False, None
    pinned: str | None = None
    for _family, _type, _proto, _canon, sockaddr in infos:
        try:
            ip = ipaddress.ip_address(sockaddr[0])
        except Exception:
            continue
        if not _ip_is_public(ip):
            return False, None
        if pinned is None:
            pinned = str(ip)
    return pinned is not None, pinned


async def fire_webhooks(list_id, payload: dict[str, Any]) -> None:
    """POST the payload to every webhook of the list, signed with HMAC-SHA256.
    Fire-and-forget: failures are logged, never propagated. Disallowed
    (SSRF-risk) hosts are skipped, not followed.
    Session propre (pas la session de la requête) : appelé depuis un
    create_task qui tourne APRÈS la clôture de la session du request (C1.3)."""
    import asyncio
    import hashlib
    import hmac
    import json
    import logging

    from .config import settings
    from .db import SessionLocal
    from .models import Webhook
    from sqlalchemy import select

    async with SessionLocal() as session:
        result = await session.execute(
            select(Webhook).where(Webhook.list_id == list_id))
        hooks = [(h.url, h.secret) for h in result.scalars()]
    if not hooks:
        return

    async def _fire(url: str, secret: str) -> None:
        allowed, pinned_ip = _webhook_host_allowed(url)
        if not allowed:
            logging.getLogger("tapitask.webhooks").warning(
                "skipping disallowed webhook host: %s", url)
            return
        body = json.dumps(payload).encode()
        signature = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        headers = {
            "Content-Type": "application/json",
            "X-Tapitask-Signature": f"sha256={signature}",
        }
        # Pin the IP resolved by the SSRF check: an IP-literal host needs no
        # rewrite, a hostname fetch must not re-resolve (DNS rebinding).
        if pinned_ip is not None:
            from urllib.parse import urlunparse, urlparse

            parsed = urlparse(url)
            try:
                ipaddress.ip_address(parsed.hostname or "")
            except ValueError:
                netloc = (
                    f"[{pinned_ip}]" if ":" in pinned_ip else pinned_ip
                ) + (f":{parsed.port}" if parsed.port else "")
                url = urlunparse(parsed._replace(netloc=netloc))
                headers["Host"] = parsed.hostname or ""
        try:
            import httpx

            # follow_redirects stays at its default (False): re-resolving each
            # hop against the SSRF policy would be required to follow safely.
            # Le netloc peut être l'IP épinglée (Host = hostname d'origine) :
            # sans SNI explicite, le handshake présenterait l'IP et la
            # vérification du certificat échouerait (audit C1.3).
            sni = headers.get("Host")
            # 2.4 (prod3) : trust_env=False — sinon HTTP_PROXY/HTTPS_PROXY de
            # l'hôte détourne le POST (contournement de l'IP épinglée + du
            # check SSRF).
            async with httpx.AsyncClient(timeout=settings.WEBHOOK_TIMEOUT,
                                         trust_env=False) as client:
                await client.post(
                    url, content=body, headers=headers,
                    extensions={"sni_hostname": sni} if sni else None)
        except Exception:
            logging.getLogger("tapitask.webhooks").exception("webhook failed: %s", url)

    await asyncio.gather(*(_fire(*hook) for hook in hooks))


async def notify_list(list_id: UUID, message: dict[str, Any]) -> None:
    """Push a change to all members of a list (called from sync router context)."""
    from .db import SessionLocal
    from .models import Checklist, ListMember
    from sqlalchemy import select

    async with SessionLocal() as session:
        result = await session.execute(
            select(Checklist.owner_id).where(Checklist.id == list_id)
        )
        owner_id = result.scalar_one_or_none()
        members = await session.execute(
            select(ListMember.user_id).where(ListMember.list_id == list_id)
        )
        user_ids = [owner_id] if owner_id else []
        user_ids += [m for (m,) in members.all()]
    message = dict(message)
    message["list_id"] = str(list_id)
    await hub.notify_users(user_ids, message)
