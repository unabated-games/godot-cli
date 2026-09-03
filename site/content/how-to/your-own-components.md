---
title: Teach an agent to use your own sub-scenes
description: Step by step, from a scene you have already built to a coding agent instancing it by id instead of rebuilding it from raw nodes.
---

# Teach an agent to use your own sub-scenes

A coding agent starts every session knowing Godot's built-in nodes and nothing about your project. Ask for a pause menu and it will build one out of a fresh `Panel`, a `VBoxContainer`, and three `Button` nodes, styled from scratch, ignoring the button scene you wrote last month.

The component catalog is how you tell it what already exists. A manifest sits beside a scene, says what the component is for and when to use it, and godot-cli reads the scene and its root script to fill in the rest. From then on the agent can list what the project has, ask for one component's interface, and instance it by id.

This guide goes from a scene on disk to an agent using it. The example is a health bar, but nothing here is specific to UI.

## What you need first

A Godot project with a scene worth reusing, and godot-cli installed ([getting started]({{ base_url }}/getting-started/)). The example scene is `res://ui/health_bar/health_bar.tscn`: a `MarginContainer` root with a `ProgressBar` and a `Label` under it, and this script attached to the root:

```gdscript
@tool
extends MarginContainer

signal depleted
signal value_changed(new_value: int)

@export var max_health: int = 100
@export var label_text: String = "Health"
```

The `@export` variables and the signals are the component's interface. godot-cli parses them out of the script, so you never write them into the manifest by hand.

## 1. Write the manifest

Run `catalog add` against the scene. The prose flags are the part only you can supply:

```bash
godot-cli catalog add res://ui/health_bar/health_bar.tscn --project-root . \
  --id ui/health_bar \
  --summary "Health bar with a label, used in the HUD" \
  --when-to-use "Any screen showing player or enemy health" \
  --when-not-to-use "Non-health meters; use ui/meter instead" \
  --tags ui,hud,health
```

That writes `ui/health_bar/health_bar.manifest.json` beside the scene:

```json
{
  "catalog_format_version": 2,
  "id": "ui/health_bar",
  "scene": "res://ui/health_bar/health_bar.tscn",
  "tags": ["ui", "hud", "health"],
  "summary": "Health bar with a label, used in the HUD",
  "when_to_use": "Any screen showing player or enemy health",
  "when_not_to_use": "Non-health meters; use ui/meter instead",
  "signals": [
    { "name": "depleted", "doc": "", "connect_example": "" },
    { "name": "value_changed", "doc": "", "connect_example": "" }
  ]
}
```

Both signals are already there, read from the script. The `id` is the name agents will use; without `--id` it defaults to the scene path with `res://` and the extension removed, which for a scene in its own folder gives you `ui/health_bar/health_bar`. Short ids read better in a prompt.

The manifest is plain JSON on purpose. Nothing has to be installed in the Godot project to read or write it, and an agent can author one directly.

## 2. Fill in the prose

`when_to_use` and `when_not_to_use` do the work here. An agent reading "Any screen showing player or enemy health" picks this component for a boss health bar without asking. An agent reading "Non-health meters; use ui/meter instead" stops itself from using it for a stamina bar.

Open the manifest and fill in what the flags did not cover:

```json
{
  "notes": "Anchors to the top-left of its parent. Put it in a MarginContainer if you need padding.",
  "related_ids": ["ui/meter", "ui/hud_root"],
  "signals": [
    {
      "name": "depleted",
      "doc": "Emitted once when health reaches zero. Not re-emitted until health goes above zero.",
      "connect_example": "health_bar.depleted.connect(_on_player_died)"
    }
  ]
}
```

Rerunning `catalog add --update` later keeps everything you wrote, drops rows for signals the script no longer declares, and adds blank rows for new ones. Without `--update` it refuses to overwrite an existing manifest.

## 3. Check what the agent will see

`catalog show` merges the manifest with the scene's node tree and the script's exports and signals:

```bash
godot-cli catalog show ui/health_bar --project-root . --json
```

```json
{
  "id": "ui/health_bar",
  "source": "project",
  "exports_source": "gdscript_heuristic",
  "script_parse_complete": true,
  "exports": [
    { "name": "max_health", "type_hint": "int", "default": "100" },
    { "name": "label_text", "type_hint": "String", "default": "\"Health\"" }
  ],
  "signals": [ { "name": "depleted" }, { "name": "value_changed" } ],
  "scene": { "nodes": [ { "name": "HealthBar", "type": "MarginContainer" } ] }
}
```

If `script_parse_complete` is false, the GDScript parser hit something it could not read and the export list may be short. Set `export_root_script` in the manifest to point at a different script, or write the exports into the manifest yourself.

## 4. Export the digest the harness reads

`catalog show` is for an agent that already knows the id. To make it find components on its own, export the whole catalog as markdown:

```bash
godot-cli catalog export --project-root . --output AGENTS.md
```

```markdown
## Project components

### `ui/health_bar`

- **Scene:** `res://ui/health_bar/health_bar.tscn`
- **Tags:** ui, hud, health

Health bar with a label, used in the HUD

**When to use:** Any screen showing player or enemy health

**When not to use:** Non-health meters; use ui/meter instead

**Exports**

- `max_health` (`int`, default `100`)
- `label_text` (`String`, default `"Health"`)

**Signals**

- `depleted`
- `value_changed`(new_value: int)
```

Where that file goes depends on your harness. `AGENTS.md` at the project root is read by Codex and by OpenCode. Claude Code reads `CLAUDE.md`. Cursor reads files under `.cursor/rules/`. All of them take the same markdown, so `--output` is the only thing that changes:

```bash
godot-cli catalog export --project-root . --output CLAUDE.md
godot-cli catalog export --project-root . --output .cursor/rules/catalog.md
```

The digest also lists Godot's own controls under `godot/`, as documentation only. Those entries carry a class name and its signals, so an agent that needs a plain `Button` is told to create the node rather than instance a project scene.

## 5. Give the agent the rules alongside the catalog

The digest says what exists. Two more things say how to use it.

Install the bundled skill, which carries the whole authoring workflow:

```bash
install.sh --install-skill
```

It lands in `~/.cursor/skills/`, `~/.claude/skills/`, `~/.config/opencode/skills/`, and `~/.agents/skills/`. Refresh it later with `install.sh --skills-only`.

Then add the project rules to the same file you exported the digest into. This is the part that keeps an agent honest:

```markdown
## Scene authoring

Author scenes with godot-cli. Do not hand-edit .tscn text and do not build
static structure in GDScript.

Before adding UI or level structure:
  godot-cli catalog list --project-root . --json
  godot-cli catalog show <id> --project-root . --json

Instance a project component by id, never by copying its nodes:
  godot-cli scene instance add <scene> --parent <path> --name <Name> \
    --catalog-id <id> --project-root .

Adding a child node in _ready() with load().instantiate() is only for objects
the game spawns while playing, such as projectiles or enemy waves. Menus, HUDs,
and level layout belong in the scene file. So do signal connections:
  godot-cli scene connection add <scene> --from <path> --signal pressed \
    --to <path> --method <method> --project-root .

Finish with: godot-cli scene validate <scene> --project-root . --json
```

## 6. Watch it instance by id

With the catalog in place, one command puts the component in a scene:

```bash
godot-cli scene instance add hud.tscn --parent /root/HUD --name PlayerHealth \
  --catalog-id ui/health_bar --project-root . --json
```

```json
{ "node_path": "/root/HUD/PlayerHealth", "scene": "res://ui/health_bar/health_bar.tscn",
  "ext_resource_id": "1_gpo7l", "summary": "instanced PlayerHealth at /root/HUD/PlayerHealth" }
```

The scene file now holds what the editor would have written if you had dragged the scene in:

```text
[gd_scene format=3 load_steps=2]

[ext_resource type="PackedScene" path="res://ui/health_bar/health_bar.tscn" id="1_gpo7l"]

[node name="HUD" type="Node2D" unique_id=1195448652]

[node name="PlayerHealth" parent="." instance=ExtResource("1_gpo7l") unique_id=1278869255]
```

Inside a larger edit, the same thing is one op in a patch:

```json
{ "op": "instance_add", "parent": "/root/HUD", "name": "PlayerHealth", "catalog_id": "ui/health_bar" }
```

## 7. Override the exports on the instance

Instanced scenes take per-instance values, which is how one health bar serves the player and the boss:

```json
{
  "ops": [
    { "op": "instance_override", "path": "/root/HUD/PlayerHealth", "property": "max_health", "value": "150" },
    { "op": "instance_override", "path": "/root/HUD/PlayerHealth", "property": "label_text", "value": "\"Player\"" }
  ]
}
```

```bash
godot-cli scene apply hud.tscn --patch override.json --project-root . --json
```

```text
[node name="PlayerHealth" parent="." instance=ExtResource("1_gpo7l") unique_id=1278869255]
max_health = 150
label_text = "Player"
```

Those are the same `@export` names `catalog show` reported, which is why the agent can set them without opening the script.

To reach inside the instanced scene, add `--editable` when instancing, then use `child` on the override op. Keep that for cases you would use editable children for in the editor.

## 8. Validate, then look at the diff

```bash
godot-cli scene validate hud.tscn --project-root . --json
godot-cli scene diff before.tscn hud.tscn --properties --json
```

Validation exits 1 when it finds duplicate ids, a node whose parent is declared later in the file, an `ext_resource` pointing at a path that does not exist, or a stale UID. The diff reports added, removed, and retyped nodes, and with `--properties`, changed values.

## Keeping the catalog true

Manifests go stale in three ways, and each has a command.

A component's script changes, so the signals list is wrong. Rerun `catalog add --update` and your prose survives.

A scene moves. `scene` in the manifest is a plain path string and Godot does not rewrite it on a move. `catalog relink --project-root .` repairs it two ways: through the manifest's `scene_uid` and `.godot/uid_cache.bin` when the scene has a uid, and otherwise by the scene sitting beside its manifest with the same name, which is what a folder move looks like. It also rewrites the paths of scripts and textures inside the relinked scene that moved with it. A manifest it cannot place is reported `unresolved` with exit 1 rather than guessed at.

The digest drifts from the manifests. Add both to CI:

```bash
godot-cli catalog validate --project-root . --json   # exits 1 on invalid manifests
godot-cli catalog export --project-root . --output AGENTS.md
git diff --exit-code AGENTS.md
```

## When there is no component for the job

Not every request has a catalog entry, and pretending otherwise sends an agent instancing the wrong thing. `catalog search` is the honest check:

```bash
godot-cli catalog search --project-root . --tags ui --query "health" --json
```

With nothing suitable, the agent builds from Godot nodes with `scene node add`, which is what the `godot/` builtin entries document. If that new thing gets reused, it becomes a component: build it as its own scene, run `catalog add`, and it joins the catalog.

## Why this keeps an agent authoring scenes

An agent without a catalog has two bad options for reusing your work. It can copy the nodes out of your scene into the one it is editing, which duplicates the component and detaches it from later fixes. Or it can write `load("res://ui/health_bar/health_bar.tscn").instantiate()` in `_ready()`, which is the shape most models reach for by default because it is the shape most Godot tutorials show.

Both leave you with a scene file that does not describe the scene. The editor shows an empty node, the layout only exists at runtime, and reviewing the change means reading GDScript to work out what the screen looks like.

The catalog closes that gap. The agent knows the component exists and what it is for, it can read the exports and signals, and it has one command that writes the same `ext_resource` and `instance=` lines the editor would. What comes out opens in Godot and diffs like any other scene.
