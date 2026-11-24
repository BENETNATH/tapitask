from __future__ import annotations

import os


class Settings:
    DATABASE_URL: str = os.environ.get(
        "DATABASE_URL",
        "postgresql+asyncpg://checklists:checklists@localhost:5432/checklists",
    )
    JWT_SECRET: str = os.environ.get("JWT_SECRET", "")
    ACCESS_TOKEN_TTL: int = int(os.environ.get("ACCESS_TOKEN_TTL", "900"))
    REFRESH_TOKEN_TTL: int = int(os.environ.get("REFRESH_TOKEN_TTL", str(60 * 60 * 24 * 30)))
    CORS_ORIGINS: list[str] = os.environ.get("CORS_ORIGINS", "http://localhost:8080").split(",")
    RATE_LIMIT_PER_MINUTE: int = int(os.environ.get("RATE_LIMIT_PER_MINUTE", "20"))
    # Rate limit par principal sur les canaux écriture lourds (/sync, bulk
    # items, MCP messages) (audit lot T).
    PRINCIPAL_RATE_LIMIT_PER_MINUTE: int = int(
        os.environ.get("PRINCIPAL_RATE_LIMIT_PER_MINUTE", "300"))
    ADMIN_EMAIL: str = os.environ.get("ADMIN_EMAIL", "")
    ADMIN_PASSWORD: str = os.environ.get("ADMIN_PASSWORD", "")

    # --- Email verification (optional) ---
    SMTP_ENABLED: bool = os.environ.get("SMTP_ENABLED", "0") == "1"
    SMTP_HOST: str = os.environ.get("SMTP_HOST", "")
    SMTP_PORT: int = int(os.environ.get("SMTP_PORT", "587"))
    SMTP_USER: str = os.environ.get("SMTP_USER", "")
    SMTP_PASSWORD: str = os.environ.get("SMTP_PASSWORD", "")
    SMTP_FROM: str = os.environ.get("SMTP_FROM", "tapitask@localhost")

    # --- Realtime ---
    WS_PING_INTERVAL: float = float(os.environ.get("WS_PING_INTERVAL", "30.0"))

    # --- Rate limiting (optional Redis) ---
    REDIS_URL: str = os.environ.get("REDIS_URL", "")
    # Comma-separated list of trusted reverse-proxy IPs. Only when the direct
    # peer is one of these is X-Forwarded-For trusted for rate-limit keys;
    # otherwise the rate-limit/lockout key falls back to the direct peer IP so
    # a client cannot rotate a forged XFF header to defeat brute-force limits.
    TRUSTED_PROXIES: list[str] = os.environ.get("TRUSTED_PROXIES", "").split(",")

    # --- Webhooks ---
    WEBHOOK_TIMEOUT: int = int(os.environ.get("WEBHOOK_TIMEOUT", "5"))
    # Optional explicit allowlist of webhook hostnames (comma separated, may use
    # a leading dot for subdomains, e.g. "hooks.example.com" or ".example.com").
    # Hosts in this list bypass the SSRF block (loopback/private/metadata) so
    # self-hosted webhooks can point at private addresses when intended.
    WEBHOOK_ALLOWED_HOSTS: list[str] = os.environ.get("WEBHOOK_ALLOWED_HOSTS", "").split(",")
    # Plafond de webhooks par liste (audit lot T) : borne le gather de
    # fire_webhooks contre l'amplification DoS.
    WEBHOOKS_MAX_PER_LIST: int = int(os.environ.get("WEBHOOKS_MAX_PER_LIST", "10"))


settings = Settings()

if not settings.JWT_SECRET:
    raise RuntimeError("JWT_SECRET environment variable must be set")

# RFC 7518 §3.2: HMAC-SHA256 keys should be at least 32 bytes. Production
# secrets shorter than that are rejected; the exception is the orthogonal
# TEST_ENV marker (exact value "1") — never the secret's content.
if len(settings.JWT_SECRET) < 32 and os.environ.get("TEST_ENV") != "1":
    raise RuntimeError(
        "JWT_SECRET trop court (< 32 octets) — générez un secret solide : "
        'python3 -c "import secrets; print(secrets.token_urlsafe(48))"'
    )
