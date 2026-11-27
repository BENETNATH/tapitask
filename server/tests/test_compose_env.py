"""docker-compose C1.4 : les variables lues par server/app/config.py mais
absentes de l'environment du service api sont passées en ${VAR:-default}
(sinon les réglages runtime de prod (rate-limit, WS ping, SSRF allowlist…)
restent bloqués aux valeurs par défaut du code)."""

from __future__ import annotations

import os

import yaml

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

REQUIRED = [
    "TRUSTED_PROXIES",
    "WEBHOOK_ALLOWED_HOSTS",
    "WS_PING_INTERVAL",
    "WEBHOOKS_MAX_PER_LIST",
    "PRINCIPAL_RATE_LIMIT_PER_MINUTE",
    "RATE_LIMIT_PER_MINUTE",
]


def _api_environment() -> dict:
    with open(os.path.join(REPO_ROOT, "docker-compose.yml"), encoding="utf-8") as f:
        compose = yaml.safe_load(f)
    return compose["services"]["api"]["environment"]


def test_api_environment_passes_all_config_variables():
    env = _api_environment()
    for var in REQUIRED:
        assert var in env, f"{var} absent de api.environment"
        # Format ${VAR:-default} : le default du code doit être préservé
        # (aucune valeur par défaut n'est changée — spec hors périmètre).
        assert env[var].startswith(f"${{{var}:-"), env[var]


def test_defaults_match_config():
    env = _api_environment()
    # Les valeurs extraitées du ${VAR:-default} : défauts de config.py.
    defaults = {
        "TRUSTED_PROXIES": "",
        "WEBHOOK_ALLOWED_HOSTS": "",
        "WS_PING_INTERVAL": "30.0",
        "WEBHOOKS_MAX_PER_LIST": "10",
        "PRINCIPAL_RATE_LIMIT_PER_MINUTE": "300",
        "RATE_LIMIT_PER_MINUTE": "20",
    }
    for var, dflt in defaults.items():
        value = env[var]
        inner = value[len(f"${{{var}:-") :]
        assert inner.rstrip("}") == dflt, (var, value, dflt)
