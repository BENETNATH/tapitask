"""stdio MCP server: every error reply carries the originating request id."""
from __future__ import annotations

import io
import json
import urllib.error

import mcp_server


def _http_error(code: int, body: str) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        "http://x/lists/l/items/i", code, "err", {}, io.BytesIO(body.encode()))


def test_tool_failure_keeps_request_id(monkeypatch):
    def boom(method, path, body=None):
        raise _http_error(404, '{"detail":"Item not found"}')

    monkeypatch.setattr(mcp_server, "_api", boom)
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 42, "method": "tools/call",
        "params": {"name": "check_item",
                   "arguments": {"list_id": "0f9c6c11-8a3c-4a14-9a2b-0d3f4c5a6b7e",
                                 "item_id": "7c1d3e2a-9b4f-4e5c-8d6a-1f2e3d4c5b6a"}},
    }))
    assert reply["id"] == 42
    # A tool that ran and failed is a tool result, not a JSON-RPC error.
    assert "error" not in reply and reply["result"]["isError"] is True
    text = reply["result"]["content"][0]["text"]
    assert "404" in text and "Item not found" in text


def test_invalid_uuid_is_invalid_params():
    """C2.11 : list_id/item_id sont interpolés dans les URLs — un non-UUID
    est un défaut d'arguments (-32602), pas un appel réseau avec une URL cassée."""
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 43, "method": "tools/call",
        "params": {"name": "check_item",
                   "arguments": {"list_id": "l", "item_id": "i"}}}))
    assert reply["id"] == 43 and reply["error"]["code"] == -32602
    assert "list_id" in reply["error"]["message"]

    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 44, "method": "tools/call",
        "params": {"name": "check_item",
                   "arguments": {"list_id": "0f9c6c11-8a3c-4a14-9a2b-0d3f4c5a6b7e",
                                 "item_id": "not-a-uuid"}}}))
    assert reply["id"] == 44 and reply["error"]["code"] == -32602
    assert "item_id" in reply["error"]["message"]


def test_api_call_uses_10s_timeout(monkeypatch):
    """C2.11 : urlopen sans timeout = un agent bloqué indéfiniment sur un
    API muet. Le timeout est passé en kwarg."""
    seen = {}

    def fake_urlopen(req, **kwargs):
        seen.update(kwargs)
        raise urllib.error.URLError("stop")

    monkeypatch.setattr(mcp_server.urllib.request, "urlopen", fake_urlopen)
    try:
        mcp_server._api("GET", "/lists")
    except urllib.error.URLError:
        pass
    assert seen.get("timeout") == 10, seen


def test_unknown_tool_and_bad_params_keep_request_id():
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": "abc", "method": "tools/call",
        "params": {"name": "nope", "arguments": {}}}))
    assert reply["id"] == "abc" and reply["error"]["code"] == -32602

    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": {"name": "get_list", "arguments": {}}}))  # list_id missing
    assert reply["id"] == 7 and reply["error"]["code"] == -32602

    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 8, "method": "tools/call"}))  # no params
    assert reply["id"] == 8 and reply["error"]["code"] == -32602


def test_read_only_refusal_and_unreachable_api_are_iserror(monkeypatch):
    def refused(method, path, body=None):
        raise _http_error(403, '{"detail":"Read-only credentials"}')

    monkeypatch.setattr(mcp_server, "_api", refused)
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": {"name": "add_items",
                   "arguments": {"list_id": "0f9c6c11-8a3c-4a14-9a2b-0d3f4c5a6b7e",
                                 "text": "milk"}}}))
    assert reply["result"]["isError"] is True
    # Same wording as the HTTP bridge: FastAPI's detail, not the raw JSON.
    assert reply["result"]["content"][0]["text"] == "HTTP 403: Read-only credentials"

    def proxy(method, path, body=None):
        raise _http_error(502, "<html>Bad gateway</html>")

    monkeypatch.setattr(mcp_server, "_api", proxy)
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 9, "method": "tools/call",
        "params": {"name": "list_lists"}}))
    assert reply["result"]["content"][0]["text"] == "HTTP 502: <html>Bad gateway</html>"

    def down(method, path, body=None):
        raise urllib.error.URLError("Connection refused")

    monkeypatch.setattr(mcp_server, "_api", down)
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": {"name": "list_lists"}}))
    assert reply["result"]["isError"] is True
    assert "Connection refused" in reply["result"]["content"][0]["text"]


def test_protocol_and_server_faults_stay_jsonrpc_errors(monkeypatch):
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "get_list", "arguments": ["l"]}}))
    assert reply["error"]["code"] == -32602 and "result" not in reply

    def no_key(method, path, body=None):
        raise RuntimeError("cannot read CHECKLISTS_API_KEY_FILE: No such file")

    monkeypatch.setattr(mcp_server, "_api", no_key)
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 4, "method": "tools/call",
        "params": {"name": "list_lists"}}))
    assert reply["error"]["code"] == -32603


def test_success_has_no_iserror(monkeypatch):
    monkeypatch.setattr(mcp_server, "_api", lambda m, p, b=None: "[]")
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": {"name": "list_lists"}}))
    assert reply["result"] == {"content": [{"type": "text", "text": "[]"}]}


def test_success_unknown_method_and_id_zero():
    reply = mcp_server.handle_line(json.dumps(
        {"jsonrpc": "2.0", "id": 0, "method": "tools/list"}))
    assert reply["id"] == 0 and "tools" in reply["result"]
    reply = mcp_server.handle_line(json.dumps(
        {"jsonrpc": "2.0", "id": 5, "method": "bogus"}))
    assert reply["id"] == 5 and reply["error"]["code"] == -32601


def test_parse_error_is_only_null_id_case():
    reply = mcp_server.handle_line("{not json")
    assert reply["id"] is None and reply["error"]["code"] == -32700


def test_notifications_get_no_reply(monkeypatch):
    def boom(method, path, body=None):
        raise RuntimeError("down")

    monkeypatch.setattr(mcp_server, "_api", boom)
    assert mcp_server.handle_line(json.dumps(
        {"jsonrpc": "2.0", "method": "notifications/initialized"})) is None
    assert mcp_server.handle_line(json.dumps(
        {"jsonrpc": "2.0", "method": "tools/call",
         "params": {"name": "list_lists"}})) is None
