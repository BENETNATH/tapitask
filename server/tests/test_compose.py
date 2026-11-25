"""docker-compose API exposure: the plaintext API must bind to loopback by
default (audit run-2, tapitask.compose.plaintext_api_all_profiles).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _compose_config(api_bind: str | None) -> dict:
    # hermetic: never read values from the repo's .env — docker compose
    # auto-loads it, so point it at a temp env file instead.
    env_file = tempfile.NamedTemporaryFile("w", suffix=".env", delete=False)
    env_file.write("DB_PASSWORD=xxxxxx" + "x" * 14 + "\n")
    env_file.write("JWT_SECRET=" + "a" * 40 + "\n")
    env_file.write("API_PORT=8000\n")
    if api_bind:
        env_file.write(f"API_BIND={api_bind}\n")
    env_file.close()
    try:
        # --profile pg : le service db est sous ce profile (spec 2026-11-25,
        # D-1) ; sans lui, `api` dépend d'un service hors profile et
        # `config` échoue.
        r = subprocess.run(
            [
                "docker",
                "compose",
                "--env-file",
                env_file.name,
                "-f",
                "docker-compose.yml",
                "--profile",
                "pg",
                "config",
                "--format",
                "json",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
    finally:
        os.unlink(env_file.name)
    assert r.returncode == 0, r.stderr
    import json

    return json.loads(r.stdout)


def _api_port_entry(ports: list) -> dict:
    entry = [p for p in ports if p.get("target") == 8000]
    assert len(entry) == 1, ports
    return entry[0]


def test_api_port_binds_loopback_by_default():
    if shutil.which("docker") is None:
        import pytest

        pytest.skip("docker not available")
    config = _compose_config(None)
    port = _api_port_entry(config["services"]["api"]["ports"])
    # default: 127.0.0.1:8000:8000
    assert port["host_ip"] == "127.0.0.1" and port["published"] == "8000", port


def test_api_port_can_bind_all_interfaces_explicitly():
    if shutil.which("docker") is None:
        import pytest

        pytest.skip("docker not available")
    config = _compose_config("0.0.0.0")
    port = _api_port_entry(config["services"]["api"]["ports"])
    # explicit: 0.0.0.0:8000:8000
    assert port["host_ip"] == "0.0.0.0" and port["published"] == "8000", port


def test_db_service_is_under_pg_profile():
    """D-1 : le service db est sous profiles ['pg'] (mode SQLite =
    docker-compose.sqlite.yml, sans service de base)."""
    import yaml

    with open(os.path.join(REPO_ROOT, "docker-compose.yml"), encoding="utf-8") as f:
        compose = yaml.safe_load(f)
    assert compose["services"]["db"].get("profiles") == ["pg"]


def test_sqlite_compose_has_no_db_and_persists_data():
    """D-2 : docker-compose.sqlite.yml — pas de service db ni de
    depends_on, DATABASE_URL sqlite fichier sur le volume nommé data."""
    import yaml

    with open(
        os.path.join(REPO_ROOT, "docker-compose.sqlite.yml"), encoding="utf-8"
    ) as f:
        compose = yaml.safe_load(f)
    services = compose["services"]
    assert "db" not in services
    assert "depends_on" not in services["api"]
    assert services["api"]["environment"]["DATABASE_URL"].startswith(
        "sqlite+aiosqlite://"
    )
    assert "data:/data" in services["api"]["volumes"]
    assert "data" in compose["volumes"]
    # Même exposition loopback par défaut que le mode PG.
    ports = [str(p) for p in services["api"]["ports"]]
    assert any(
        p.startswith("${API_BIND:-127.0.0.1}:${API_PORT:-8000}") and p.endswith(":8000")
        for p in ports
    ), ports
