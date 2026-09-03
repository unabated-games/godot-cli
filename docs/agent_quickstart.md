# godot-cli agent quickstart

One page. Detail lives in the files at the end; read those when a task needs them, not up front.

## Setup

```bash
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
source "$HOME/.godot-cli/env.sh"
godot-cli ping --json
```

`env.sh` puts `godot-cli` on `PATH` and sets `GODOT_CLI_HOME` (install root, docs and examples under it) and `GODOT_CLI_TEMPLATES_ROOT`. Work from the Godot project root, the folder holding `project.godot`. Pass `--json` on every command. In an empty folder, `project new --name <Name>` writes the `project.godot` the project manager would; nothing else creates it.

## When to pass `--project-root`

| Commands | `--project-root` |
|----------|------------------|
| `scene apply`, `scene plan`, `scene new`, `scene node add/remove/…`, `scene instance add`, `scene set-property`, `catalog *` | **Pass** : needed for `res://`, catalog ids, UID cache, save prep |
| `scene validate`, `scene inspect`, `scene refs` | **Pass** : enables UID cache and `res://` resolution checks |
| `project input *` | **Pass** : reads/writes `project.godot` under the project root |
| `project settings *`, `project autoload *` | **Pass** : main scene, display, layer names, autoloads |
| `scene node list`, `scene node get`, `scene diff` | **Optional** : accepted for uniformity; ignored (file-only reads) |

Common `project.godot` keys: `application` → `run/main_scene`, `config/name`; `display` → `window/size/viewport_width`, `window/size/viewport_height`, `window/stretch/mode`; `rendering` and `physics` take the aliases in `project rendering apply` / `project physics apply`. `project apply` takes one intent with `settings`, `input`, `autoload`, `plugins`, `rendering`, and `physics` sections (`$GODOT_CLI_HOME/examples/intents/project_bootstrap.json`).

Agents may pass `--project-root .` on all scene commands when working inside a Godot project; it is only *required* for writes, catalog, and validation that touches project paths.


## Rules

1. Scenes are authored in the scene file, the way the editor writes them. Never hand-edit `.tscn`, `.tres`, or `project.godot` text, and never build static UI or level structure in `_ready()` with `load().instantiate()`; that is for things the game spawns while playing.
2. Discover before editing: `scene node list` for viewport paths (`/root/<Root>/...`), `catalog list` and `catalog show <id>` for components the project already has.
3. A project catalog id is instanced (`scene instance add --catalog-id`); a `godot/...` builtin is a plain node (`scene node add --type`), never instanced.
4. Presentation lives on nodes (`anchor_*`, `grow_*`, `theme_override_*`, `custom_minimum_size`), signals in `[connection]` sections (`scene connection add`), resources in `.tres` files (`resource new`). None of them in `_ready()`.
5. Values are Godot Variant text: `Vector2(1, 2)`, `1.5`, `true`, and a string carries its own quotes, `"\"Paused\""`. A bare word is rejected before anything is written.
6. Move files with `project move`, never `mv`; a plain move leaves every `res://` reference stale.
7. Validate after every edit, then run the game and read the frame and the log.

## Workflow

```text
1. scene node list <scene> --json                     what is there
2. catalog list --project-root . --json               what exists to reuse
3. edit: scene commands, or scene apply --intent      one write per change
4. scene validate <scene> --project-root . --json     exit 1 on errors
5. run the game, read capture/shot*.png and capture/godot.log
```

## Cheat sheet

```bash
# create and build
godot-cli project new --project-root . --name MyGame --main-scene res://scenes/main.tscn --width 640 --height 360
godot-cli scene new --output scenes/main.tscn --root-name Main --root-type Node2D --project-root .
godot-cli scene node add scenes/main.tscn --parent /root/Main --name HUD --type Control \
  --property anchors_preset --value 15 --property anchor_right --value 1.0 --property anchor_bottom --value 1.0 --project-root .
godot-cli scene instance add scenes/main.tscn --parent /root/Main --name Btn --catalog-id ui/button --project-root .
godot-cli scene connection add scenes/main.tscn --from /root/Main/Btn --signal pressed --to /root/Main --method _on_btn_pressed --project-root .
godot-cli scene apply scenes/main.tscn --intent intents/hud.json --project-root . --json        # recipes: player_2d, static_body_2d, camera_2d, ui_panel, connect, ...
godot-cli scene apply scenes/main.tscn --intent-json '{"steps":[...]}' --project-root . --json           # the same, inline; --patch-json for a patch
godot-cli scene node add scenes/main.tscn --parent /root/Main --name Box --type Node2D --properties '{"visible":false,"z_index":3}' --project-root .
godot-cli scene apply scenes/main.tscn --patch patch.json --dry-run --project-root . --json     # preview; --write-undo-patch undo.json to record the reverse

# resources, project, files
godot-cli resource new --output materials/wood.tres --type StandardMaterial3D --property roughness --value 0.8 --project-root .
godot-cli project settings set --project-root . --section application --key run/main_scene --value res://scenes/main.tscn
godot-cli project input apply --project-root . --intent intents/wasd_movement.json
godot-cli project move --project-root . --from scripts/player.gd --to scripts/hero.gd

# check
godot-cli scene validate scenes/main.tscn --project-root . --json
godot-cli scene node list scenes/main.tscn --json
godot-cli scene diff before.tscn scenes/main.tscn --properties --json
```

## Run the game after a change

```bash
mkdir -p capture && touch capture/.gdignore
godot --headless --path . --import --quit
godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 60 --log-file capture/godot.log --no-header
```

Read the highest-numbered `capture/shot*.png` and `capture/godot.log`. Any `ERROR` or `SCRIPT ERROR` line means the change is not done.

## Read next

| File | When |
|------|------|
| `agent_godot_basics.md` | Before the first UI or level: what a project is, one root per scene, why `anchors_preset` alone leaves a Control at 0 by 0, which containers stack children, the capture recipe in full |
| `agent_scene_authoring.md` | Every recipe and patch op, resources, moving files, UI editor parity, the follow-ups table, anti-patterns |
| `agent_batch_commands.md` | Several commands in one process, with `stop`, `continue`, or `atomic` |
| `mcp_tools.json` | JSON request shape for every command |
| `examples/intents/` | Copy-paste intents: `player_with_icon.json`, `wasd_movement.json`, `project_bootstrap.json`, `hud_top_bar.json` |
