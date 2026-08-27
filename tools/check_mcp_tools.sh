#!/usr/bin/env bash
# Report commands missing from docs/mcp_tools.json.
#
# The tool catalog is hand-written, because its value is the worked example in
# each entry. This checks only coverage: every runnable command should appear,
# so a new command cannot silently go undocumented for agents.
#
#   tools/check_mcp_tools.sh [path/to/godot-cli]

set -euo pipefail

binary="${1:-./zig-out/bin/godot-cli}"
catalog="${2:-docs/mcp_tools.json}"

tree_json="$(mktemp)"
trap 'rm -f "$tree_json"' EXIT
"$binary" reference --format json >"$tree_json"

python3 - "$tree_json" "$catalog" <<'PY'
import json
import sys

tree_path, catalog_path = sys.argv[1], sys.argv[2]
with open(tree_path) as handle:
    tree = json.load(handle)
with open(catalog_path) as handle:
    catalog = json.load(handle)

# Commands that describe the CLI itself rather than a Godot file operation.
# An agent authoring scenes has no use for them.
excluded = {"help", "ping", "completions", "man", "reference"}

runnable = [c["path"] for c in tree["commands"] if c["runnable"] and c["path"] not in excluded]
known = {c["path"] for c in tree["commands"]}

covered = set()
for tool in catalog.get("tools", []):
    argv = tool.get("argv") or tool.get("json_request", {}).get("argv", [])
    for length in range(len(argv), 0, -1):
        candidate = " ".join(argv[:length])
        if candidate in known:
            covered.add(candidate)
            break

missing = [path for path in runnable if path not in covered]

if missing:
    print(f"{len(missing)} command(s) missing from {catalog_path}:", file=sys.stderr)
    for path in missing:
        print(f"  godot-cli {path}", file=sys.stderr)
    print("\nAdd an entry with a worked example, or extend the exclusion list.", file=sys.stderr)
    sys.exit(1)

catalog_version = catalog.get("version")
if catalog_version != tree["version"]:
    print(
        f"{catalog_path} says version {catalog_version!r}, binary is {tree['version']!r}",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"{catalog_path}: {len(runnable)} runnable command(s) covered")
PY
