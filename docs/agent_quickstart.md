# godot-cli agent quickstart

One-page guide for LLM agents. Full detail: `agent_scene_authoring.md` in the same directory.

## Setup (no source tree required)

```bash
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
source "$HOME/.godot-cli/env.sh"
godot-cli ping --json
```

That downloads the released binary for the platform, verifies it against the release checksums, and installs to `~/.godot-cli`. From a checkout, `./install.sh` builds instead.

Add `--install-skill` to copy `godot-scene-authoring` to Cursor, Claude Code, OpenCode, and `~/.agents/skills/`. Refresh later with `install.sh --skills-only`.

Environment variables set by `env.sh`:

| Variable | Purpose |
|----------|---------|
| `GODOT_CLI` | Absolute path to binary |
| `GODOT_CLI_HOME` | Install root (`~/.godot-cli`) |
| `GODOT_CLI_TEMPLATES_ROOT` | Built-in scene templates |

`env.sh` also puts `godot-cli` on `PATH`, loads shell completions, and adds the man page to `MANPATH` (`man godot-cli`). The full command reference is at `$GODOT_CLI_HOME/docs/commands.md`.

Work from the **Godot project root** (folder containing `project.godot`). Pass `--json` on every command.

### `--project-root` — when to pass it

| Commands | `--project-root` |
|----------|------------------|
| `scene apply`, `scene plan`, `scene new`, `scene node add/remove/…`, `scene instance add`, `scene set-property`, `catalog *` | **Pass** — needed for `res://`, catalog ids, UID cache, save prep |
| `scene validate`, `scene inspect`, `scene refs` | **Pass** — enables UID cache and `res://` resolution checks |
| `project input *` | **Pass** — reads/writes `project.godot` under the project root |
| `project settings *`, `project autoload *` | **Pass** — main scene, display, layer names, autoloads |

Common `project.godot` keys: `application` → `run/main_scene`, `config/name`; `display` → `window/size/viewport_width`, `window/size/viewport_height`, `window/stretch/mode`; `rendering` and `physics` take the aliases in `project rendering apply` / `project physics apply`. `project apply` takes one intent with `settings`, `input`, `autoload`, `plugins`, `rendering`, and `physics` sections (`$GODOT_CLI_HOME/examples/intents/project_bootstrap.json`).
| `scene node list`, `scene node get`, `scene diff` | **Optional** — accepted for uniformity; ignored (file-only reads) |

Agents may pass `--project-root .` on all scene commands when working inside a Godot project; it is only *required* for writes, catalog, and validation that touches project paths.

## North star

Persist scene hierarchy in `.tscn` files — the same structure a human builds in the Godot editor. Do **not** use `load().instantiate()` in `_ready()` for static UI or level layout.

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

## Resources (.tres)

Materials, themes, shapes, and any other Resource are `.tres` files, and they are authored the same way as scenes:

```bash
godot-cli resource new --output materials/wood.tres --type StandardMaterial3D \
  --property albedo_color --value "Color(0.6, 0.4, 0.2, 1)" --property roughness --value 0.8 --project-root .
godot-cli resource sub add themes/main.tres --type StyleBoxFlat \
  --property bg_color --value "Color(0.1, 0.1, 0.1, 1)" --project-root . --json   # returns the id
godot-cli resource set-property themes/main.tres --property Button/styles/normal \
  --value 'SubResource("StyleBoxFlat_xxxxx")' --project-root .
godot-cli resource ext add themes/main.tres --type FontFile --path res://fonts/ui.ttf --project-root .
godot-cli resource inspect themes/main.tres --json
```

Theme entries are `Type/category/name` properties on the resource: `Button/styles/normal`, `Label/colors/font_color`, `Label/font_sizes/font_size`. Do not hand-write `.tres` text.

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
godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 60 --log-file capture/godot.log --no-header
```

Read the highest-numbered `capture/shot*.png` and `capture/godot.log`. Sixty frames is one second at 60 FPS, long enough for gravity and a camera to settle; five is enough for a static UI screen. The log holds every `print()`, `push_warning`, `push_error`, and script error with a backtrace; any `ERROR` or `SCRIPT ERROR` line means the change is not done. Without a display, drop `--write-movie` and add `--headless` to get the log alone.

## Standard workflow

```text
1. scene node list <scene.tscn> --json          # --project-root optional (ignored)
2. catalog list --project-root . --json          (if using project catalog)
3. edit via scene * commands or scene apply --intent
4. scene validate <scene.tscn> --project-root . --json
5. scene node list <scene.tscn> --json           (confirm)
```

## Common commands

```bash
# New 2D scene (root viewport path = /root/Main)
godot-cli scene new --output scenes/main.tscn \
  --root-name Main --root-type Node2D --project-root .

# Template scaffold (templates from GODOT_CLI_HOME)
godot-cli scene template list --json
godot-cli scene template copy 2d/top_down_player \
  --output scenes/player.tscn --project-root .

# Plan + apply intent (recipes expand to patch ops)
godot-cli scene plan scenes/main.tscn \
  --intent intents/hud.json --project-root . --json

godot-cli scene apply scenes/main.tscn \
  --intent intents/hud.json --project-root . --json

# Dry-run preview
godot-cli scene apply scenes/main.tscn --intent intents/hud.json \
  --dry-run --preview-properties --project-root . --json

# Instance project catalog entry
godot-cli catalog show ui/button --project-root . --json
godot-cli scene instance add scenes/main.tscn \
  --parent /root/Main --name StartButton --catalog-id ui/button --project-root .

# Batch (apply → validate → list)
godot-cli batch --file workflow.json --json

# Input Map (WASD / joypad for player movement scripts)
godot-cli project input list --project-root . --json
godot-cli project input apply --project-root . \
  --intent intents/wasd_movement.json --dry-run --json
godot-cli project input apply --project-root . \
  --intent intents/wasd_movement.json --json
godot-cli project input validate --project-root . --json

# Main scene, display, layer names, autoloads
godot-cli project settings apply --project-root . --intent intents/main_scene.json --json
godot-cli project autoload apply --project-root . --intent intents/autoload_game_state.json --json

# Editor plugins + rendering + physics
godot-cli project plugins enable --project-root . --plugin my_addon --json
godot-cli project rendering apply --project-root . --intent intents/rendering_forward_plus.json --json
godot-cli project physics apply --project-root . --intent intents/physics_jolt.json --json

# Unified bootstrap (one intent, multiple sections)
godot-cli project show --project-root . --json
godot-cli project apply --project-root . --intent intents/project_bootstrap.json --dry-run --json
```

Copy `wasd_movement.json` from `$GODOT_CLI_HOME/examples/intents/`. Use with a movement script that calls `Input.get_vector("move_left", "move_right", "move_up", "move_down")`. Re-applying the same intent is idempotent (replaces each action by name).

## UI authoring (editor parity)

1. **Scene properties first** — font size, colors, min size, anchors, margins via `scene apply` / `node_set` / instance overrides. Do not set static theme look only in `_ready()`.
2. **Reusable widgets** — root script is `@tool`; `@export` fields use setters that push into child Controls (`get_node_or_null`). Instance overrides then preview in-editor.
3. **Unique names** — `--unique-name` on `scene node add` / `instance add`, or `unique_name_in_owner` via `node_set`. Reference with `%Name` from owner scripts.
4. **Bars / HUDs** — `Bar (Control)` → `ColorRect` + `MarginContainer` → content. Full-width: top-wide anchors; padding via MarginContainer theme margins.
5. **Quoted strings in patches** — instance override text values need Godot quotes: `"value": "\"Score\""`. JSON `properties` on `add_node` use plain JSON strings.

Example: `$GODOT_CLI_HOME/examples/intents/hud_top_bar.json`. Full detail: `agent_scene_authoring.md`.

## Intent recipes

`player_2d`, `camera_2d`, `ui_panel`, `tilemap_layer`, `audio_player`, `instance_catalog`, `instance_scene`, `catalog_button`, `assign_ext`, `instance_override`, `node_set`, `add_node`

`player_2d` optional: `texture` / `sprite_texture` / `texture_path` (e.g. `res://icon.svg`).

Example intent (`intents/hud.json`):

```json
{
  "steps": [
    { "recipe": "player_2d", "parent": "/root/Main", "name": "Player", "radius": 10.0 },
    { "recipe": "camera_2d", "parent": "/root/Main", "name": "Camera" }
  ]
}
```

Copy examples from `$GODOT_CLI_HOME/examples/intents/` (`player_with_icon.json`, `assign_sprite_texture.json`).

**Parent paths** always start with `/root/<SceneRootName>/`. Run `scene node list` first if unsure of the root name.

## Common follow-ups

| Task | Approach |
|------|----------|
| Attach script | `assign_ext` recipe/op, or `player_2d` + `"script": "res://…gd"` |
| Assign sprite texture | `assign_ext` or `player_2d` + `"texture": "res://icon.svg"` |
| Tint a sprite | `modulate` on `node_add` / `node_set` (e.g. `Color(0.25, 1, 0.35, 1)`) or `player_2d` + `"modulate"` |
| Second character body | Repeat `player_2d` with a different `name` — shape ids are per-node; shared textures reuse the same `ext_resource` |
| Reuse existing texture | `assign_ext` dedupes by `res://` path; in patches you may also set `ExtResource("<existing_id>")` from `scene inspect` / `scene refs` |
| Instance catalog UI | `scene instance add --catalog-id` |
| Player WASD + joypad | Write `scripts/player.gd`, attach via `player_2d`/`assign_ext`, then `project input apply` with `wasd_movement.json` |
| Set main scene | `project settings apply` with `main_scene.json` or `settings set --section application --key run/main_scene --value res://…` |
| Game singleton | `project autoload apply` with `autoload_game_state.json` |
| Physics layer names | `project settings apply` with `physics_layers.json` |
| Enable editor plugin | `project plugins enable --plugin <addon_name>` (addon must exist under `addons/`) |
| Rendering backend | `project rendering apply` with `rendering_forward_plus.json` |
| Physics engine (e.g. Jolt) | `project physics apply` with `physics_jolt.json` |
| Bootstrap project config | `project apply` with `project_bootstrap.json` (settings + input + autoload + rendering + physics) |
| Project overview | `project show --json` |
| HUD / Control styling | Scene properties (`theme_override_*`, anchors, `custom_minimum_size`) — not `_ready()` only; see `agent_scene_authoring.md` § UI authoring |
| Reusable UI widget | `@tool` script + export setters; instance overrides on root exports |
| Unique node paths in scripts | `--unique-name` on `scene node add` / `instance add`, or `unique_name_in_owner` via `node_set` → `%Name` |
| HUD top bar layout | `hud_top_bar.json` intent example |

`player_2d` optional fields: `texture` / `sprite_texture` / `texture_path`, `modulate`, `position`, `script`, `shape_id_hint`, `radius`, `sprite` (bool).

Writes run **save preparation** by default (ext/sub section order, node parent-before-child order, id repair). Use `scene normalize` to re-run prep on an existing file; `--no-prepare-save` only for tests.

**Node section order:** Godot instantiates nodes in file order. If `scene validate` reports `node_parent_order`, run `scene normalize` — do not use Godot headless as a scene pretty-printer. Add new parent nodes before reparenting children onto them when building multi-step patches.

See `agent_scene_authoring.md` → “Wiring external resources” and “Multiple character bodies”.

## Catalog rules

| Kind | Id example | How to use |
|------|------------|------------|
| Project entry | `ui/button` | `scene instance add --catalog-id ui/button` |
| Builtin (docs only) | `godot/ui/Button` | `scene node add --type Button` — never `--catalog-id` |

## Batch JSON

```json
{
  "mode": "stop",
  "steps": [
    { "argv": ["scene", "apply", "scenes/main.tscn", "--intent", "intents/hud.json", "--project-root", ".", "--json"] },
    { "argv": ["scene", "validate", "scenes/main.tscn", "--project-root", ".", "--json"] }
  ]
}
```

Use `batch --file`, not top-level `--request`. See `agent_batch_commands.md`.

## Tool reference

`mcp_tools.json` in this directory — every command with example JSON argv.

## Anti-patterns

- Hand-editing `[node]` / `parent=` / `instance=` lines when a CLI command exists
- Instancing `godot/…` builtin ids
- Skipping `scene validate` after edits
- Forgetting `--project-root` when using `res://` or catalog ids
- Using Godot headless to rewrite `.tscn` node order — use `scene normalize` instead
