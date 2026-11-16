"""docker-compose API exposure: the plaintext API must bind to loopback by
default (audit run-2, tapitask.compose.plaintext_api_all_profiles).
"""
from __future__ import annotations

import os
import shutil
import subprocess

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _compose_config(api_bind: str | None) -> dict:
    env = dict(os.environ)
    # hermetic: never read values from the repo's .env
    env.update({"DB_PASSWORD": "x" * 20, "JWT_SECRET": "a" * 40,
                "API_PORT": "8000", "API_BIND": api_bind or ""})
    if not api_bind:
        env.pop("API_BIND")
    r = subprocess.run(
        ["docker", "compose", "config", "--format", "json"],
        cwd=REPO_ROOT, env=env, capture_output=True, text=True,
    )
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
