from __future__ import annotations

import asyncio
import logging
import smtplib
from email.message import EmailMessage

from .config import settings

logger = logging.getLogger("tapitask.mail")


def _sync_send(to: str, subject: str, body: str) -> None:
    if not settings.SMTP_ENABLED or not settings.SMTP_HOST:
        logger.info("SMTP disabled: skip email to %s (%s)", to, subject)
        return
    msg = EmailMessage()
    msg["From"] = settings.SMTP_FROM
    msg["To"] = to
    msg["Subject"] = subject
    msg.set_content(body)
    try:
        if settings.SMTP_PORT == 465:
            # Implicit TLS (SMTPS): the session is SSL from the very first
            # byte — STARTTLS is wrong here and fails on most servers.
            with smtplib.SMTP_SSL(
                settings.SMTP_HOST, settings.SMTP_PORT, timeout=10
            ) as server:
                if settings.SMTP_USER:
                    server.login(settings.SMTP_USER, settings.SMTP_PASSWORD)
                server.send_message(msg)
        else:
            with smtplib.SMTP(
                settings.SMTP_HOST, settings.SMTP_PORT, timeout=10
            ) as server:
                if settings.SMTP_PORT == 587:
                    server.starttls()
                if settings.SMTP_USER:
                    server.login(settings.SMTP_USER, settings.SMTP_PASSWORD)
                server.send_message(msg)
        logger.info("Email sent to %s (%s)", to, subject)
    except Exception:
        logger.exception("Email to %s failed", to)


async def send_email(to: str, subject: str, body: str) -> None:
    """Best-effort async send; failures are logged, never blocking."""
    await asyncio.to_thread(_sync_send, to, subject, body)


def user_wants_email(settings_json: str | None) -> bool:
    """Per-user notification preference (default: email enabled)."""
    import json

    try:
        data = json.loads(settings_json) if settings_json else {}
    except Exception:
        return True
    return data.get("notify_email", True) is True
