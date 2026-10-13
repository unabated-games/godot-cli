#!/usr/bin/env bash
# Generate the export option table for one Godot version from that engine.
#
#   GODOT=/path/to/godot tools/gen_export_options.sh > src/godot/export_options/godot_4_8.zig
#   zig fmt src/godot/export_options/godot_4_8.zig
#
# KEEP_SAVE=<dir> also keeps the editor's own export_presets.cfg and
# export_credentials.cfg there; test_fixtures/export holds one pair per table.
#
# Export options are not in the class reference: each platform defines its
# own in C++, with defaults, and the editor writes every one of them into
# export_presets.cfg whenever it saves. So the table comes from the editor
# itself. A scratch project gets one bare preset per platform and a small
# editor plugin (tools/export_options) that makes the editor save them in
# full; what it writes is the table. Needs an editor build, not an export
# template.
set -euo pipefail

GODOT="${GODOT:-godot}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The names Godot matches a preset's `platform` against (get_name, not
# get_os_name: Windows is "Windows Desktop"). A preset naming anything else is
# skipped on load and dropped on the next save, so the output is checked for
# every one of these below.
platforms=(Android iOS Linux macOS visionOS Web "Windows Desktop")

mkdir -p "$work/addons/godot_cli_export_options"
cp "$repo_root"/tools/export_options/*.gd "$repo_root"/tools/export_options/plugin.cfg "$work/addons/godot_cli_export_options/"
cat > "$work/project.godot" <<'PROJECT'
config_version=5

[application]

config/name="godot-cli export options"

[editor_plugins]

enabled=PackedStringArray("res://addons/godot_cli_export_options/plugin.cfg")
PROJECT

index=0
: > "$work/export_presets.cfg"
for platform in "${platforms[@]}"; do
  [ "$index" -gt 0 ] && printf '\n' >> "$work/export_presets.cfg"
  printf '[preset.%d]\n\nname="%s"\nplatform="%s"\nexport_filter="all_resources"\ninclude_filter=""\nexclude_filter=""\nexport_path=""\n' \
    "$index" "$platform" "$platform" >> "$work/export_presets.cfg"
  index=$((index + 1))
done

version="$("$GODOT" --version 2>/dev/null | head -1)"
# The plugin quits once the save has landed. The headless editor sleeps
# between frames, so --quit-after is no bound on time; a watchdog is.
"$GODOT" --headless --editor --path "$work" > "$work/editor.log" 2>&1 &
editor=$!
( sleep 120 && kill "$editor" 2>/dev/null ) &
watchdog=$!
wait "$editor" || true
kill "$watchdog" 2>/dev/null || true
wait "$watchdog" 2>/dev/null || true

if [ ! -f "$work/export_options_dump.json" ]; then
  echo "the editor plugin never finished; is this an editor build? its errors:" >&2
  grep -v 'nonexistent section' "$work/editor.log" | grep -A4 'ERROR' | head -30 >&2
  exit 1
fi

# Godot's own save, kept on request: the golden files the writer's tests
# compare against byte for byte.
if [ -n "${KEEP_SAVE:-}" ]; then
  mkdir -p "$KEEP_SAVE"
  cp "$work/export_presets.cfg" "$KEEP_SAVE/export_presets.cfg"
  cp "$work/.godot/export_credentials.cfg" "$KEEP_SAVE/export_credentials.cfg"
fi

python3 "$repo_root/tools/gen_export_options.py" \
  "$version" "$work/export_presets.cfg" "$work/.godot/export_credentials.cfg" "$work/export_options_dump.json" \
  "${platforms[@]}"
