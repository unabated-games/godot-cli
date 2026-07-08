#!/usr/bin/env bash
# Sync ext_resource id session cache from a Godot headless save.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${CLI:-$ROOT/zig-out/bin/godot-cli}"
PROJECT="$ROOT/test_fixtures/project"

"$CLI" uid session import \
  --referrer "res://sample.tscn" \
  --from "$PROJECT/sample_godot_saved.tscn" \
  --project-root "$PROJECT" \
  --json

echo "Updated $PROJECT/.godot/scene_id_cache.json"
