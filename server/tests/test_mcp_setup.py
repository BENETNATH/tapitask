"""mcp_setup.py (key onboarding / rotation) and mcp_server.py's key file, all
against a fake in-memory API: no real key is created, and nothing outside the
pytest tmp directory is read or written."""

from __future__ import annotations

import io
import json
import os
import sys

import mcp_server
import mcp_setup
import pytest

from .fake_api import FakeApi

posix_only = pytest.mark.skipif(os.name == "nt", reason="POSIX file modes")

L_GROC = "11111111-1111-1111-1111-111111111111"
L_WORK = "22222222-2222-2222-2222-222222222222"
L_VIEW = "33333333-3333-3333-3333-333333333333"
PASSWORD = "correct-horse"


@pytest.fixture
def api(monkeypatch):
    monkeypatch.setenv("NO_PROXY", "127.0.0.1,localhost")
    monkeypatch.setenv("no_proxy", "127.0.0.1,localhost")
    fake = FakeApi(password=PASSWORD).start()
    yield fake
    fake.stop()


@pytest.fixture
def cfg(tmp_path, monkeypatch):
    """XDG_CONFIG_HOME inside tmp: the default key directory lives there."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    return tmp_path / "xdg" / "tapitask"


class Script:
    """Feeds scripted answers; EOF when exhausted. Records the prompts."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.prompts: list[str] = []

    def __call__(self, prompt=""):
        self.prompts.append(prompt)
        if not self.answers:
            raise EOFError
        return self.answers.pop(0)


def run(api, argv, answers=(), secrets=(PASSWORD,)):
    out, err = io.StringIO(), io.StringIO()
    inp, sec = Script(answers), Script(secrets)
    con = mcp_setup.Console(input_fn=inp, secret_fn=sec, out=out, err=err)
    code = mcp_setup.main(["--url", api.url, "--email", "me@example.com", *argv], con)
    return code, out.getvalue(), err.getvalue(), inp, sec


def stored_key(path):
    return open(path, encoding="utf-8").read().strip()


def assert_no_secret_leak(api, *texts, extra=()):
    """No password, token or key value in anything that was printed/prompted."""
    secrets_ = {
        PASSWORD,
        *extra,
        *(k["raw"] for k in api.keys.values()),
        *(t for t in api.tokens),
    }
    for text in texts:
        for s in secrets_:
            assert s not in text, "a secret leaked into the output"


# ------------------------------------------------------------------ setup --


def test_setup_one_list_read_only_default(api, cfg):
    # list 1 (Groceries), Enter = read-only default, Enter = default name
    code, out, err, inp, sec = run(api, ["setup"], ["1", "", ""])
    assert code == 0, err
    ((kid, rec),) = api.active_keys().items()
    assert rec["read_only"] is True and rec["list_scope"] == L_GROC
    path = cfg / f"{mcp_setup.slug(rec['name'])}.key"
    assert stored_key(path) == rec["raw"]
    # printed: the stdio command + the key FILE path, never the key
    assert "mcp_server.py" in out
    assert f"command: {json.dumps(sys.executable)}" in out
    assert (
        f"args: {json.dumps([os.path.abspath(mcp_setup.__file__.replace('mcp_setup.py', 'mcp_server.py'))])}"
        in out
    )
    assert f"CHECKLISTS_API_KEY_FILE={path}" in out
    assert f"CHECKLISTS_URL={api.url}" in out
    assert_no_secret_leak(api, out, err, *inp.prompts, *sec.prompts)
    # the password was asked through the secret channel only
    assert sec.prompts == ["Tapitask password: "]
    assert not any("password" in p.lower() for p in inp.prompts)


@posix_only
def test_setup_file_modes_0600_in_0700_dir(api, cfg):
    code, *_ = run(api, ["setup"], ["1", "", ""])
    assert code == 0
    (path,) = list(cfg.glob("*.key"))
    assert oct(path.stat().st_mode & 0o777) == "0o600"
    assert oct(cfg.stat().st_mode & 0o777) == "0o700"
    assert not list(cfg.glob("*.tmp"))


@posix_only
def test_setup_tightens_existing_default_dir_but_refuses_loose_custom_dir(
    api, cfg, tmp_path
):
    cfg.mkdir(parents=True)
    os.chmod(cfg, 0o755)
    code, _, err, *_ = run(api, ["setup"], ["1", "", ""])
    assert code == 0 and oct(cfg.stat().st_mode & 0o777) == "0o700"
    assert "tightened" in err
    loose = tmp_path / "loose"
    loose.mkdir()
    os.chmod(loose, 0o755)
    before = len(api.keys)
    code, _, err, *_ = run(
        api, ["setup", "--key-file", str(loose / "k.key")], ["1", "", ""]
    )
    assert code == 1 and "0700" in err
    assert len(api.keys) == before  # refused BEFORE minting a key


@pytest.mark.parametrize(
    "answer,read_only",
    [
        ("", True),
        ("w", True),
        ("yes", True),
        ("read", True),
        ("write", False),
        ("WRITE", False),
    ],
)
def test_write_access_needs_explicit_choice(api, cfg, answer, read_only):
    code, _, err, *_ = run(api, ["setup"], ["2", answer, ""])
    assert code == 0, err
    (rec,) = api.active_keys().values()
    assert rec["read_only"] is read_only and rec["list_scope"] == L_WORK


def test_setup_all_lists(api, cfg):
    code, out, err, *_ = run(api, ["setup"], ["a", "", "everything"])
    assert code == 0, err
    rec = api.key_by_name("everything")
    assert rec["list_scope"] is None and rec["read_only"] is True
    assert "future" in err  # all-lists warning
    assert (cfg / "everything.key").exists()


def test_setup_viewer_write_warns(api, cfg):
    code, _, err, *_ = run(api, ["setup"], ["3", "write", ""])
    assert code == 0 and "viewer" in err


def test_setup_noninteractive_flags(api, tmp_path):
    f = tmp_path / "keys" / "k.key"
    code, out, err, *_ = run(
        api,
        [
            "setup",
            "--list",
            L_WORK,
            "--access",
            "read",
            "--name",
            "ci",
            "--key-file",
            str(f),
        ],
    )
    assert code == 0, err
    rec = api.key_by_name("ci")
    assert rec["list_scope"] == L_WORK and stored_key(f) == rec["raw"]
    code, _, err, *_ = run(api, ["setup", "--list", "nope", "--name", "x"])
    assert code == 1 and "not one of your accessible lists" in err


def test_setup_refuses_to_overwrite_and_mints_nothing(api, cfg, tmp_path):
    f = tmp_path / "k.key"
    f.write_text("chk_existing\n")
    code, _, err, *_ = run(
        api,
        [
            "setup",
            "--list",
            "all",
            "--access",
            "read",
            "--name",
            "n",
            "--key-file",
            str(f),
        ],
    )
    assert code == 1 and "already exists" in err
    assert api.keys == {} and f.read_text() == "chk_existing\n"


def test_setup_wrong_password(api, cfg):
    code, out, err, inp, sec = run(api, ["setup"], ["1"], secrets=("wrong-password",))
    assert code == 1 and "invalid credentials" in err
    assert api.keys == {}
    assert_no_secret_leak(api, out, err, extra=("wrong-password",))


def test_setup_2fa_prompted_only_when_required(api, cfg):
    api.totp = "123456"
    code, out, err, inp, sec = run(
        api, ["setup"], ["1", "", ""], secrets=(PASSWORD, "123456")
    )
    assert code == 0, err
    assert sec.prompts == ["Tapitask password: ", "2FA code: "]
    assert api.login_bodies[-1]["totp_code"] == "123456"
    assert_no_secret_leak(api, out, err, extra=("123456",))


def test_setup_2fa_rejected(api, cfg):
    api.totp = "123456"
    code, _, err, *_ = run(
        api, ["setup"], ["1"], secrets=(PASSWORD, "000000", "000001", "000002")
    )
    assert code == 1 and "2FA" in err and api.keys == {}


def test_http_to_remote_host_refused_and_redirect_not_followed(api, cfg):
    with pytest.raises(mcp_setup.SetupError, match="plain http"):
        mcp_setup.check_url("http://tapitask.example.com", False)
    assert (
        mcp_setup.check_url("https://tapitask.example.com/", False)
        == "https://tapitask.example.com"
    )
    assert mcp_setup.check_url("http://localhost:8000", False)
    assert mcp_setup.check_url("http://[::1]:8000", False)
    assert mcp_setup.check_url("http://tapitask.example.com", True)
    api.redirect_login = True
    code, _, err, *_ = run(api, ["setup"], ["1"])
    assert code == 1 and "redirect" in err
    assert len(api.login_bodies) == 1 and api.keys == {}


def test_verification_failure_is_reported_and_never_revokes(api, cfg):
    api.leak_all_lists_to_scoped_keys = True  # server bug: scope ignored
    code, out, err, *_ = run(api, ["setup"], ["1", "", ""])
    assert code == 1 and "verification failed" in err
    assert "MCP client configuration" not in out  # no "all good" instructions
    assert api.calls("DELETE") == []
    assert_no_secret_leak(api, out, err)


def test_verification_catches_writable_readonly_key(api, cfg):
    api.writable_readonly_keys = True
    code, _, err, *_ = run(api, ["setup"], ["1", "", ""])
    assert code == 1 and "expected 403" in err


def test_all_lists_key_verified_against_account_lists(api, cfg):
    code, *_ = run(
        api, ["setup", "--list", "all", "--access", "read", "--name", "all-ro"]
    )
    assert code == 0
    # verification used the new key: GET /lists + a read + the (refused) write probe
    key_calls = [c for c in api.requests if c[2] == "key"]
    assert [c[:2] for c in key_calls] == [
        ("GET", "/lists"),
        ("GET", f"/lists/{sorted(api.lists)[0]}/items"),
        ("POST", "/lists"),
    ]


# ----------------------------------------------------------------- rotate --


def _setup_key(api, name="agent", scope=L_GROC, access="read"):
    code, *_ = run(api, ["setup", "--list", scope, "--access", access, "--name", name])
    assert code == 0
    return api.key_by_name(name)


def test_rotate_creates_and_verifies_before_asking_to_revoke(api, cfg):
    old = _setup_key(api)
    f = cfg / "agent.key"
    api.requests.clear()
    code, out, err, inp, _ = run(
        api, ["rotate", "--key-file", str(f), "--name", "new"], answers=["n"]
    )
    assert code == 0, err
    new = next(k for k in api.keys.values() if k["id"] != old["id"])
    assert stored_key(f) == new["raw"] != old["raw"]
    # same access as the old key; never wider
    assert new["read_only"] is True and new["list_scope"] == L_GROC
    # the old key is untouched until the user says yes
    assert not old["revoked"] and api.calls("DELETE") == []
    assert any("Revoke it now?" in p for p in inp.prompts)
    # order: replacement was created, then exercised with its own key
    verbs = [(m, p, who) for m, p, who in api.requests]
    assert verbs.index(("POST", "/api-keys", "jwt")) < verbs.index(
        ("GET", "/lists", "key")
    )
    assert not os.path.exists(f"{f}.new")
    assert "python mcp_setup.py revoke" in out
    assert_no_secret_leak(api, out, err, *inp.prompts)


def test_rotate_revokes_old_only_after_explicit_yes(api, cfg):
    old = _setup_key(api)
    f = cfg / "agent.key"
    code, out, *_ = run(
        api, ["rotate", "--key-file", str(f), "--name", "new"], answers=["yes"]
    )
    assert code == 0 and old["revoked"] is True
    assert [c[:2] for c in api.calls("DELETE")] == [
        ("DELETE", f"/api-keys/{old['id']}")
    ]
    # the other (new) key is still active and is what the file holds
    (new,) = api.active_keys().values()
    assert stored_key(f) == new["raw"]


@pytest.mark.parametrize("answers", [[], [""], ["no"], ["nope"], ["Y!"]])
def test_rotate_default_and_eof_do_not_revoke(api, cfg, answers):
    old = _setup_key(api)
    code, *_ = run(
        api,
        ["rotate", "--key-file", str(cfg / "agent.key"), "--name", "new"],
        answers=answers,
    )
    assert code == 0 and not old["revoked"] and api.calls("DELETE") == []


def test_rotate_failed_verification_keeps_old_file_and_revokes_nothing(api, cfg):
    old = _setup_key(api)
    f = cfg / "agent.key"
    before = stored_key(f)
    api.leak_all_lists_to_scoped_keys = True
    code, out, err, *_ = run(
        api, ["rotate", "--key-file", str(f), "--name", "new"], answers=["yes"]
    )
    assert code == 1 and "verification failed" in err and "OLD key" in err
    assert stored_key(f) == before and not os.path.exists(f"{f}.new")
    assert not old["revoked"] and api.calls("DELETE") == []  # even with a 'yes' queued
    assert_no_secret_leak(api, out, err)


def test_rotate_preserves_write_access_and_scope(api, cfg):
    old = _setup_key(api, name="rw-work", scope=L_WORK, access="write")
    code, *_ = run(
        api, ["rotate", "--key-file", str(cfg / "rw-work.key")], answers=["", "n"]
    )
    assert code == 0
    new = next(k for k in api.keys.values() if k["id"] != old["id"])
    assert new["read_only"] is False and new["list_scope"] == L_WORK
    assert new["name"].startswith("rw-work-rotated-")


def test_rotate_unknown_current_key_offers_choice_and_can_skip_revocation(api, cfg):
    _setup_key(api)
    f = cfg / "agent.key"
    f.write_text("chk_notarealkeyvalue\n")  # matches no active key
    code, out, err, *_ = run(
        api, ["rotate", "--key-file", str(f), "--name", "new"], answers=["0", "1", ""]
    )
    assert code == 0 and "nothing to revoke" in out
    assert api.calls("DELETE") == []


def test_rotate_works_when_server_omits_scope_field(api, cfg):
    _setup_key(api)
    api.omit_list_scope_in_listing = True  # older server
    code, _, err, *_ = run(
        api,
        ["rotate", "--key-file", str(cfg / "agent.key")],
        answers=["1", "", "", "n"],
    )  # re-choose list 1, read-only, default name, no revoke
    assert code == 0 and "does not report" in err


# ----------------------------------------------------------------- revoke --


def test_revoke_needs_confirmation(api, cfg):
    old = _setup_key(api)
    code, *_ = run(api, ["revoke"], answers=["1", "n"])
    assert code == 0 and not old["revoked"]
    code, *_ = run(api, ["revoke"], answers=["1", "y"])
    assert code == 0 and old["revoked"]


# ------------------------------------------------------- mcp_server.py key --


def _server_call(api, monkeypatch, **attrs):
    monkeypatch.setattr(mcp_server, "URL", api.url)
    for k, v in attrs.items():
        monkeypatch.setattr(mcp_server, k, v)
    return mcp_server._api("GET", "/lists")


def test_mcp_server_reads_key_file_on_every_request(api, cfg, monkeypatch):
    rec = _setup_key(api)
    f = str(cfg / "agent.key")
    assert _server_call(api, monkeypatch, KEY_FILE=f, KEY="")  # authenticates
    # rotate underneath the running server: next request uses the new key, no restart
    run(api, ["rotate", "--key-file", f, "--name", "new"], answers=["yes"])
    assert rec["revoked"]
    assert _server_call(api, monkeypatch, KEY_FILE=f, KEY="")


def test_mcp_server_key_file_wins_over_env_and_env_still_works(
    api, cfg, monkeypatch, tmp_path
):
    rec = _setup_key(api)
    f = tmp_path / "k"
    f.write_text(rec["raw"] + "\n")
    monkeypatch.setattr(mcp_server, "KEY_FILE", str(f))
    monkeypatch.setattr(mcp_server, "KEY", "chk_stale")
    assert mcp_server._load_key() == rec["raw"]
    monkeypatch.setattr(mcp_server, "KEY_FILE", "")
    assert mcp_server._load_key() == "chk_stale"


def test_mcp_server_key_file_errors_do_not_echo_content(monkeypatch, tmp_path):
    f = tmp_path / "k"
    f.write_text("  \n")
    monkeypatch.setattr(mcp_server, "KEY_FILE", str(f))
    with pytest.raises(RuntimeError, match="empty"):
        mcp_server._load_key()
    monkeypatch.setattr(mcp_server, "KEY_FILE", str(tmp_path / "missing"))
    with pytest.raises(RuntimeError, match="cannot read"):
        mcp_server._load_key()


def test_mcp_server_main_fails_fast_without_key(monkeypatch, capsys):
    monkeypatch.setattr(mcp_server, "KEY_FILE", "")
    monkeypatch.setattr(mcp_server, "KEY", "")
    with pytest.raises(SystemExit) as e:
        mcp_server.main()
    assert e.value.code == 1 and "CHECKLISTS_API_KEY_FILE" in capsys.readouterr().err


@posix_only
def test_mcp_server_warns_on_group_readable_key_file(monkeypatch, tmp_path):
    f = tmp_path / "k"
    f.write_text("chk_x\n")
    os.chmod(f, 0o644)
    monkeypatch.setattr(mcp_server, "KEY_FILE", str(f))
    assert "chmod 600" in mcp_server._key_file_warning()
    os.chmod(f, 0o600)
    assert mcp_server._key_file_warning() is None
