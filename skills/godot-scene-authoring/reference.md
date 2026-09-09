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

Always confirm with `scene describe --json` (or `scene node list`) before setting `parent` in intents. Pass `--project-root` and an instanced node reports the class it really is rather than `PackedScene`.

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
| `property_type_mismatch` | The value is the wrong Variant type for that class property, e.g. `visible = Vector2(1, 2)` |
| `unknown_signal` | The class does not emit that signal and the node's script does not declare it; check the spelling |
| `unknown_property` (warning) | The class has no such property, so Godot keeps the line and ignores it. Skipped when the node has a script or is an instance |
| `header_attribute` | `path`, `name`, `parent` and `type` live in a section header: use `scene retarget-ext`, `project move`, `scene node rename` or `reparent` |
| `invalid_patch` naming a field | The op does not take that field; the hint lists the ones it does |
| Click verified nothing | A click that cannot reach its target fails the run, naming the node's position and the viewport. `--click` works under `--headless`; only the frame is missing there |

## JSON output

Every command supports `--json`. Response envelope:

```json
{ "ok": true, "data": { ... }, "messages": [] }
```

`ok` follows the exit code. A command that ran but answered no — a `scene validate` that found issues, a `project run` whose log held an error — reports `ok: false` with `failure.kind: "checks_failed"` **and** keeps its findings in `data`, so read `data` on failure too. A failure caused by the call itself carries `details` naming the field, the value, and what would have been accepted.
