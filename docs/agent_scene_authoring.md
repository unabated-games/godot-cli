# Agent guide: scene authoring with godot-cli

**Audience:** LLM agents, automation scripts, and humans wiring MCP tools.

**North star:** Author scenes the way a human would in the Godot editor — structure lives in `.tscn`, not in `_ready()` spawns. See [ABOUT.md — North star](ABOUT.md#north-star-editor-like-scene-authoring).

**Tool reference:** [`mcp_tools.json`](mcp_tools.json) lists every command with example `--request` JSON.

---

## Golden rules

1. **Persist the tree in the file.** Use `scene node add`, `scene instance add`, `scene ext add`, `scene sub add`, and `scene set-property`. Do not `load().instantiate()` static UI or level layout in GDScript.
2. **Discover before editing.** `scene node list`, `scene inspect`, `catalog list`, `catalog show <id>`.
3. **Validate after editing.** `scene validate --project-root .` — fix errors before moving on.
4. **Prefer catalog ids for project UI.** `catalog show ui/button` then `scene instance add … --catalog-id ui/button`.
5. **Use builtins for raw Godot nodes.** `godot/ui/Button` is document-only — `scene node add --type Button`, not instancing.
6. **One command per concern, or a patch.** Sequential CLI calls are fine; for many edits use `scene apply --patch patch.json` (see [Patch format](#patch-format)).
7. **Parent-before-child section order.** Godot loads `[node]` sections in file order; a child's `parent=` must refer to a node already declared above it (`packed_scene.cpp` — “parent path has vanished”). `node_add` and `node_reparent` keep loadable order; save prep / `scene normalize` re-sort if needed. **Never** use Godot headless to “fix” section order — run `scene validate` (fails with `node_parent_order`) then `scene normalize`. When patching manually, add parent nodes before children.

---

## Standard workflow

```text
catalog export --project-root .     # optional: refresh AGENTS.md digest
scene node list main.tscn --json     # understand current tree (--project-root optional)
… edit via scene * commands …        # use --project-root .
scene validate main.tscn --project-root .
scene node list main.tscn --json     # confirm result
```

Always pass `--project-root` when resolving `res://` paths, catalog ids, UID cache checks, or saving scenes. It is optional (and ignored) on file-only reads: `scene node list`, `scene node get`, `scene diff`.

---

## Recipe: new empty scene

```bash
godot-cli scene new --output scenes/main.tscn \
  --root-name Main --root-type Node2D --project-root .
```

Root viewport path is `/root/Main`. Direct children use `--parent /root/Main`.

---

## Recipe: add a 2D player body

```bash
# Body
godot-cli scene node add scenes/main.tscn \
  --parent /root/Main --name Player --type CharacterBody2D \
  --project-root .

# Collision shape (sub-resource + node)
godot-cli scene sub add scenes/main.tscn \
  --type CapsuleShape2D --property radius --value 8.0 \
  --project-root .

godot-cli scene node add scenes/main.tscn \
  --parent /root/Main/Player --name Collision --type CollisionShape2D \
  --property shape --value 'SubResource("CapsuleShape2D_<id>")' \
  --project-root .

# Sprite
godot-cli scene node add scenes/main.tscn \
  --parent /root/Main/Player --name Sprite --type Sprite2D \
  --project-root .
```

Use `scene sub add` JSON output or `scene inspect --json` to read the generated sub-resource id. Prefer a **patch** (below) when you need stable `id_hint` wiring in one step.

---

## Recipe: attach a script

```bash
godot-cli scene ext add scenes/main.tscn \
  --type Script --path res://player.gd --project-root .

godot-cli scene set-property scenes/main.tscn \
  --node-name Player --property script --value 'ExtResource("<ext_id>")' \
  --project-root .
```

Or combine in one `node add` with `--property script --value 'ExtResource("…")'`.

**Reusable UI widgets:** if the script drives child Controls from `@export` fields, use `@tool` + export setters (see [UI authoring (editor parity)](agent_scene_authoring.md#ui-authoring-editor-parity)). Attach the script, then set presentation via scene properties — not only `_ready()` overrides.

---

## Recipe: player movement input (Input Map)

Movement scripts that use `Input.get_vector("move_left", "move_right", "move_up", "move_down")` need those actions in **Project Settings → Input Map** (`[input]` in `project.godot`). godot-cli can apply them without hand-editing the project file.

```bash
# Discover existing actions (avoid clobbering ui_* defaults)
godot-cli project input list --project-root . --json

# Preview
godot-cli project input apply --project-root . \
  --intent intents/wasd_movement.json --dry-run --json

# Write project.godot
godot-cli project input apply --project-root . \
  --intent intents/wasd_movement.json --json

godot-cli project input validate --project-root . --json
```

Copy `wasd_movement.json` from `$GODOT_CLI_HOME/examples/intents/`. Semantics:

- **Per-action replace** — each `name` in the intent overwrites that action’s block; other actions are untouched.
- **Idempotent** — safe to re-run in agent loops.
- **Event types** — `key` (`keycode`: `A`, `KEY_W`, `ArrowUp`, …), `joypad_button` (`dpad_left`, `a`, …), `joypad_motion` (`left_x` / `left_y` + `axis_value`).

Typical workflow: write `scripts/player.gd` on disk → attach via `player_2d` / `assign_ext` → `project input apply` → run the game.

### `project plugins` (enable/disable only)

Addon must already exist at `addons/<name>/plugin.cfg` — godot-cli does not install from the Asset Library.

```json
{
  "enable": ["my_addon"],
  "disable": ["old_plugin"]
}
```

```bash
godot-cli project plugins list --project-root . --json
godot-cli project plugins enable --project-root . --plugin my_addon --json
godot-cli project plugins apply --project-root . --intent intents/enable_plugins.json --json
```

### `project rendering`

```json
{
  "method": "forward_plus",
  "method_mobile": "mobile",
  "driver_windows": "d3d12"
}
```

Aliases: `method` → `renderer/rendering_method`, `method_mobile` → `renderer/rendering_method.mobile`, `driver_windows` → `rendering_device/driver.windows`, etc.

```bash
godot-cli project rendering apply --project-root . --intent intents/rendering_forward_plus.json --json
```

### `project physics`

```json
{
  "engine_3d": "Jolt Physics",
  "gravity_3d": 980
}
```

Aliases: `engine_3d` → `3d/physics_engine`, `gravity_3d` → `3d/default_gravity`, `engine_2d` → `2d/physics_engine`, etc.

```bash
godot-cli project physics apply --project-root . --intent intents/physics_jolt.json --json
```

### `project apply` (unified)

One intent file can combine any subset of section keys. Each subsection uses the same shape as the standalone `project <section> apply` command.

```json
{
  "settings": { "application": { "run/main_scene": "res://scenes/main.tscn" } },
  "input": { "actions": [ { "name": "move_left", "events": [ { "type": "key", "keycode": "A" } ] } ] },
  "autoload": { "autoloads": [ { "name": "GameState", "path": "res://scripts/game_state.gd" } ] },
  "rendering": { "method": "forward_plus" },
  "physics": { "engine_3d": "Jolt Physics" }
}
```

```bash
godot-cli project show --project-root . --json
godot-cli project apply --project-root . --intent intents/project_bootstrap.json --json
```

### `project settings` intent shape

```json
{
  "application": {
    "run/main_scene": "res://scenes/main.tscn"
  },
  "display": {
    "window/stretch/mode": "canvas_items",
    "window/size/viewport_width": 1280
  },
  "layer_names": {
    "2d_physics/layer_1": "player",
    "2d_physics/layer_2": "enemy"
  }
}
```

```bash
godot-cli project settings apply --project-root . --intent intents/main_scene.json --json
godot-cli project settings get --project-root . --section application --key run/main_scene --json
```

### `project autoload` intent shape

```json
{
  "autoloads": [
    { "name": "GameState", "path": "res://scripts/game_state.gd", "singleton": true }
  ]
}
```

Set `"replace_all": true` to remove autoloads not listed in the intent (use sparingly).

```bash
godot-cli project autoload list --project-root . --json
godot-cli project autoload apply --project-root . --intent intents/autoload_game_state.json --json
```

---

## UI authoring (editor parity)

Agents can build Control trees with godot-cli, but **static look-and-feel must live in the `.tscn`**, not only in `_ready()` GDScript. Runtime code is for **dynamic** updates (score ticking, health bars); the editor and instance preview should match Play without running the game.

### 1. Scene properties first (not `_ready()` styling)

**Do** — set on nodes via `scene set-property`, patch `node_set`, or intent `properties` / `instance_override`:

| Property family | Examples |
|-----------------|----------|
| Theme fonts | `theme_override_font_sizes/font_size` |
| Theme margins | `theme_override_constants/margin_left` (and `_right`, `_top`, `_bottom`) |
| Layout | `anchors_preset`, `anchor_*`, `offset_*`, `size_flags_horizontal`, `size_flags_vertical` |
| Sizing | `custom_minimum_size` (e.g. `Vector2(160, 0)` for stable HUD cells) |
| Color | `modulate`, `color` (on `ColorRect`) |

**Don't** — presentation defaults only in script:

```gdscript
func _ready() -> void:
    $Label.add_theme_font_size_override("font_size", 35)  # editor never sees this
```

### 2. Reusable widgets: `@tool` + export setters

For packed scenes with root exports (`label`, `number`, …) that drive child Controls:

- Script must be `@tool`.
- Each `@export` uses a setter that calls `_apply_*()` with `get_node_or_null` (not bare `@onready` in apply helpers).
- **Mutate via root exports** with `instance_override` / `node_set` on the instance — do not only set child `text` and ignore exports.

**@tool checklist when attaching a script to a reusable UI widget:**

1. Add `@tool` at top of script.
2. Export fields use setters → `_apply_*()` helpers.
3. `_ready()` calls the same `_apply_*()` once.
4. Apply helpers use `get_node_or_null("ChildName")` so editor preview works before full ready.
5. Instance overrides target **export names** on the instance root (`label`, `number`, …).

### 3. Unique names (`%Name`) for script references

Brittle paths break when layout changes (`$HUD/HBox/Score` → `$HUD/Bar/Margin/HBox/Score`). Prefer **Access as Unique Name** on HUD roots and reference `%Score` from the owner script.

**godot-cli:**

```bash
# CLI flag on add / instance
godot-cli scene node add main.tscn --parent /root/Main/HUD --name Score --type Label \
  --unique-name --project-root .

# Intent add_node
{ "recipe": "add_node", "name": "Score", "type": "Label", "unique_name": true, … }

# Patch / node_set
{ "op": "node_set", "path": "/root/Main/HUD/Score", "property": "unique_name_in_owner", "value": "true" }
```

### 4. Layout patterns (bars / HUDs)

| Goal | Structure |
|------|-----------|
| Full-width top bar | `Control` with top-wide anchors (`anchors_preset` 10) → background + content siblings |
| Background behind content | `ColorRect` (full rect, first child) + `MarginContainer` (full rect) |
| Content padding | `theme_override_constants/margin_*` on `MarginContainer`, not only HBox offsets |
| Left / center / right stats | `HBox`: fixed-width item, expand spacer (`size_flags_horizontal` 3), item, spacer, item |
| Stable cell width | `custom_minimum_size` on widget root |

Example intent: `share/examples/intents/hud_top_bar.json` (CanvasLayer → bar → ColorRect + Margin → Label with theme overrides and `unique_name`).

### 5. Quoted strings in patches and intents

Godot `.tscn` string properties need Godot-quoted values in patch/intent `value` fields:

```json
{ "recipe": "instance_override", "path": "/root/Main/HUD/ScoreCell", "property": "label", "value": "\"Score\"" }
```

Bare `Score` corrupts or mis-parses text properties. The same rule applies in `node_add` / `properties` objects: a string value carries its own quotes, `"text": "\"Score: 0\""`, and a bare `"Score: 0"` is rejected with `invalid_property_value` before anything is written. Numbers and booleans are plain JSON (`"visible": false`, `"offset_left": 8.0`).

---

## Wiring external resources (general pattern)

Many node properties point at **files on disk** via `ext_resource`. The pattern is always:

```text
1. scene ext add   → register res://path
2. scene set-property (or patch node_set) → property = ExtResource("id")
```

| Goal | `ext_add --type` | Node property | Path example |
|------|------------------|---------------|--------------|
| Script | `Script` | `script` | `res://player.gd` |
| Sprite image | `Texture2D` | `texture` | `res://icon.svg` |
| Audio | `AudioStream` | `stream` | `res://click.wav` |
| TileSet | `TileSet` | `tile_set` | `res://world.tiles.tres` |

**Texture type rule:** For PNG/SVG/etc., use `ext_resource type="Texture2D"` with the **source** `res://` path (e.g. `res://icon.svg`). Godot’s import pipeline handles `CompressedTexture2D` internally — do not point at `.godot/imported/…` unless you have a special reason.

**Inline shapes** (collision, etc.) use `sub_resource` instead — see `player_2d` / patch examples.

### One-shot via intent

`assign_ext` — wire any external file to a node property:

```json
{
  "recipe": "assign_ext",
  "path": "/root/Main/Player/Sprite",
  "property": "texture",
  "ext_type": "Texture2D",
  "res_path": "res://icon.svg",
  "id_hint": "icon"
}
```

`player_2d` accepts optional `texture`, `sprite_texture`, or `texture_path` to assign a sprite image in the same step. Also: `modulate`, `position`, `script`, and `shape_id_hint` (defaults to `{name}_shape` for collision sub-resources).

### Reusing an existing `ext_resource`

When a `res://` path is already registered, `assign_ext` (recipe or patch op) **reuses** the existing id — safe for multiple nodes sharing art. You can also reference a known id directly in patch `node_add` / `node_set` properties, e.g. `ExtResource("Texture2D_icon")`. Discover ids with `scene inspect`, `scene refs`, or prior command JSON output.

### Multiple character bodies

Call `player_2d` once per `CharacterBody2D`. Each invocation gets its own collision `sub_resource` id (`CapsuleShape2D_{name}_shape` by default). Shared textures/scripts dedupe by path via `assign_ext`. For layouts beyond the recipe, use explicit patch ops (`node_add`, `sub_add`, `assign_ext`).

---

## Recipe: assign texture to Sprite2D

Stock Godot projects ship with `icon.svg` at the project root.

**CLI (two steps):**

```bash
godot-cli scene ext add scenes/main.tscn \
  --type Texture2D --path res://icon.svg --project-root .

godot-cli scene set-property scenes/main.tscn \
  --node-name Sprite --parent Player --property texture \
  --value 'ExtResource("<ext_id>")' --project-root .
```

Read `<ext_id>` from `scene ext add --json` output, or use a patch / intent with `id_hint` (below).

**Intent (one apply):**

```bash
godot-cli scene apply scenes/main.tscn \
  --intent intents/assign_sprite_texture.json --project-root . --json
```

Example intent (`assign_sprite_texture.json`):

```json
{
  "steps": [
    {
      "recipe": "assign_ext",
      "path": "/root/Main/Player/Sprite",
      "property": "texture",
      "ext_type": "Texture2D",
      "res_path": "res://icon.svg",
      "id_hint": "icon"
    }
  ]
}
```

**Player + icon in one intent** (`player_with_icon.json`):

```json
{
  "steps": [
    {
      "recipe": "player_2d",
      "parent": "/root/Main",
      "name": "Player",
      "texture": "res://icon.svg"
    },
    { "recipe": "camera_2d", "parent": "/root/Main", "name": "Camera" }
  ]
}
```

**Patch (`id_hint` wires ext + property without parsing JSON between steps):**

```json
{
  "ops": [
    { "op": "ext_add", "type": "Texture2D", "path": "res://icon.svg", "id_hint": "icon" },
    {
      "op": "node_set",
      "path": "/root/Main/Player/Sprite",
      "property": "texture",
      "value": "ExtResource(\"Texture2D_icon\")"
    }
  ]
}
```

Copy examples from `$GODOT_CLI_HOME/examples/intents/` and `$GODOT_CLI_HOME/examples/patches/`.

---

## Recipe: instance project UI from catalog

```bash
# 1. Discover
godot-cli catalog show ui/button --project-root . --json

# 2. Instance (writes ext_resource + instance=ExtResource in .tscn)
godot-cli scene instance add scenes/main.tscn \
  --parent /root/Main --name StartButton \
  --catalog-id ui/button --project-root .

# 3. Optional: editable children (adds [editable path="…"] for editor overrides)
godot-cli scene instance add scenes/hud.tscn \
  --parent /root/HUD --name StartButton \
  --catalog-id ui/button --editable --project-root .
```

After instancing, set exports on the root script via `scene set-property` if `catalog show` lists `@export` fields.

**Do not** spawn the same button in GDScript:

```gdscript
# WRONG for authored UI
func _ready() -> void:
    add_child(load("res://ui/button/button.tscn").instantiate())
```

---

## Recipe: raw Godot control (builtin)

When the catalog says `when_not_to_use` for a project entry, or you need a debug-only control:

```bash
godot-cli catalog show godot/ui/Button --json
godot-cli scene node add scenes/debug.tscn \
  --parent /root/Main --name DebugButton --type Button \
  --project-root .
```

Builtins are **never** instanced with `--catalog-id`.

---

## Recipe: reparent / rename / remove

```bash
godot-cli scene node reparent scenes/main.tscn /root/Main/Player/Sprite \
  --parent /root/Main --project-root .

godot-cli scene node rename scenes/main.tscn /root/Main/Player \
  --name Hero --project-root .

godot-cli scene node remove scenes/main.tscn /root/Main/OldNode \
  --recursive --project-root .
```

Viewport paths always start with `/root/<SceneRootName>/…`.

---

## Recipe: fix parenting mistakes

Symptoms: node missing in editor, validate errors, wrong hierarchy.

```bash
godot-cli scene node list broken.tscn --json
godot-cli scene inspect broken.tscn --json
```

Check:

| Symptom | Fix |
|---------|-----|
| Node under wrong parent | `scene node reparent` |
| Duplicate sibling name | `scene node rename` |
| Orphan section | `scene node remove` or fix `parent` via reparent |
| Missing ext/sub ref | `scene ext add` / `scene sub add`, then `set-property` |

---

## Patch format

Apply multiple edits in one transaction:

```bash
godot-cli scene apply scenes/main.tscn --patch patches/player.json \
  --project-root . --output scenes/main.tscn
```

### Plan first (intent → patch, no write)

```bash
# Expand recipes to patch JSON; preview against existing scene
godot-cli scene plan scenes/main.tscn \
  --intent intents/hud.json --project-root . --json

# Write patch file for review, then apply
godot-cli scene plan scenes/main.tscn \
  --intent intents/hud.json --write-patch patches/generated.json --project-root .
godot-cli scene apply scenes/main.tscn --patch patches/generated.json --project-root .
```

**Intent recipes:** `add_node`, `connect`, `static_body_2d`, `instance_catalog`, `instance_scene`, `node_set`, `assign_ext`, `instance_override`, `catalog_button`, `player_2d`, `camera_2d`, `ui_panel`, `tilemap_layer`, `audio_player`  

To lift part of a scene into a reusable widget, `scene extract <scene> /root/Main/HUD --output ui/hud.tscn --catalog-id ui/hud --project-root .` moves the subtree with its properties, resources, and inner connections into the new file and instances it back in place; connections that crossed the boundary are listed for you to re-add from the parent. `godot-cli scene recipes --json` lists every recipe with its required and optional fields (over MCP: `godot-cli://docs/recipes`). `static_body_2d` takes `color` for a visible fill. The `instance_catalog` and `instance_scene` recipes, and the `instance_add` op, take an optional `properties` object set on the instance root in the same write (anchors, offsets, exported overrides); `scene instance add --properties` does the same from the command line. An unknown recipe fails as `unknown_recipe` with the known names in `details.hint`.  
**Passthrough:** intent file with `"ops": [ … ]` same as patch format  
**Direct op in steps:** `{ "op": "node_add", … }` without `recipe`

### Apply intent in one step

```bash
godot-cli scene apply scenes/main.tscn --intent intents/hud.json --project-root .
```

Equivalent to `scene plan` + `scene apply` without writing an intermediate patch file.

### Snapshots and undo

```bash
# Save snapshot + undo patch while applying
godot-cli scene apply scenes/main.tscn --patch patches/out.json \
  --auto-snapshot --write-undo-patch patches/undo.json --project-root .

# Full file restore from snapshot
godot-cli scene restore scenes/main.tscn --from scenes/main.tscn.godot-cli-snapshot

# Or apply the generated undo patch
godot-cli scene apply scenes/main.tscn --patch patches/undo.json --project-root .
```

Undo patches reverse `node_add`, `instance_add`, `node_set`, `node_remove`, `node_rename`, `node_reparent`, and forward `ext_add`/`sub_add` via `ext_remove`/`sub_remove`. Removing resources records `ext_add`/`sub_add` undo ops when `--record-undo` is set.

### Dry-run apply with diff preview

```bash
godot-cli scene apply scenes/main.tscn --patch patches/out.json \
  --dry-run --preview-properties --project-root . --json
```

Response includes `preview_diff` with the same shape as `scene diff` (`nodes`, `property_diff_count`, etc.) comparing the scene before and after the patch (save preparation applied to both sides).

### Batch multiple commands

See **[agent_batch_commands.md](agent_batch_commands.md)** — `godot-cli batch --file workflow.json` runs apply → validate → diff in one call with `stop`, `continue`, or `atomic` failure handling.

### Diff node trees and properties

```bash
godot-cli scene diff scenes/before.tscn scenes/after.tscn --properties --json
```

Node diffs: `added`, `removed`, `type_changed`  
Property diffs (with `--properties`): `property_added`, `property_removed`, `property_changed`

### Recipe examples

`tilemap_layer` — optional `with_tilemap`, `tilemap_name`, `tileset`  
`audio_player` — optional `stream`, `autoplay`, `volume_db`, `spatial` (`2d` / `3d`)

`patches/player.json`:

```json
{
  "ops": [
    {
      "op": "node_add",
      "parent": "/root/Main",
      "name": "Player",
      "type": "CharacterBody2D"
    },
    {
      "op": "sub_add",
      "type": "CapsuleShape2D",
      "id_hint": "shape",
      "properties": { "radius": 8.0 }
    },
    {
      "op": "node_add",
      "parent": "/root/Main/Player",
      "name": "Collision",
      "type": "CollisionShape2D",
      "properties": {
        "shape": "SubResource(\"CapsuleShape2D_shape\")"
      }
    },
    {
      "op": "ext_add",
      "type": "Script",
      "path": "res://player.gd",
      "id_hint": "script"
    },
    {
      "op": "node_set",
      "path": "/root/Main/Player",
      "property": "script",
      "value": "ExtResource(\"Script_script\")"
    },
    {
      "op": "instance_add",
      "parent": "/root/Main",
      "name": "StartButton",
      "catalog_id": "ui/button"
    }
  ]
}
```

### Property values are Variant text

Every `properties` value, `node_set` value, and `instance_override` value is Godot Variant text, not a plain string. `"Vector2(1, 2)"` is a vector, `"true"` is a bool, `"1.5"` is a float, and a string carries its own quotes: `"\"Paused\""`. A bare word such as `"Paused"` is rejected before anything is written:

```json
{ "ok": false, "failure": { "kind": "invalid_property_value",
  "details": { "op": "node_add", "field": "text", "value": "Paused",
               "hint": "not valid Variant text; for a string write \"\\\"Paused\\\"\"" } } }
```

A missing required field fails the same way with `"kind": "missing_field"` and the op and field in `details`. The CLI commands (`set-property`, `node add --property`, `sub add --property`) apply the same check unless `--raw-value` is passed.

### Patch op reference

| `op` | Required fields | Notes |
|------|-----------------|-------|
| `node_add` | `parent`, `name`, `type` | Optional `properties` object; set `unique_name_in_owner`: true for `%Name` access |
| `node_remove` | `path` | Optional `recursive`: true |
| `node_rename` | `path`, `name` | |
| `node_reparent` | `path`, `parent` | Viewport path for new parent |
| `node_set` | `path`, `property`, `value` | |
| `ext_add` | `type`, `path` | Optional `id_hint` → id `{Type}_{hint}` (e.g. `Texture2D_icon`) |
| `ext_remove` | `id` | Fails if resource is referenced |
| `sub_add` | `type` | Optional `id_hint` → id `{Type}_{hint}`; optional `properties` |
| `sub_remove` | `id` | Fails if resource is referenced |
| `instance_add` | `parent`, `name` | `scene` **or** `catalog_id`; optional `editable` |
| `instance_override` | `path`, `property`, `value` | Optional `child` + `type` for editable child nodes; optional `editable`: false |
| `connection_add` | `from`, `signal`, `to`, `method` | Viewport paths; optional `deferred`, `one_shot` (bools), `binds` (array text), `unbinds` (int) |
| `connection_remove` | `from`, `signal`, `to` | Optional `method`; without it every connection of that signal between the nodes goes |

`id_hint` lets later ops reference stable ids in `ExtResource("…")` / `SubResource("…")` strings.

Options: `--dry-run` (apply in memory + `preview_diff`), `--preview-properties` (property diffs in dry-run), `--strict` (stop on first error, default).

### Scene templates

```bash
godot-cli scene template list --json
godot-cli scene template show 2d/character_body --json
godot-cli scene template copy 2d/character_body --output scenes/player.tscn \
  --rename-node Player:Hero \
  --set-property '/root/Hero/visible=false' \
  --project-root .
```

Built-in templates: `2d/character_body`, `2d/top_down_player`, `2d/camera_rig`, `3d/static_body`, `ui/control_root`.

`template show` returns `nodes` and `sections` (inspect-style). Use `--content` for raw `.tscn` text.

`--set-property` formats: `/root/Node/prop=value` or `/root/Node|prop|value` (comma-separated for multiple).

### Intent recipes (instance overrides)

| Recipe | Purpose |
|--------|---------|
| `instance_override` / `instance_set` | Maps to `instance_override` patch op (`path`, `property`, `value`; optional `child`, `type`, `editable`) |
| `catalog_button` | `instance_add` from catalog + optional `label` / `label_text` on child `Label` |

```json
{
  "steps": [
    {
      "recipe": "catalog_button",
      "parent": "/root/Main",
      "name": "StartButton",
      "catalog_id": "ui/button",
      "label": "Start Game"
    }
  ]
}
```

---

## Recipe: static body (ground, platform, wall)

```json
{ "recipe": "static_body_2d", "parent": "/root/Main", "name": "Ground",
  "position": "Vector2(320, 352)", "size": "Vector2(640, 16)", "texture": "res://art/ground.svg" }
```

Expands to a `StaticBody2D`, a `RectangleShape2D` sub-resource of `size` with its `CollisionShape2D`, and, when `texture` is given, a `Sprite2D` tiled across `size` (`region_enabled`, `region_rect`, `texture_repeat`). `size` defaults to `Vector2(64, 16)`.

## Signal connections

Wiring a button belongs in the scene, not in `_ready()`. The editor writes a `[connection]` section per connected signal, and so does godot-cli:

```bash
godot-cli scene connection add scenes/main.tscn --from /root/Main/Menu/Resume --signal pressed \
  --to /root/Main/Menu --method _on_resume_pressed --project-root .
godot-cli scene connection list scenes/main.tscn --json
```

```
[connection signal="pressed" from="Menu/Resume" to="Menu" method="_on_resume_pressed"]
```

The receiving node needs a script with that method; godot-cli writes the connection, it does not write GDScript. `--deferred`, `--one-shot`, `--binds '["quit"]'`, and `--unbinds 1` map to Godot's connect flags. In an intent the recipe is `connect`:

```json
{ "recipe": "connect", "from": "/root/Main/Menu/Resume", "signal": "pressed",
  "to": "/root/Main/Menu", "method": "_on_resume_pressed" }
```

`node get` lists a node's connections, `diff` reports added and removed ones, rename and reparent rewrite the paths, removing a node removes its connections, and `validate` fails on a connection to a node that is not in the scene.

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


## Move or rename a file

Never `mv` a script, scene, or texture by hand; the `res://` paths in every scene that uses it go stale. One command moves the file with its `.uid` sidecar and repoints every scene, resource, manifest, and `project.godot` setting:

```bash
godot-cli project move --project-root . --from scripts/player.gd --to scripts/hero.gd
```

`--dry-run` lists what would change. Nodes inside an instanced scene are not in the parent file: to change one, use the `instance_override` patch op with `child`, which marks the instance editable; `set-property --node` on such a path fails with a hint saying so.


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


## Command examples by task

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


## Anti-patterns

- Hand-editing `[node]` / `parent=` / `instance=` lines when a CLI command exists
- Instancing `godot/…` builtin ids
- Skipping `scene validate` after edits
- Forgetting `--project-root` when using `res://` or catalog ids
- Using Godot headless to rewrite `.tscn` node order — use `scene normalize` instead

## Catalog integration

| Step | Command |
|------|---------|
| List entries | `catalog list --project-root . --json` |
| Full interface | `catalog show <id> --project-root . --json` |
| Search | `catalog search --project-root . --tags ui,button --query menu` |
| Agent digest | `catalog export --project-root . --output AGENTS.md` |
| Validate manifests | `catalog validate --project-root .` |

Project ids (e.g. `ui/button`) → `scene instance add --catalog-id`.  
Builtin ids (`godot/ui/Button`) → `scene node add --type Button`.

---

## Anti-patterns

| Anti-pattern | Instead |
|--------------|---------|
| `load().instantiate()` in `_ready()` for menus/HUD | `scene instance add` or `node_add` |
| Hand-editing `[node]` / `parent=` lines | `scene node *` commands |
| Guessing `ExtResource` ids | `scene inspect`, patch `id_hint`, or add then read JSON output |
| Instancing `godot/…` builtins | `scene node add --type <Class>` |
| Skipping validate | Always `scene validate --project-root .` |

---

## Dynamic vs authored (exception)

Runtime `instantiate()` **is** correct for gameplay systems that spawn entities at run time (enemies, projectiles, procedural chunks). godot-cli targets **authored** structure — what you would save in the editor before pressing Play.

---

## Related docs

| Doc | Purpose |
|-----|---------|
| [ABOUT.md](ABOUT.md) | Project overview and north star |
| [development_principles.md](development_principles.md) | JSON envelope, scene philosophy |
| [scene_authoring_roadmap.md](scene_authoring_roadmap.md) | Implementation phases |
| [catalog_design.md](catalog_design.md) | Manifests and builtins |
| [mcp_tools.json](mcp_tools.json) | Machine-readable command catalog |
