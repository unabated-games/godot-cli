#!/usr/bin/env bash
# Regenerate Godot import metadata for test_fixtures/project (uid_cache.bin, etc.).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
PROJECT="$ROOT/test_fixtures/project"

if [[ ! -x "$GODOT" ]]; then
  echo "Godot binary not found: $GODOT" >&2
  echo "Set GODOT=/path/to/Godot and retry." >&2
  exit 1
fi

"$GODOT" --headless --path "$PROJECT" --import
echo "Imported $PROJECT"
echo "uid cache: $PROJECT/.godot/uid_cache.bin"
