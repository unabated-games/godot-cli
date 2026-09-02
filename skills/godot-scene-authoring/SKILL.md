---
name: godot-scene-authoring
description: >-
  Author Godot 4 scenes via godot-cli — editor-like .tscn hierarchy, catalog
  instancing, intents, patches, and batch workflows. Use when creating or
  editing .tscn files, building Godot scene trees, using godot-cli, catalog
  manifests, scene intents, or when the user wants LLM-driven Godot scene
  authoring without hand-editing scene text.
---

# Godot scene authoring (godot-cli)

## Prerequisites

User must have run `install.sh` and sourced the environment:

```bash
source "$HOME/.godot-cli/env.sh"
```

Use `$GODOT_CLI` or `godot-cli` on PATH. **Never** reference the godot-cli source tree — all docs and examples live under `$GODOT_CLI_HOME`.

| Path | Contents |
|------|----------|
| `$GODOT_CLI_HOME/docs/agent_quickstart.md` | Start here |
| `$GODOT_CLI_HOME/docs/agent_scene_authoring.md` | Full recipes |
| `$GODOT_CLI_HOME/docs/agent_batch_commands.md` | Batch workflows |
| `$GODOT_CLI_HOME/docs/mcp_tools.json` | Command JSON shapes |
| `$GODOT_CLI_HOME/examples/intents/` | Copy-paste intent files |

Work from the Godot project root (`project.godot`). Pass `--json` on every command. Pass `--project-root .` for writes, catalog, validate, and apply; optional (ignored) on `scene node list`, `scene node get`, and `scene diff`.

## North star

Persist hierarchy in `.tscn` — same as the Godot editor. **Never** `load().instantiate()` for static UI or level layout in GDScript.

## Workflow checklist

```
- [ ] source "$HOME/.godot-cli/env.sh"
- [ ] scene node list <scene> --json
- [ ] catalog list --project-root . --json (if instancing project UI)
- [ ] edit (scene commands, intent, or batch) — use --project-root .
- [ ] scene validate <scene> --project-root . --json
- [ ] scene node list <scene> --json (confirm)
```

## Wire signals in the scene

```bash
godot-cli scene connection add <scene> --from /root/Main/Menu/Resume --signal pressed \
  --to /root/Main/Menu --method _on_resume_pressed --project-root .
```

That writes the `[connection]` section the editor's Node dock writes. Do not connect static UI signals in `_ready()`; the method still lives in the receiving node's script.

## Several properties in one command

`--property`/`--value` repeat on `scene node add` and `scene sub add`:

```bash
godot-cli scene node add <scene> --parent /root/Main --name HUD --type Control \
  --property anchors_preset --value 15 --property anchor_right --value 1.0 \
  --property anchor_bottom --value 1.0 --property grow_horizontal --value 2 \
  --property grow_vertical --value 2 --project-root .
```

## Godot project and scene basics

Things Godot assumes that an agent often does not know:

- A project is a folder with `project.godot` at its root, and `res://` is that folder. A `.tscn` outside it cannot resolve `res://` paths, so create scenes inside the project and set `application/run/main_scene` with `project settings set`.
- A scene has exactly one root node; the root has no `parent` attribute. Pick the root type for the job: `Node2D` for 2D worlds, `Node3D` for 3D, `Control` for UI screens.
- `anchors_preset` is an editor label only. Runtime layout comes from `anchor_left/top/right/bottom` (0 to 1), `offset_*`, and `grow_horizontal/grow_vertical`. A `Control` with default anchors is 0 by 0 pixels, and anything centred inside it lands at the top-left corner.
  - Full rect: `anchors_preset = 15`, `anchor_right = 1.0`, `anchor_bottom = 1.0`, `grow_horizontal = 2`, `grow_vertical = 2`.
  - Centred: `anchors_preset = 8`, all four anchors `0.5`, `grow_horizontal = 2`, `grow_vertical = 2`.
  - Top-left with an offset: leave anchors at 0 and set `offset_left` and `offset_top`.
- Containers lay children out; plain Controls do not. `VBoxContainer` and `HBoxContainer` stack children. `MarginContainer`, `PanelContainer`, and `CenterContainer` hold one child, and stack several on top of each other. Give leaf controls (`ProgressBar`, `TextureRect`) a `custom_minimum_size` so a container knows how big they are.
- After adding scripts or scenes from outside the editor, run `godot --headless --path . --import --quit` once so Godot assigns UIDs; then run the game and read the frame and the log (below).

## Run the game and check the result

After a scene change, `scene validate` proves the file is well formed. To see the result, run the game from the terminal; Godot writes a frame and a log with no extra tooling:

```bash
mkdir -p capture && touch capture/.gdignore          # Godot skips this folder, so frames are not imported
godot --headless --path . --import --quit          # once after adding files, so Godot assigns UIDs
godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 5 --log-file capture/godot.log --no-header
```

Read the highest-numbered `capture/shot*.png` and `capture/godot.log`. The log holds every `print()`, `push_warning`, `push_error`, and script error with a backtrace; any `ERROR` or `SCRIPT ERROR` line means the change is not done. Without a display, drop `--write-movie` and add `--headless` to get the log alone.

## Command cheat sheet

```bash
# Discover (file-only — --project-root optional)
godot-cli scene node list scenes/main.tscn --json
godot-cli catalog list --project-root . --json
godot-cli catalog show <id> --project-root . --json

# Create
godot-cli scene new --output scenes/main.tscn --root-name Main --root-type Node2D --project-root .
godot-cli scene template copy 2d/top_down_player --output scenes/player.tscn --project-root .

# Edit (pick one style)
godot-cli scene node add scenes/main.tscn --parent /root/Main --name Player --type CharacterBody2D --project-root .
godot-cli scene instance add scenes/main.tscn --parent /root/Main --name Btn --catalog-id ui/button --project-root .
godot-cli scene apply scenes/main.tscn --intent intents/hud.json --project-root . --json

# Preview before write
godot-cli scene apply scenes/main.tscn --intent intents/hud.json --dry-run --preview-properties --project-root . --json

# Batch
godot-cli batch --file workflow.json --json

# Input Map (after movement script uses Input.get_vector actions)
godot-cli project input apply --project-root . --intent intents/wasd_movement.json --json

# Main scene + autoloads + plugins + rendering + physics
godot-cli project settings apply --project-root . --intent intents/main_scene.json --json
godot-cli project plugins enable --project-root . --plugin my_addon --json
godot-cli project rendering apply --project-root . --intent intents/rendering_forward_plus.json --json
godot-cli project physics apply --project-root . --intent intents/physics_jolt.json --json

# Unified bootstrap (optional — one intent for multiple sections)
godot-cli project show --project-root . --json
godot-cli project apply --project-root . --intent intents/project_bootstrap.json --json
```

## Rules

1. **Discover before edit** — `scene node list` for `/root/<RootName>/` paths
2. **Project catalog** → `scene instance add --catalog-id`
3. **Builtins** (`godot/ui/Button`) → `scene node add --type Button` only
4. **Validate after every edit**
5. **Many steps** → `scene apply --intent` or `batch --file`
6. **UI editor parity** — static Control look in `.tscn` properties (`theme_override_*`, anchors, min size); `@tool` + export setters on reusable widgets; `%Name` via `--unique-name`; see `agent_scene_authoring.md` § UI authoring

## UI authoring (short)

- **Don't** set font size / theme / layout only in `_ready()` — editor won't match Play.
- **Do** use `node_set` / `instance_override` / intent `properties` for presentation.
- **Reusable widgets:** `@tool` + export setters → `get_node_or_null` into children.
- **Stable script refs:** `--unique-name` on HUD nodes → `%Score` in GDScript.
- **Patch strings:** `"value": "\"Score\""` for instance override text properties.
- Example: `$GODOT_CLI_HOME/examples/intents/hud_top_bar.json`

## Intent example

Copy from `$GODOT_CLI_HOME/examples/intents/hud_main.json` into the project's `intents/` folder. Adjust `parent` to match `scene node list` output.

```json
{
  "steps": [
    { "recipe": "player_2d", "parent": "/root/Main", "name": "Player", "radius": 10.0 },
    { "recipe": "camera_2d", "parent": "/root/Main", "name": "Camera" }
  ]
}
```

Recipes: `player_2d`, `camera_2d`, `ui_panel`, `tilemap_layer`, `audio_player`, `instance_catalog`, `catalog_button`, `assign_ext`, `instance_override`, `node_set`, `add_node`.

`player_2d` optional: `texture` / `sprite_texture` / `texture_path`, `modulate`, `position`, `script`, `shape_id_hint`, `radius`, `sprite` (bool).

## Common follow-ups

After create → intent → validate:

- **Attach script** → `assign_ext` or `player_2d` + `"script": "res://…gd"`
- **Assign sprite texture** → `assign_ext` or `player_2d` with `"texture": "res://icon.svg"`
- **Tint sprite** → `modulate` on node properties or `player_2d` + `"modulate"`
- **Another character body** → repeat `player_2d` with a different `name` (unique shape ids; shared textures dedupe by path)
- **Reuse existing texture** → `assign_ext` or reference `ExtResource("<id>")` from inspect/refs
- **Instance catalog UI** → already covered
- **Player movement (WASD / joypad)** → `project input apply` with `wasd_movement.json` after attaching a script that uses `move_*` actions
- **HUD styling** → theme/anchor/min-size on nodes via intent; not `_ready()` only (`hud_top_bar.json`)
- **Reusable UI cell** → `@tool` script + `instance_override` on root exports (`label`, `number`)
- **Script node refs** → `--unique-name` when adding HUD widgets; use `%Name` in GDScript

Writes auto-run save preparation (ext/sub order, **node parent-before-child order**, id repair); `scene normalize` re-preps existing files.

**Node order:** validate fails with `node_parent_order` if a child appears before its parent in the file. Never use Godot headless to fix order — normalize instead. Add parents before children in multi-step patches.

Full pattern: `$GODOT_CLI_HOME/docs/agent_scene_authoring.md` (Wiring external resources).

## First session prompt (for user)

When starting a fresh agent session on a Godot project:

```text
Source ~/.godot-cli/env.sh. Author scenes with godot-cli only — no hand-editing .tscn.
Read $GODOT_CLI_HOME/docs/agent_quickstart.md. Use --json on every command; --project-root . for apply/validate/catalog/writes.
Task: create scenes/main.tscn (Node2D root Main), add player + camera via intent, validate.
```

## More detail

See [reference.md](reference.md) for batch modes, undo, and troubleshooting.
