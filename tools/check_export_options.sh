#!/usr/bin/env bash
# Check export presets against a real Godot editor, two ways.
#
# 1. Drift: regenerate the export option table from this engine and compare it
#    with the committed table for its minor version. A new option in a patch
#    release means presets godot-cli writes get rewritten by that editor.
# 2. Round trip: write presets with `project export apply` (options set, a
#    secret, a runnable preset), have the editor load and save them, and
#    require both files back byte for byte.
#
# Reports; the workflow step does not block on it. Regenerating a table is a
# deliberate change, as with the class table.
#
#   GODOT=/path/to/godot tools/check_export_options.sh [path/to/godot-cli]
set -euo pipefail

GODOT="${GODOT:-godot}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cli="${1:-$repo_root/zig-out/bin/godot-cli}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

version="$("$GODOT" --version 2>/dev/null | head -1)"
minor="$(echo "$version" | grep -oE '^[0-9]+\.[0-9]+' || true)"
table="$repo_root/src/godot/export_options/godot_${minor/./_}.zig"
echo "engine: $version"
if [ ! -f "$table" ]; then
  echo "no export option table for Godot $minor; presets for it use the newest table"
  echo "to add one: GODOT=$GODOT KEEP_SAVE=test_fixtures/export/godot_${minor/./_} tools/gen_export_options.sh > $table"
  exit 0
fi
echo "table:  $(grep -o 'godot_version = "[^"]*"' "$table")"
status=0

# 1. Drift.
GODOT="$GODOT" "$repo_root/tools/gen_export_options.sh" > "$work/regen.zig" 2> "$work/regen.log" || {
  echo "could not regenerate the table from this engine:"; cat "$work/regen.log"; exit 1;
}
zig fmt "$work/regen.zig" >/dev/null
strip() { grep -v 'godot_version = \|^//!' "$1"; }
if diff <(strip "$table") <(strip "$work/regen.zig") > "$work/table.diff"; then
  echo "export option table matches this engine"
else
  echo "export option table differs from this engine ('>' is the engine):"
  head -30 "$work/table.diff"
  status=1
fi

# 2. Round trip through the editor.
project="$work/project"
mkdir -p "$project"
printf 'config_version=5\n\n[application]\n\nconfig/name="Round trip"\nconfig/features=PackedStringArray("%s")\n' "$minor" > "$project/project.godot"
"$cli" project export apply --project-root "$project" --intent "$repo_root/share/examples/intents/export_desktop_web.json" --json > /dev/null
"$cli" project export apply --project-root "$project" --json --intent-json '{"presets":[{"name":"Android","platform":"Android","export_path":"build/game.aab","custom_features":["store"],"options":{"gradle_build/export_format":"AAB","keystore/release_password":"secret","package/unique_name":"com.example.roundtrip","version/code":7}},{"name":"Linux","runnable":true}]}' > /dev/null
cp "$project/export_presets.cfg" "$work/written.cfg"
cp "$project/.godot/export_credentials.cfg" "$work/written_credentials.cfg"

mkdir -p "$project/addons/godot_cli_export_options"
cp "$repo_root"/tools/export_options/*.gd "$repo_root"/tools/export_options/plugin.cfg "$project/addons/godot_cli_export_options/"
printf '\n[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_cli_export_options/plugin.cfg")\n' >> "$project/project.godot"
"$GODOT" --headless --editor --path "$project" > "$work/editor.log" 2>&1 &
editor=$!
( sleep 120 && kill "$editor" 2>/dev/null ) &
watchdog=$!
wait "$editor" || true
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true

if diff "$work/written.cfg" "$project/export_presets.cfg" > "$work/presets.diff" &&
   diff "$work/written_credentials.cfg" "$project/.godot/export_credentials.cfg" > "$work/credentials.diff"; then
  echo "the editor saves the presets godot-cli wrote byte for byte"
else
  echo "the editor rewrote presets godot-cli wrote ('>' is the editor):"
  head -30 "$work/presets.diff" "$work/credentials.diff" 2>/dev/null
  status=1
fi
exit $status
