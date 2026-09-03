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

The user has run `install.sh` and sourced the environment:

```bash
source "$HOME/.godot-cli/env.sh"
```

Use `godot-cli` on PATH. Never reference the godot-cli source tree; docs and examples live under `$GODOT_CLI_HOME`.

| Path | Contents |
|------|----------|
| `$GODOT_CLI_HOME/docs/agent_quickstart.md` | Start here: rules, workflow, cheat sheet |
| `$GODOT_CLI_HOME/docs/agent_godot_basics.md` | Projects, scenes, Control layout, running the game |
| `$GODOT_CLI_HOME/docs/agent_scene_authoring.md` | Every recipe and patch op, resources, moving files, UI parity |
| `$GODOT_CLI_HOME/docs/agent_batch_commands.md` | Batch workflows |
| `$GODOT_CLI_HOME/docs/mcp_tools.json` | Command JSON shapes |
| `$GODOT_CLI_HOME/examples/intents/` | Copy-paste intent files |

Work from the Godot project root (`project.godot`). Pass `--json` on every command and `--project-root .` for writes, catalog, validate, apply, and project commands.

## Rules

1. Structure lives in the scene file, as the editor writes it. No hand-edited `.tscn`, no `load().instantiate()` in `_ready()` for static UI or levels.
2. Discover before editing: `scene node list`, `catalog list`, `catalog show <id>`.
3. Project catalog ids are instanced with `--catalog-id`; `godot/...` builtins are plain nodes.
4. Presentation on nodes, signals as `[connection]` sections (`scene connection add`), resources as `.tres` (`resource new`).
5. Values are Variant text; strings carry their own quotes (`"\"Paused\""`).
6. Files move with `project move`, never `mv`.
7. Validate after every edit; run the game and read the frame and the log before reporting done.

## Workflow checklist

```
- [ ] source "$HOME/.godot-cli/env.sh"
- [ ] scene node list <scene> --json
- [ ] catalog list --project-root . --json (when adding UI or level structure)
- [ ] edit with scene commands, an intent, or a batch, always with --project-root .
- [ ] scene validate <scene> --project-root . --json
- [ ] mkdir -p capture && touch capture/.gdignore && godot --headless --path . --import --quit
- [ ] godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 60 --log-file capture/godot.log --no-header
- [ ] read the last capture/shot*.png and capture/godot.log
```

## Command cheat sheet

```bash
godot-cli scene new --output scenes/main.tscn --root-name Main --root-type Node2D --project-root .
godot-cli scene node add scenes/main.tscn --parent /root/Main --name Player --type CharacterBody2D --project-root .
godot-cli scene instance add scenes/main.tscn --parent /root/Main --name Btn --catalog-id ui/button --project-root .
godot-cli scene connection add scenes/main.tscn --from /root/Main/Btn --signal pressed --to /root/Main --method _on_btn_pressed --project-root .
godot-cli scene apply scenes/main.tscn --intent intents/hud.json --project-root . --json
godot-cli scene apply scenes/main.tscn --patch patch.json --dry-run --project-root . --json
godot-cli resource new --output materials/wood.tres --type StandardMaterial3D --property roughness --value 0.8 --project-root .
godot-cli project apply --project-root . --intent intents/project_bootstrap.json --json
godot-cli project move --project-root . --from scripts/player.gd --to scripts/hero.gd
godot-cli batch --file workflow.json --json
godot-cli scene validate scenes/main.tscn --project-root . --json
```

Recipes: `player_2d`, `static_body_2d`, `camera_2d`, `ui_panel`, `tilemap_layer`, `audio_player`, `instance_catalog`, `catalog_button`, `connect`, `assign_ext`, `instance_override`, `node_set`, `add_node`. Patch ops and their fields: `agent_scene_authoring.md`.

## First session prompt (for the user)

```text
Source ~/.godot-cli/env.sh. Author scenes with godot-cli only; no hand-edited .tscn.
Read $GODOT_CLI_HOME/docs/agent_quickstart.md, then agent_godot_basics.md.
Use --json on every command and --project-root . for writes, validate, catalog, and project commands.
Task: ...
```
