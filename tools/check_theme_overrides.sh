#!/usr/bin/env bash
# Compare the committed theme override table against an engine's own list.
#
# Only one direction matters: an override this engine offers that the table
# lacks would be reported by `scene validate` as unknown on a scene the
# editor saved. Names the table has and this engine lacks are a newer
# engine's, and expected against an older one.
#
# Reports drift; does not fail the build, like tools/check_class_table.sh.
set -euo pipefail

GODOT="${GODOT:-godot}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
committed="$repo_root/src/godot/theme_overrides.zig"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "engine: $("$GODOT" --version 2>/dev/null | head -1 || echo unknown)"
echo "table:  $(grep -o 'godot_version = "[^"]*"' "$committed" | head -1)"
GODOT="$GODOT" "$repo_root/tools/gen_theme_overrides.sh" > "$work/regen.zig"

python3 - "$work/regen.zig" "$committed" <<'PY'
import re, sys
def load(path):
    out = {}
    for m in re.finditer(r'\.class = "(\w+)", \.overrides = &\.\{([^}]*)\}', open(path).read()):
        out[m.group(1)] = set(re.findall(r'"([^"]+)"', m.group(2)))
    return out
engine, table = load(sys.argv[1]), load(sys.argv[2])
missing = sorted(f"{c}: {n}" for c in engine for n in engine[c] - table.get(c, set()))
extra = sum(len(table[c] - engine.get(c, set())) for c in table)
print(f"{len(missing)} override(s) this engine offers are not in the table")
print(f"{extra} override(s) in the table are not in this engine")
if missing:
    print("the table is behind this engine. Regenerate deliberately with:")
    print("  tools/gen_theme_overrides.sh > src/godot/theme_overrides.zig && zig fmt src/godot/theme_overrides.zig")
    print("\n".join(missing[:20]))
else:
    print("theme override table covers this engine")
PY
