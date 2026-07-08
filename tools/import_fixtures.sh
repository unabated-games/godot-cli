#!/usr/bin/env bash
# Regenerate Godot import metadata and optional rich variant fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJECT="$ROOT/test_fixtures/project"
REGENERATE_RICH="${REGENERATE_RICH:-0}"

if [[ ! -x "$GODOT" ]]; then
  echo "Godot binary not found: $GODOT" >&2
  echo "Set GODOT=/path/to/Godot and retry." >&2
  exit 1
fi

"$GODOT" --headless --path "$PROJECT" --import
echo "Imported $PROJECT"
echo "uid cache: $PROJECT/.godot/uid_cache.bin"

if [[ "$REGENERATE_RICH" == "1" ]]; then
  "$GODOT" --headless --path "$PROJECT" --script save_rich_fixtures.gd
  echo "Regenerated rich variant fixtures (material + scene shells)"
  echo "Edit rich_variants.tscn manually if you need full variant literals, then copy to rich_variants_godot_saved.tscn"
fi
