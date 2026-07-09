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
```

## Rules

1. **Discover before edit** — `scene node list` for `/root/<RootName>/` paths
2. **Project catalog** → `scene instance add --catalog-id`
3. **Builtins** (`godot/ui/Button`) → `scene node add --type Button` only
4. **Validate after every edit**
5. **Many steps** → `scene apply --intent` or `batch --file`

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

Writes auto-run save preparation; `scene normalize` re-preps existing files.

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
