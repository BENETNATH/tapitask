"""MCP server exposing checklist tools to AI agents (stdio transport).

Run:  python mcp_server.py
Requires an API key with the desired scope:
      export CHECKLISTS_API_KEY=chk_... CHECKLISTS_URL=https://checklists.example.com
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request

URL = os.environ.get("CHECKLISTS_URL", "http://localhost:8000")
KEY = os.environ.get("CHECKLISTS_API_KEY", "")


def _api(method: str, path: str, body: dict | None = None) -> str:
    req = urllib.request.Request(
        f"{URL}{path}",
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req) as resp:
        return resp.read().decode()


TOOLS = [
    {
        "name": "list_lists",
        "description": "List the checklists the API key can access.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "get_list",
        "description": "Get the items of a list. Set unchecked_only to focus on what remains to do.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "list_id": {"type": "string"},
                "unchecked_only": {"type": "boolean", "default": False},
            },
            "required": ["list_id"],
        },
    },
    {
        "name": "add_items",
        "description": "Add items to a list. One line in `text` = one item.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "list_id": {"type": "string"},
                "text": {"type": "string", "description": "One item per line"},
            },
            "required": ["list_id", "text"],
        },
    },
    {
        "name": "check_item",
        "description": "Check (or uncheck) an item by id.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "list_id": {"type": "string"},
                "item_id": {"type": "string"},
                "done": {"type": "boolean", "default": True},
            },
            "required": ["list_id", "item_id"],
        },
    },
]


def _handle(name: str, args: dict) -> str:
    if name == "list_lists":
        return _api("GET", "/lists")
    if name == "get_list":
        flag = "true" if args.get("unchecked_only") else "false"
        return _api("GET", f"/lists/{args['list_id']}/items?unchecked_only={flag}")
    if name == "add_items":
        return _api("POST", f"/lists/{args['list_id']}/items/bulk", {"text": args["text"]})
    if name == "check_item":
        return _api(
            "PATCH",
            f"/lists/{args['list_id']}/items/{args['item_id']}",
            {"done": args.get("done", True)},
        )
    raise ValueError(f"Unknown tool: {name}")


def main() -> None:
    if not KEY:
        print("CHECKLISTS_API_KEY is not set", file=sys.stderr)
        sys.exit(1)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            message = {"jsonrpc": "2.0", "id": request.get("id")}
            method = request.get("method")
            if method == "initialize":
                message["result"] = {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "checklists", "version": "0.1.0"},
                }
            elif method == "tools/list":
                message["result"] = {"tools": TOOLS}
            elif method == "tools/call":
                result = _handle(request["params"]["name"], request["params"].get("arguments", {}))
                message["result"] = {"content": [{"type": "text", "text": result}]}
            elif method == "notifications/initialized":
                continue
            else:
                message["error"] = {"code": -32601, "message": f"Unknown method {method}"}
            sys.stdout.write(json.dumps(message) + "\n")
            sys.stdout.flush()
        except Exception as e:
            sys.stdout.write(
                json.dumps({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": str(e)}})
                + "\n"
            )
            sys.stdout.flush()


if __name__ == "__main__":
    main()
