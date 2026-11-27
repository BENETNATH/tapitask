"""JWT_SECRET length guard, tested in a subprocess: the guard runs at import.

The production exception path is controlled by the orthogonal TEST_ENV marker
(exact value "1"), never by the secret's content (audit run-2,
tapitask.config.jwt_secret.test_prefix_bypass).
"""

from __future__ import annotations

import os
import subprocess
import sys

SERVER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _import_config(extra_env: dict[str, str]) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in ("JWT_SECRET", "TEST_ENV")}
    env.update(extra_env)
    env["PYTHONPATH"] = SERVER_DIR
    return subprocess.run(
        [sys.executable, "-c", "import app.config"],
        cwd=SERVER_DIR,
        env=env,
        capture_output=True,
        text=True,
    )


def test_short_secret_rejected_without_test_env():
    r = _import_config({"JWT_SECRET": "short-secret"})
    assert r.returncode != 0
    assert "RuntimeError" in r.stderr


def test_short_secret_accepted_with_test_env():
    r = _import_config({"JWT_SECRET": "short-secret", "TEST_ENV": "1"})
    assert r.returncode == 0, r.stderr


def test_test_prefix_alone_is_not_a_bypass():
    # regression: "test-abc" (7 chars of payload) must be rejected in prod
    r = _import_config({"JWT_SECRET": "test-abc"})
    assert r.returncode != 0
    assert "RuntimeError" in r.stderr


def test_32_byte_secret_accepted_without_test_env():
    r = _import_config({"JWT_SECRET": "a" * 32})
    assert r.returncode == 0, r.stderr


def test_webhook_allowed_hosts_default_empty_list():
    """WEBHOOK_ALLOWED_HOSTS passe par _parse_csv comme CORS_ORIGINS /
    TRUSTED_PROXIES — défaut (env absente) → [] (pas [''])."""
    env = {
        k: v
        for k, v in os.environ.items()
        if k not in ("JWT_SECRET", "TEST_ENV", "WEBHOOK_ALLOWED_HOSTS")
    }
    env.update({"JWT_SECRET": "a" * 32})
    env["PYTHONPATH"] = SERVER_DIR
    r = subprocess.run(
        [
            sys.executable,
            "-c",
            "import app.config as c; print(c.settings.WEBHOOK_ALLOWED_HOSTS)",
        ],
        cwd=SERVER_DIR,
        env=env,
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "[]", r.stdout


def test_cors_origins_csv_stripped():
    """M4 (prod4) : CORS_ORIGINS passe par _parse_csv — "a, b" → ["a", "b"]
    (espaces stripés, vides écartés), pas ["a", " b"]."""
    env = {k: v for k, v in os.environ.items() if k not in ("JWT_SECRET", "TEST_ENV")}
    env.update(
        {"JWT_SECRET": "a" * 32, "CORS_ORIGINS": "http://a.com, http://b.com,  "}
    )
    env["PYTHONPATH"] = SERVER_DIR
    r = subprocess.run(
        [
            sys.executable,
            "-c",
            "import app.config as c; print(c.settings.CORS_ORIGINS)",
        ],
        cwd=SERVER_DIR,
        env=env,
        capture_output=True,
        text=True,
    )
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "['http://a.com', 'http://b.com']", r.stdout
