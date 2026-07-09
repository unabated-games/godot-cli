# godot-cli scene authoring — reference

Read `$GODOT_CLI_HOME/docs/agent_scene_authoring.md` for full recipes. This file covers patterns agents hit often.

## Environment

```bash
source "$HOME/.godot-cli/env.sh"
# GODOT_CLI, GODOT_CLI_HOME, GODOT_CLI_TEMPLATES_ROOT, PATH updated
```

Templates resolve automatically via `GODOT_CLI_TEMPLATES_ROOT`. Override per command with `--templates-root`.

## Viewport paths

Scene root in editor = `/root/<RootNodeName>/…`

| Root name in file | Child parent example |
|-------------------|----------------------|
| `Main` | `/root/Main/Player` |
| `Root` | `/root/Root/HUD` |

Always confirm with `scene node list --json` before setting `parent` in intents. `--project-root` is not needed for `scene node list` (optional; ignored if passed).

## Catalog

```bash
godot-cli catalog scan --project-root . --json
godot-cli catalog export --project-root . --output AGENTS.md   # optional digest
```

Project manifests define instancable PackedScenes (`ui/button`). Builtins (`godot/ui/Button`) are documentation for raw `scene node add`.

## Wiring external resources

Pattern for scripts, textures, audio, `.tres` files:

```text
ext_add (register res://path) → set-property / node_set (ExtResource("Type_hint"))
```

| Goal | ext type | property | example path |
|------|----------|----------|--------------|
| Script | `Script` | `script` | `res://player.gd` |
| Sprite | `Texture2D` | `texture` | `res://icon.svg` |
| Audio | `AudioStream` | `stream` | `res://sfx.wav` |

Use `Texture2D` + source `res://` path for images (not `CompressedTexture2D`).

```bash
# Intent one-shot
godot-cli scene apply scenes/main.tscn \
  --intent intents/assign_sprite_texture.json --project-root . --json
```

Examples: `$GODOT_CLI_HOME/examples/intents/player_with_icon.json`, `patches/sprite_icon_texture.json`.

## Patch / intent / apply

```bash
# Plan only (no write)
godot-cli scene plan scenes/main.tscn --intent intents/hud.json --project-root . --json

# Write patch file for review
godot-cli scene plan scenes/main.tscn --intent intents/hud.json \
  --write-patch patches/generated.json --project-root .

# Apply patch or intent
godot-cli scene apply scenes/main.tscn --patch patches/generated.json --project-root .
godot-cli scene apply scenes/main.tscn --intent intents/hud.json --project-root .

# Undo
godot-cli scene apply scenes/main.tscn --patch patches/undo.json --project-root .
godot-cli scene restore scenes/main.tscn --from scenes/main.tscn.godot-cli-snapshot
```

## Batch modes

| mode | Behavior |
|------|----------|
| `stop` | Stop on first failure (default) |
| `continue` | Run all steps, report aggregate |
| `atomic` | Snapshot `rollback` paths; restore on any failure |

```json
{
  "mode": "atomic",
  "rollback": ["scenes/main.tscn"],
  "steps": [
    { "argv": ["scene", "apply", "scenes/main.tscn", "--intent", "intents/hud.json", "--project-root", ".", "--json"] },
    { "argv": ["scene", "validate", "scenes/main.tscn", "--project-root", ".", "--json"] }
  ]
}
```

Example: `$GODOT_CLI_HOME/examples/batch/apply_validate.json`

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `TemplateNotFound` | `source env.sh` or pass `--templates-root $GODOT_CLI_HOME/templates` |
| Catalog id not found | `catalog scan` + `catalog list`; ensure manifest exists |
| Wrong parent path | `scene node list --json` |
| Builtin instancing error | Use `scene node add --type` instead |
| Batch `--request` fails | Use `batch --file` or `batch --json-body` |

## JSON output

Every command supports `--json`. Response envelope:

```json
{ "ok": true, "data": { ... }, "messages": [] }
```

On failure: `"ok": false`, non-zero exit. Parse `data` and `messages` before proceeding.
