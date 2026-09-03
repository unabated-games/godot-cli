#!/usr/bin/env bash
# Smoke-test `godot-cli mcp` over a real pipe: a legacy initialize handshake,
# then a modern server/discover opening, each followed by a tool call, a
# rejected path, and a resource read. Checks the replies with python3.
#
#   tools/test_mcp.sh [path/to/godot-cli]

set -euo pipefail

binary="${1:-./zig-out/bin/godot-cli}"
binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"

legacy_out="$(mktemp)"
modern_out="$(mktemp)"
trap 'rm -f "$legacy_out" "$modern_out"' EXIT

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"scene_node_list","arguments":{"file":"sample.tscn"}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"scene_node_list","arguments":{"file":"../../outside.tscn"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"godot-cli://docs/quickstart"}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"scene_node_list","arguments":{"file":"missing.tscn"}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"godot-cli://catalog"}}' \
  | "$binary" mcp --project-root test_fixtures/project >"$legacy_out"

printf '%s\n' \
  '{"jsonrpc":"2.0","id":"d1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  '{"jsonrpc":"2.0","id":"d2","method":"prompts/get","params":{"name":"godot-scene-session","arguments":{"task":"add a HUD"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  '{"jsonrpc":"2.0","id":"d3","method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2031-01-01","io.modelcontextprotocol/clientCapabilities":{}}}}' \
  | "$binary" mcp >"$modern_out"

python3 - "$legacy_out" "$modern_out" <<'PY'
import json
import sys

def lines(path):
    with open(path) as handle:
        return [json.loads(line) for line in handle if line.strip()]

legacy = lines(sys.argv[1])
assert len(legacy) == 7, f"expected 7 legacy responses, got {len(legacy)}"
by_id = {r["id"]: r for r in legacy}

init = by_id[1]["result"]
assert init["protocolVersion"] == "2025-06-18", init
assert set(init["capabilities"]) >= {"tools", "resources", "prompts"}
assert init["serverInfo"]["name"] == "godot-cli"

tools = by_id[2]["result"]["tools"]
names = [t["name"] for t in tools]
assert len(tools) >= 80, len(tools)
assert "mcp" not in names and "ping" not in names and "scene_node_add" in names
for tool in tools:
    assert tool["inputSchema"]["type"] == "object", tool["name"]
    assert "project-root" not in tool["inputSchema"]["properties"], tool["name"]
assert names == sorted(names, key=names.index), "tool order must be deterministic"

call = by_id[3]["result"]
assert call["isError"] is False, call
assert call["structuredContent"]["ok"] is True
assert call["structuredContent"]["command"] == ["scene", "node", "list"]
assert json.loads(call["content"][0]["text"]) == call["structuredContent"]
assert any(n["path"] == "/root/Root" for n in call["structuredContent"]["data"]["nodes"]), call

outside = by_id[4]
assert "error" in outside and outside["error"]["code"] == -32602, outside
assert "outside the project root" in outside["error"]["message"]

quickstart = by_id[5]["result"]["contents"][0]
assert "godot-cli agent quickstart" in quickstart["text"]
assert quickstart["mimeType"] == "text/markdown"

missing = by_id[6]["result"]
assert missing["isError"] is True, missing
assert missing["structuredContent"]["ok"] is False
assert missing["structuredContent"]["failure"]["kind"], missing

catalog = json.loads(by_id[7]["result"]["contents"][0]["text"])
assert catalog["ok"] is True and "entries" in catalog["data"], catalog

modern = lines(sys.argv[2])
assert len(modern) == 3, f"expected 3 modern responses, got {len(modern)}"
m = {r["id"]: r for r in modern}
discover = m["d1"]["result"]
assert "2026-07-28" in discover["supportedVersions"]
assert discover["resultType"] == "complete"
assert "ttlMs" in discover and "cacheScope" in discover
assert discover["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "godot-cli"

prompt = m["d2"]["result"]
assert prompt["messages"][-1]["content"]["text"] == "Task: add a HUD", prompt["messages"][-1]
assert prompt["messages"][1]["content"]["type"] == "resource"

bad_version = m["d3"]
assert bad_version["error"]["code"] == -32022, bad_version
assert "2026-07-28" in bad_version["error"]["data"]["supported"]

print(f"mcp smoke: {len(tools)} tools, legacy and modern openings both answered")
PY
