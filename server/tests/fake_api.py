"""A tiny in-process fake of the Tapitask REST API (login, lists, API keys).

It is a real HTTP server on 127.0.0.1 so the urllib code of mcp_setup.py and
mcp_server.py is exercised end to end — but it holds all state in memory, so
no real key is ever created. Behaviour mirrors server/app (same status codes
for the cases the setup command relies on).
"""
from __future__ import annotations

import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class FakeApi:
    def __init__(self, *, email="me@example.com", password="correct-horse", totp=None,
                 lists=None):
        self.email, self.password, self.totp = email, password, totp
        # id -> {"title", "role"}
        self.lists = lists or {
            "11111111-1111-1111-1111-111111111111": {"title": "Groceries", "role": "owner"},
            "22222222-2222-2222-2222-222222222222": {"title": "Work", "role": "editor"},
            "33333333-3333-3333-3333-333333333333": {"title": "Shared read", "role": "viewer"},
        }
        self.keys: dict[str, dict] = {}      # id -> record (incl. "raw")
        self.tokens: set[str] = set()
        self.requests: list[tuple[str, str, str]] = []   # (method, path, who)
        self.login_bodies: list[dict] = []
        # fault injection
        self.leak_all_lists_to_scoped_keys = False
        self.redirect_login = False
        self.writable_readonly_keys = False
        self.omit_list_scope_in_listing = False
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.url = f"http://127.0.0.1:{self._server.server_port}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    # lifecycle
    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self._server.shutdown()
        self._server.server_close()

    # helpers for assertions
    def active_keys(self):
        return {i: k for i, k in self.keys.items() if not k["revoked"]}

    def key_by_name(self, name):
        return next(k for k in self.keys.values() if k["name"] == name)

    def calls(self, method=None, path_prefix=""):
        return [r for r in self.requests
                if (method is None or r[0] == method) and r[1].startswith(path_prefix)]

    # request handling
    def _who(self, auth: str):
        if not auth.startswith("Bearer "):
            return None, None
        tok = auth[7:]
        if tok in self.tokens:
            return "jwt", None
        for k in self.keys.values():
            if k["raw"] == tok and not k["revoked"]:
                return "key", k
        return None, None

    def _visible_lists(self, kind, key):
        if kind == "key" and key["list_scope"] and not self.leak_all_lists_to_scoped_keys:
            return {key["list_scope"]: self.lists[key["list_scope"]]} \
                if key["list_scope"] in self.lists else {}
        return self.lists

    def _handler(self):
        api = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):  # silence
                pass

            def _send(self, status, body=None, headers=None):
                raw = b"" if body is None else json.dumps(body).encode()
                self.send_response(status)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _body(self):
                n = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(n)) if n else {}

            def _route(self, method):
                path = self.path
                body = self._body() if method in ("POST", "PATCH") else None
                kind, key = api._who(self.headers.get("Authorization", ""))
                api.requests.append((method, path, kind or "anon"))

                if method == "POST" and path == "/auth/login":
                    api.login_bodies.append(body)
                    if api.redirect_login:
                        return self._send(302, None, {"Location": "https://elsewhere.invalid/auth/login"})
                    if api.totp and body.get("totp_code") != api.totp:
                        return self._send(401, {"detail": "Code 2FA requis ou invalide"})
                    if body.get("email") != api.email or body.get("password") != api.password:
                        return self._send(401, {"detail": "Invalid credentials"})
                    tok = "jwt-" + secrets.token_hex(8)
                    api.tokens.add(tok)
                    return self._send(200, {"access_token": tok, "refresh_token": "r", "token_type": "bearer"})

                if kind is None:
                    return self._send(401, {"detail": "Missing credentials"})

                if method == "GET" and path == "/lists":
                    vis = api._visible_lists(kind, key)
                    return self._send(200, [
                        {"id": i, "title": v["title"], "role": v["role"], "owner_id": "o",
                         "updated_at": "2026-01-01T00:00:00Z"} for i, v in vis.items()])

                if method == "GET" and path.startswith("/lists/") and path.endswith("/items"):
                    lid = path.split("/")[2]
                    if kind == "key" and key["list_scope"] and lid != key["list_scope"]:
                        return self._send(403, {"detail": "API key scoped to another list"})
                    if lid not in api.lists:
                        return self._send(404, {"detail": "List not found"})
                    return self._send(200, [])

                if method == "POST" and path == "/lists":
                    if kind == "key" and key["read_only"] and not api.writable_readonly_keys:
                        return self._send(403, {"detail": "Read-only credentials"})
                    return self._send(422, {"detail": [{"msg": "field required", "input": {}}]})

                if method == "POST" and path == "/api-keys":
                    if kind == "key" and key["read_only"]:
                        return self._send(403, {"detail": "Read-only credentials"})
                    scope = body.get("list_scope")
                    if scope is not None and scope not in api.lists:
                        return self._send(404, {"detail": "List not found"})
                    kid = secrets.token_hex(8)
                    raw = "chk_" + secrets.token_urlsafe(32)
                    api.keys[kid] = {"id": kid, "name": body["name"], "raw": raw,
                                     "read_only": body.get("read_only", False),
                                     "list_scope": scope, "revoked": False}
                    return self._send(201, {"key": raw, "id": kid, "name": body["name"],
                                            "read_only": api.keys[kid]["read_only"],
                                            "note": "Store this key now"})

                if method == "GET" and path == "/api-keys":
                    rows = []
                    for k in api.active_keys().values():
                        row = {"id": k["id"], "name": k["name"], "key_prefix": k["raw"][:10],
                               "read_only": k["read_only"],
                               "created_at": "2026-01-01T00:00:00Z"}
                        if not api.omit_list_scope_in_listing:
                            row["list_scope"] = k["list_scope"]
                        rows.append(row)
                    return self._send(200, rows)

                if method == "DELETE" and path.startswith("/api-keys/"):
                    kid = path.rsplit("/", 1)[1]
                    if kid not in api.keys:
                        return self._send(404, {"detail": "API key not found"})
                    api.keys[kid]["revoked"] = True
                    return self._send(204)

                return self._send(404, {"detail": "not found"})

            def do_GET(self):
                self._route("GET")

            def do_POST(self):
                self._route("POST")

            def do_DELETE(self):
                self._route("DELETE")

        return H
