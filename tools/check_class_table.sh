#!/usr/bin/env bash
# Compare the committed class table against the engine's own class reference.
#
# src/godot/class_table.zig carries `godot_version`, and until this script
# existed nothing read it: the table could fall behind the engine and
# `scene validate` would go on checking property types against a class list
# nobody had looked at. A pin nothing verifies is not a pin.
#
# Reports drift; does not fail the build. Regenerating the table changes what
# `scene validate` enforces, which is a deliberate change rather than
# something to do automatically.
set -euo pipefail

GODOT="${GODOT:-godot}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
committed="$repo_root/src/godot/class_table.zig"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

engine_version="$("$GODOT" --version 2>/dev/null | head -1 || echo unknown)"
echo "engine: $engine_version"
echo "table:  $(grep -o 'godot_version = "[^"]*"' "$committed" | head -1)"

if ! "$GODOT" --headless --doctool "$work" --no-docbase >/dev/null 2>&1; then
  echo "note: this Godot build cannot --doctool (editor builds only); skipping"
  exit 0
fi

python3 "$repo_root/tools/gen_class_table.py" "$work" > "$work/regen.zig"
zig fmt "$work/regen.zig" >/dev/null

# The version line differs by construction: a doctool dump carries no
# version.py. Everything else should match.
strip() { grep -v 'godot_version = \|^//!' "$1"; }
if diff <(strip "$work/regen.zig") <(strip "$committed") > "$work/table.diff"; then
  echo "class table matches this engine's class reference"
  exit 0
fi

added=$(grep -c '^< ' "$work/table.diff" || true)
removed=$(grep -c '^> ' "$work/table.diff" || true)
echo "class table differs from this engine: $added line(s) only in the engine, $removed only in the table"
echo "regenerate deliberately with:"
echo "  tools/gen_class_table.py <godot source checkout> > src/godot/class_table.zig && zig fmt src/godot/class_table.zig"
sed -n '1,40p' "$work/table.diff"
