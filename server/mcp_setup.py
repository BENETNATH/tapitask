#!/usr/bin/env python3
"""Local onboarding for the Tapitask stdio MCP server (mcp_server.py).

    python mcp_setup.py setup    # log in, pick lists, create a key, store it
    python mcp_setup.py rotate   # replace a key file's key, verify, offer to revoke the old one
    python mcp_setup.py revoke   # revoke one of your API keys (explicit confirmation)

What it does, and what it never does:
  * Logs in with a password read through getpass (no echo, never an argument,
    never printed or logged) and an optional 2FA code. Only the short-lived
    access token is kept, in memory.
  * Creates a *read-only* key by default; read+write needs an explicit choice.
  * Stores the key in a 0600 file inside a 0700 directory and prints the
    stdio command + CHECKLISTS_API_KEY_FILE path. The key value is never printed.
  * Rotation creates and verifies the replacement before it even offers to
    revoke the old key; nothing is ever revoked without an explicit "yes".
  * Touches nothing but the key file: no MCP client, Docker or sync configuration.

Standard library only, so it runs without the server's virtualenv.
"""
from __future__ import annotations

import argparse
import datetime
import getpass
import ipaddress
import json
import os
import re
import shlex
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from urllib.parse import urlparse

DEFAULT_URL = "http://localhost:8000"
TIMEOUT = 15
KEY_PREFIX = "chk_"


class SetupError(Exception):
    """A problem to report to the user (exit code 1); never carries a secret."""


# ---------------------------------------------------------------- console --

class Console:
    """Prompt/print wrapper so tests can script the answers."""

    def __init__(self, input_fn=input, secret_fn=getpass.getpass, out=None, err=None):
        self._input = input_fn
        self._secret = secret_fn
        self.out = out or sys.stdout
        self.err = err or sys.stderr

    def say(self, text: str = "") -> None:
        print(text, file=self.out)

    def warn(self, text: str) -> None:
        print(f"warning: {text}", file=self.err)

    def ask(self, prompt: str) -> str:
        try:
            return self._input(prompt).strip()
        except EOFError:
            raise SetupError("no answer available (stdin closed); pass the matching option") from None

    def secret(self, prompt: str) -> str:
        try:
            return self._secret(prompt)
        except EOFError:
            raise SetupError("no answer available (stdin closed)") from None

    def confirm(self, prompt: str) -> bool:
        """Yes/no, default NO. Anything but y/yes is a no; EOF is a no."""
        try:
            return self._input(f"{prompt} [y/N] ").strip().lower() in ("y", "yes")
        except EOFError:
            return False


# -------------------------------------------------------------------- HTTP --

class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: it would replay the Authorization header (or
    the login body) against another URL."""

    def redirect_request(self, *args, **kwargs):  # noqa: D102
        return None


def _detail(data) -> str:
    """The server's string `detail`, or "". Structured details (422) can echo
    the submitted payload, so they are never printed."""
    if isinstance(data, dict) and isinstance(data.get("detail"), str):
        return data["detail"][:200]
    return ""


class Api:
    def __init__(self, base_url: str):
        self.base = base_url.rstrip("/")
        self._opener = urllib.request.build_opener(_NoRedirect)

    def call(self, method: str, path: str, body: dict | None = None,
             token: str | None = None) -> tuple[int, object]:
        """Return (status, parsed JSON or None). HTTP errors are returned, not
        raised; only transport failures raise SetupError."""
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(
            f"{self.base}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            headers=headers, method=method)
        try:
            with self._opener.open(req, timeout=TIMEOUT) as resp:
                status, raw = resp.status, resp.read()
        except urllib.error.HTTPError as e:
            status, raw = e.code, e.read()
            if 300 <= status < 400:
                raise SetupError(
                    f"{self.base} answered with a redirect (HTTP {status}); "
                    "use the final URL (e.g. https://...) with --url") from None
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise SetupError(f"cannot reach {self.base}: {reason}") from None
        try:
            return status, json.loads(raw) if raw else None
        except ValueError:
            return status, None


def check_url(url: str, allow_insecure_http: bool) -> str:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise SetupError(f"invalid --url {url!r}: expected http(s)://host[:port]")
    if parsed.scheme == "http" and not allow_insecure_http and not _is_loopback(parsed.hostname):
        raise SetupError(
            "refusing to send a password over plain http to a non-local host; "
            "use https:// (or --allow-insecure-http if the network is trusted)")
    return url.rstrip("/")


def _is_loopback(host: str) -> bool:
    if host == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


# ------------------------------------------------------------------- login --

def login(api: Api, con: Console, email: str) -> str:
    """Prompt for the password (and 2FA code when the server asks) and return
    the access token. Credentials live only in local variables."""
    password = con.secret("Tapitask password: ")
    if not password:
        raise SetupError("empty password")
    totp = None
    for _ in range(3):
        body = {"email": email, "password": password}
        if totp:
            body["totp_code"] = totp
        status, data = api.call("POST", "/auth/login", body)
        if status == 200 and isinstance(data, dict) and data.get("access_token"):
            return data["access_token"]
        detail = _detail(data)
        if status == 401 and "2FA" in detail:
            totp = con.secret("2FA code: ").strip()
            if not totp:
                raise SetupError("a 2FA code is required for this account")
            continue
        if status == 401:
            raise SetupError("login failed: invalid credentials")
        if status == 429:
            raise SetupError("login refused: too many attempts, try again later")
        raise SetupError(f"login failed (HTTP {status}){': ' + detail if detail else ''}")
    raise SetupError("login failed: 2FA code rejected")


# ------------------------------------------------------------ list helpers --

@dataclass
class Scope:
    list_id: str | None  # None = every list the account can access
    label: str
    role: str | None = None


def fetch_lists(api: Api, token: str) -> list[dict]:
    status, data = api.call("GET", "/lists", token=token)
    if status != 200 or not isinstance(data, list):
        raise SetupError(f"cannot list your lists (HTTP {status})")
    return data


def choose_scope(con: Console, lists: list[dict], wanted: str | None) -> Scope:
    if not lists:
        raise SetupError("this account has no accessible list; create one first")
    by_id = {l["id"]: l for l in lists}
    if wanted is not None:
        if wanted.lower() == "all":
            return Scope(None, "all lists")
        if wanted not in by_id:
            raise SetupError(f"--list {wanted}: not one of your accessible lists")
        return _scope_of(by_id[wanted])
    con.say("Accessible lists:")
    for i, l in enumerate(lists, 1):
        con.say(f"  {i}. {l['title']}  [{l.get('role', '?')}]  {l['id']}")
    con.say("  a. ALL lists (including lists shared with you later)")
    while True:
        answer = con.ask("Give the key access to which list? (number, or 'a' for all) ").lower()
        if answer in ("a", "all"):
            return Scope(None, "all lists")
        if answer.isdigit() and 1 <= int(answer) <= len(lists):
            return _scope_of(lists[int(answer) - 1])
        con.say("Please answer with a list number or 'a'.")


def _scope_of(entry: dict) -> Scope:
    return Scope(entry["id"], f"list {entry['title']!r}", entry.get("role"))


def choose_access(con: Console, wanted: str | None) -> bool:
    """Return read_only. Read-only is the default; write must be spelled out."""
    if wanted is not None:
        return wanted != "write"
    answer = con.ask("Access: press Enter for READ-ONLY, or type 'write' for read+write: ").lower()
    return answer != "write"


def slug(text: str, limit: int = 40) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")[:limit] or "key"


def default_key_name(scope: Scope, read_only: bool) -> str:
    return f"agent-{slug(scope.label.removeprefix('list '))}-{'ro' if read_only else 'rw'}"


def pick_name(con: Console, wanted: str | None, default: str) -> str:
    name = wanted
    if name is None:
        name = con.ask(f"Key name [{default}]: ") or default
    if not 1 <= len(name) <= 100:
        raise SetupError("the key name must be 1-100 characters")
    return name


# ---------------------------------------------------------- key file store --

def config_dir() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "tapitask")


def _posix() -> bool:
    return os.name != "nt"


def _mode(path: str) -> int:
    return os.stat(path).st_mode & 0o777


def prepare_key_dir(path: str, con: Console) -> None:
    """Make sure the key's directory exists, is ours and is 0700. The default
    directory is tightened if needed; any other existing directory must
    already be 0700 (we never chmod a directory we did not create)."""
    parent = os.path.dirname(os.path.abspath(path))
    is_default = os.path.abspath(parent) == os.path.abspath(config_dir())
    if not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
        if _posix():
            os.chmod(parent, 0o700)
        return
    if not _posix():
        return
    if os.stat(parent).st_uid != os.geteuid():
        raise SetupError(f"{parent} is not owned by you; refusing to store a key there")
    if _mode(parent) != 0o700:
        if not is_default:
            raise SetupError(
                f"{parent} has mode {_mode(parent):04o}, expected 0700; use a dedicated "
                f"directory (default: {config_dir()}) or run chmod 700 on it")
        os.chmod(parent, 0o700)
        con.warn(f"tightened {parent} to mode 0700")


def preflight_key_file(path: str, con: Console, *, overwrite: bool) -> None:
    """Checks to run BEFORE minting a key, so a key is never created that
    cannot be stored."""
    if os.path.isdir(path):
        raise SetupError(f"{path} is a directory")
    if os.path.lexists(path) and not overwrite:
        raise SetupError(
            f"{path} already exists; use `rotate` to replace its key, "
            "or choose another --key-file")
    prepare_key_dir(path, con)


def write_key_file(path: str, key: str) -> None:
    """Atomically write `key` to `path` with mode 0600 (temp file created
    0600 with O_EXCL, fsynced, then renamed over the target)."""
    tmp = f"{path}.{os.getpid()}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
    fd = os.open(tmp, flags, 0o600)
    try:
        with os.fdopen(fd, "wb") as f:
            if _posix():
                os.fchmod(f.fileno(), 0o600)
            f.write((key + "\n").encode())
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def read_key_file(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            key = f.read().strip()
    except OSError as e:
        raise SetupError(f"cannot read {path}: {e.strerror}") from None
    if not key.startswith(KEY_PREFIX):
        raise SetupError(f"{path} does not contain a Tapitask API key")
    return key


# ------------------------------------------------------------ key lifecycle --

def create_key(api: Api, token: str, name: str, read_only: bool, list_id: str | None) -> dict:
    status, data = api.call("POST", "/api-keys", token=token, body={
        "name": name, "read_only": read_only, "list_scope": list_id})
    if status != 201 or not isinstance(data, dict) or not str(data.get("key", "")).startswith(KEY_PREFIX):
        detail = _detail(data)
        raise SetupError(f"key creation failed (HTTP {status}){': ' + detail if detail else ''}")
    return data


def verify_key(api: Api, key: str, *, scope: Scope, read_only: bool,
               expected_ids: set[str]) -> None:
    """Exercise the new key without changing any data; raise SetupError on any
    mismatch. Checks: it authenticates, sees exactly the expected lists, can
    read the first one, and — for a read-only key — is refused a write (an
    empty body is used, so even a wrongly-permitted write creates nothing)."""
    problems: list[str] = []
    status, data = api.call("GET", "/lists", token=key)
    if status != 200 or not isinstance(data, list):
        raise SetupError(f"verification failed: the new key was rejected (HTTP {status})")
    seen = {l["id"] for l in data}
    if seen != expected_ids:
        problems.append(f"it sees {len(seen)} list(s), expected {len(expected_ids)}")
    if seen:
        first = sorted(seen)[0]
        status, _ = api.call("GET", f"/lists/{first}/items", token=key)
        if status != 200:
            problems.append(f"reading a list failed (HTTP {status})")
    if read_only:
        status, _ = api.call("POST", "/lists", body={}, token=key)
        if status != 403:
            problems.append(f"a write attempt answered HTTP {status}, expected 403")
    if problems:
        raise SetupError("verification failed: " + "; ".join(problems))


def expected_list_ids(lists: list[dict], scope: Scope) -> set[str]:
    return {l["id"] for l in lists} if scope.list_id is None else {scope.list_id}


def print_client_block(con: Console, url: str, key_file: str) -> None:
    server = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_server.py")
    command = f"{shlex.quote(sys.executable)} {shlex.quote(server)}"
    con.say()
    con.say("MCP client configuration (stdio server):")
    # command and args are separate (and JSON-quoted), as most clients expect.
    con.say(f"  command: {json.dumps(sys.executable)}")
    con.say(f"  args: {json.dumps([server])}")
    con.say("  environment:")
    con.say(f"    CHECKLISTS_URL={url}")
    con.say(f"    CHECKLISTS_API_KEY_FILE={key_file}")
    con.say()
    con.say("Same thing as one shell line (to try it by hand):")
    con.say(f"  CHECKLISTS_URL={shlex.quote(url)} "
            f"CHECKLISTS_API_KEY_FILE={shlex.quote(key_file)} {command}")


def describe(scope: Scope, read_only: bool) -> str:
    return f"{'read-only' if read_only else 'read+write'}, scope: {scope.label}"


# ----------------------------------------------------------------- commands --

def resolve_login(args, con: Console) -> tuple[Api, str, str]:
    url = check_url(args.url, args.allow_insecure_http)
    email = args.email or con.ask("Tapitask email: ")
    if not email:
        raise SetupError("an email is required")
    api = Api(url)
    return api, url, login(api, con, email)


def cmd_setup(args, con: Console) -> int:
    api, url, token = resolve_login(args, con)
    lists = fetch_lists(api, token)
    scope = choose_scope(con, lists, args.list)
    read_only = choose_access(con, args.access)
    if not read_only:
        con.warn("this key will be able to add, edit and check items "
                 + ("on EVERY list you can write to." if scope.list_id is None
                    else f"on {scope.label} (your role there: {scope.role})."))
        if scope.role == "viewer":
            con.warn("you are only a viewer of that list: writes will be refused by the server")
    elif scope.list_id is None:
        con.warn("an all-lists key also covers lists shared with you in the future")
    name = pick_name(con, args.name, default_key_name(scope, read_only))
    key_file = os.path.abspath(os.path.expanduser(args.key_file)) if args.key_file \
        else os.path.join(config_dir(), f"{slug(name)}.key")
    preflight_key_file(key_file, con, overwrite=False)

    created = create_key(api, token, name, read_only, scope.list_id)
    key = created["key"]
    try:
        write_key_file(key_file, key)
    except OSError as e:
        raise SetupError(
            f"the key {created['id']} was created but could not be stored ({e.strerror}); "
            "revoke it with `mcp_setup.py revoke` and retry") from None
    try:
        verify_key(api, key, scope=scope, read_only=read_only,
                   expected_ids=expected_list_ids(lists, scope))
    except SetupError as e:
        con.warn(f"{e}. The key file was kept; the key id is {created['id']}.")
        return 1
    con.say(f"Created API key {name!r} (id {created['id']}; {describe(scope, read_only)}); verified.")
    show_file_state(con, key_file)
    print_client_block(con, url, key_file)
    con.say()
    con.say("The key value is only in that file; it is not shown anywhere.")
    return 0


def show_file_state(con: Console, key_file: str) -> None:
    if _posix():
        con.say(f"Key file: {key_file} (mode {_mode(key_file):04o}, "
                f"directory {_mode(os.path.dirname(key_file)):04o})")
    else:
        con.say(f"Key file: {key_file}")
        con.warn("POSIX file modes are not enforced on Windows; the file relies on "
                 "your user profile's permissions")


def choose_key(con: Console, keys: list[dict], prompt: str, *, allow_none: bool = False):
    con.say("Your active API keys:")
    for i, k in enumerate(keys, 1):
        mode = "read-only" if k.get("read_only") else "read+write"
        scope = k.get("list_scope") or "all lists"
        con.say(f"  {i}. {k['name']}  ({mode}, scope: {scope}, {k['key_prefix']}…, id {k['id']})")
    if allow_none:
        con.say("  0. none of these")
    while True:
        answer = con.ask(prompt)
        if allow_none and answer == "0":
            return None
        if answer.isdigit() and 1 <= int(answer) <= len(keys):
            return keys[int(answer) - 1]
        con.say("Please answer with a number from the list.")


def fetch_keys(api: Api, token: str) -> list[dict]:
    status, data = api.call("GET", "/api-keys", token=token)
    if status != 200 or not isinstance(data, list):
        raise SetupError(f"cannot list your API keys (HTTP {status})")
    return data


def revoke_key(api: Api, token: str, key: dict) -> None:
    status, _ = api.call("DELETE", f"/api-keys/{key['id']}", token=token)
    if status != 204:
        raise SetupError(f"revoking key {key['id']} failed (HTTP {status})")


def find_key_file(args, con: Console) -> str:
    if args.key_file:
        return os.path.abspath(os.path.expanduser(args.key_file))
    d = config_dir()
    found = sorted(f for f in os.listdir(d) if f.endswith(".key")) if os.path.isdir(d) else []
    if not found:
        raise SetupError(f"no key file found in {d}; pass --key-file")
    if len(found) == 1:
        return os.path.join(d, found[0])
    for i, f in enumerate(found, 1):
        con.say(f"  {i}. {os.path.join(d, f)}")
    while True:
        answer = con.ask("Rotate which key file? (number) ")
        if answer.isdigit() and 1 <= int(answer) <= len(found):
            return os.path.join(d, found[int(answer) - 1])


def cmd_rotate(args, con: Console) -> int:
    key_file = find_key_file(args, con)
    current = read_key_file(key_file)
    api, url, token = resolve_login(args, con)
    keys = fetch_keys(api, token)
    matches = [k for k in keys if k["key_prefix"] == current[:len(k["key_prefix"])]]
    if len(matches) == 1:
        old = matches[0]
    else:
        con.warn("could not tell which of your keys this file holds"
                 if not matches else "several keys share this file's prefix")
        old = choose_key(con, keys, "Which key is being replaced? (number, 0 = none) ",
                         allow_none=True) if keys else None
    lists = fetch_lists(api, token)
    # The replacement keeps the old key's access: rotation never widens it.
    if old is not None and "list_scope" in old:
        read_only = bool(old.get("read_only"))
        scope = Scope(None, "all lists") if old["list_scope"] is None else \
            next((_scope_of(l) for l in lists if l["id"] == old["list_scope"]), None)
        if scope is None:
            raise SetupError("the old key's list is no longer accessible; run `setup` instead")
    else:
        con.warn("no old key to copy the access from; choose the new key's access"
                 if old is None else
                 "the server does not report the old key's scope; choose it again")
        scope = choose_scope(con, lists, args.list)
        read_only = choose_access(con, args.access)

    base = re.sub(r"-rotated-\d{8}$", "", old["name"]) if old else "agent"
    default = f"{base}-rotated-{datetime.date.today():%Y%m%d}"
    name = pick_name(con, args.name, default)
    staged = f"{key_file}.new"
    if os.path.lexists(staged):
        raise SetupError(f"{staged} exists from an earlier run; remove it first")
    preflight_key_file(staged, con, overwrite=False)

    created = create_key(api, token, name, read_only, scope.list_id)
    key = created["key"]
    try:
        write_key_file(staged, key)
    except OSError as e:
        raise SetupError(
            f"the new key {created['id']} was created but could not be stored ({e.strerror}); "
            "the old key file is untouched; revoke the new key with `mcp_setup.py revoke`") from None
    try:
        verify_key(api, key, scope=scope, read_only=read_only,
                   expected_ids=expected_list_ids(lists, scope))
    except SetupError as e:
        os.unlink(staged)
        con.warn(f"{e}. {key_file} still holds the OLD key, which was not touched. "
                 f"The unused new key has id {created['id']}; revoke it with `mcp_setup.py revoke`.")
        return 1
    os.replace(staged, key_file)
    con.say(f"Created and verified replacement key {name!r} (id {created['id']}; "
            f"{describe(scope, read_only)}).")
    show_file_state(con, key_file)
    print_client_block(con, url, key_file)
    con.say()
    con.say("mcp_server.py re-reads the key file on each request, so a running server "
            "picks the new key up without a restart.")
    if old is None:
        con.say("No old key was selected, so there is nothing to revoke.")
        return 0
    con.say()
    con.say(f"The old key {old['name']!r} (id {old['id']}) is still valid.")
    if con.confirm("Revoke it now? Anything still using it will stop working."):
        revoke_key(api, token, old)
        con.say(f"Revoked old key {old['id']}.")
    else:
        con.say("Not revoked. Revoke it later with: python mcp_setup.py revoke")
    return 0


def cmd_revoke(args, con: Console) -> int:
    api, _url, token = resolve_login(args, con)
    keys = fetch_keys(api, token)
    if not keys:
        raise SetupError("you have no active API keys")
    key = choose_key(con, keys, "Revoke which key? (number) ")
    if con.confirm(f"Revoke {key['name']!r} (id {key['id']})? This cannot be undone."):
        revoke_key(api, token, key)
        con.say(f"Revoked {key['id']}.")
    else:
        con.say("Nothing revoked.")
    return 0


# --------------------------------------------------------------------- main --

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="mcp_setup.py", description="Set up and rotate the Tapitask MCP API key.")
    p.add_argument("--url", default=os.environ.get("CHECKLISTS_URL", DEFAULT_URL),
                   help=f"Tapitask API URL (default: $CHECKLISTS_URL or {DEFAULT_URL})")
    p.add_argument("--email", help="account email (asked if omitted)")
    p.add_argument("--allow-insecure-http", action="store_true",
                   help="allow http:// to a non-local host (the password travels in clear)")
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("setup", help="create a key and store it in a 0600 file")
    s.add_argument("--list", metavar="ID|all", help="list id, or 'all' (asked if omitted)")
    s.add_argument("--access", choices=("read", "write"),
                   help="read-only or read+write (asked if omitted; default read-only)")
    s.add_argument("--name", help="key name")
    s.add_argument("--key-file", help=f"where to store the key (default: {config_dir()}/<name>.key)")
    r = sub.add_parser("rotate", help="replace a key file's key, verify it, offer to revoke the old one")
    r.add_argument("--key-file", help="the key file to rotate (default: pick from the config dir)")
    r.add_argument("--name", help="name of the new key")
    r.add_argument("--list", metavar="ID|all", help=argparse.SUPPRESS)
    r.add_argument("--access", choices=("read", "write"), help=argparse.SUPPRESS)
    sub.add_parser("revoke", help="revoke one of your API keys")
    return p


def main(argv: list[str] | None = None, console: Console | None = None) -> int:
    args = build_parser().parse_args(argv)
    con = console or Console()
    try:
        return {"setup": cmd_setup, "rotate": cmd_rotate, "revoke": cmd_revoke}[args.command](args, con)
    except SetupError as e:
        print(f"error: {e}", file=con.err)
        return 1
    except KeyboardInterrupt:
        print("\ninterrupted; nothing was revoked", file=con.err)
        return 130


if __name__ == "__main__":
    sys.exit(main())
