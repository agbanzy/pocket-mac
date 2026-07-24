#!/usr/bin/env python3
"""A minimal MCP server over stdio, for testing the client without a network dependency.

Speaks newline-delimited JSON-RPC 2.0: initialize, tools/list, tools/call. Deliberately also
emits an unsolicited notification and a reply with a mismatched id, so the client's
"read until my id arrives" loop is actually exercised rather than assumed.
"""
import json
import sys


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


TOOLS = [
    {
        "name": "echo",
        "description": "Echo back the text you pass.",
        "inputSchema": {
            "type": "object",
            "properties": {"text": {"type": "string"}},
            "required": ["text"],
        },
    },
    {
        "name": "add",
        "description": "Add two numbers.",
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
            "required": ["a", "b"],
        },
    },
]


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = msg.get("method")
        msg_id = msg.get("id")

        if method == "initialize":
            # Noise first: a notification and a stale-id reply the client must skip over.
            send({"jsonrpc": "2.0", "method": "notifications/message",
                  "params": {"level": "info", "data": "warming up"}})
            send({"jsonrpc": "2.0", "id": 99999, "result": {"ignored": True}})
            send({"jsonrpc": "2.0", "id": msg_id, "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "mock", "version": "0.1.0"},
            }})
        elif method == "notifications/initialized":
            pass  # notification: no reply
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": msg_id, "result": {"tools": TOOLS}})
        elif method == "tools/call":
            params = msg.get("params", {})
            name = params.get("name")
            args = params.get("arguments", {})
            if name == "echo":
                text = f"echo: {args.get('text', '')}"
            elif name == "add":
                text = str(args.get("a", 0) + args.get("b", 0))
            else:
                send({"jsonrpc": "2.0", "id": msg_id,
                      "error": {"code": -32601, "message": f"no such tool: {name}"}})
                continue
            send({"jsonrpc": "2.0", "id": msg_id,
                  "result": {"content": [{"type": "text", "text": text}]}})
        elif msg_id is not None:
            send({"jsonrpc": "2.0", "id": msg_id,
                  "error": {"code": -32601, "message": f"unknown method: {method}"}})


if __name__ == "__main__":
    main()
