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
                   "arguments": {"list_id": "l", "item_id": "i"}},
    }))
    assert reply["id"] == 42
    assert reply["error"]["code"] == -32603
    assert "404" in reply["error"]["message"]
    assert "Item not found" in reply["error"]["message"]


def test_unknown_tool_and_bad_params_keep_request_id():
    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": "abc", "method": "tools/call",
        "params": {"name": "nope", "arguments": {}}}))
    assert reply["id"] == "abc" and "error" in reply

    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 7, "method": "tools/call",
        "params": {"name": "get_list", "arguments": {}}}))  # list_id missing
    assert reply["id"] == 7 and reply["error"]["code"] == -32602

    reply = mcp_server.handle_line(json.dumps({
        "jsonrpc": "2.0", "id": 8, "method": "tools/call"}))  # no params
    assert reply["id"] == 8 and reply["error"]["code"] == -32602


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
