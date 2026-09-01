---
title: godot-cli
description: Edit Godot scenes, resources, and project settings from the command line, with JSON output built for scripts and coding agents.
layout: landing
---

# Edit Godot scenes from the command line

godot-cli reads and writes `.tscn`, `.tres`, and `project.godot` the way the editor writes them, so scripts and coding agents can build scenes without opening Godot.
{: .lede }

<div class="cta">
<a href="{{ base_url }}/getting-started/">Get started</a>
<a href="{{ base_url }}/how-to/your-own-components/">Teach an agent your sub-scenes</a>
<a href="https://github.com/unabated-games/godot-cli">Source on GitHub</a>
</div>

```bash
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
source "$HOME/.godot-cli/env.sh"
```

## Whole edits, one write

A scene edit is rarely one change. Adding a player means a node, a collision shape, a sub-resource for that shape, and a sprite with a texture reference. Running that as six separate commands means six parses, six writes, and six chances to leave the file half-edited.

godot-cli takes the whole change as one JSON document and applies it in a single pass:

```bash
godot-cli scene apply level.tscn --intent player.json --project-root . \
  --write-undo-patch undo.json --json
```

Before it writes anything, `--dry-run` returns the node tree you would end up with. `--write-undo-patch` writes the inverse edit as you go, so rolling back is applying a patch rather than reaching for git. When a step fails, the run stops and the file on disk is untouched.

The `batch` command does the same across commands: apply, validate, and diff in one invocation, with `stop`, `continue`, or `atomic` failure handling.

## Written against Godot's own source

Godot's text formats are easy to read and easy to get subtly wrong. Resource UIDs come from a specific hash, ext and sub resource ids have a shape, `load_steps` has to match, sections have an order, and floats are written through a normalization step that turns `16.0` into `16`.

Rather than guess at those rules, godot-cli ports them. `src/godot/hash.zig` comes from `core/templates/hashfuncs.h` and `core/string/ustring.cpp`. `src/godot/resource_uid.zig` comes from `core/io/resource_uid.cpp`. Variant text follows `core/variant/variant_parser.cpp`, and the parser keeps a line map back into that file so anyone can check a rule against the engine.

The check that keeps it honest runs in CI: Godot 4.7 saves a scene headless, godot-cli writes the same scene, and the two files are compared byte for byte. Same for the project file editors, which read and write the INI-style sections and brace blocks in `project.godot` rather than pattern matching over lines.

## Agents can use the components you already built

Every project accumulates its own pieces. A button with your styling, a HUD bar, an enemy scene wired to your spawner. A coding agent has no way to know any of that exists, so it builds a fresh Panel and Label out of raw nodes and you review the same thing again next week.

A catalog manifest fixes that. It sits beside a scene and says what the component is for:

```json
{
  "catalog_format_version": 2,
  "id": "ui/health_bar",
  "scene": "res://ui/health_bar/health_bar.tscn",
  "tags": ["ui", "hud", "health"],
  "summary": "Health bar with a label, used in the HUD",
  "when_to_use": "Any screen showing player or enemy health",
  "when_not_to_use": "Non-health meters; use ui/meter instead"
}
```

`godot-cli catalog add` writes that file for you and fills in what it can read: the scene path, its UID, and a row for every signal the root script declares. `catalog show` merges it with the scene's node tree and the `@export` variables parsed out of the script, so an agent asking about `ui/health_bar` gets the component's interface, not a file listing.

Instancing then happens by id:

```bash
godot-cli scene instance add hud.tscn --parent /root/HUD --name PlayerHealth \
  --catalog-id ui/health_bar --project-root .
```

That writes the `ext_resource` and the `instance=ExtResource(...)` node into the scene, which is what the editor writes when you drag a scene into another one. Godot's own controls are in the catalog too, as documentation only, so an agent reaching for a plain `Button` is told to create the node rather than instance something.

[How to set this up, step by step]({{ base_url }}/how-to/your-own-components/)

## Scenes that contain nodes, not scripts that build them

Ask an agent for a HUD and you will often get this:

```gdscript
func _ready() -> void:
    var bar = load("res://ui/health_bar/health_bar.tscn").instantiate()
    add_child(bar)
```

It runs. It also means the scene file is empty, the editor shows you nothing, the layout only exists once the game is playing, and the next change lands in a script instead of a scene. Six months of that and the project has two ways to build UI.

The workaround exists because raw `.tscn` text is hard to write. Take that away and the agent has no reason to reach for it. godot-cli gives an agent tree operations with names it can reason about, structured errors when it gets one wrong, and a catalog telling it what to reuse. The bundled skill and the agent guides state the rule directly: static structure lives in the scene file, runtime instancing is for things the game spawns while playing.

## What it does not do

It does not run gameplay, physics, or scripts, and it does not read binary `.scn` or `.res` files. It is not a replacement for the editor when you are placing things by eye. The round-trip suite is verified against Godot 4.7.

## Start here

<ul class="cards">
<li><a href="{{ base_url }}/getting-started/">Getting started</a><p>Install, author a first scene, and learn when to pass <code>--project-root</code>.</p></li>
<li><a href="{{ base_url }}/how-to/your-own-components/">Teach an agent your sub-scenes</a><p>The catalog walkthrough, from a bare scene to an agent instancing it by id.</p></li>
<li><a href="{{ base_url }}/how-to/agent-setup/">Set up an agent</a><p>Install the skill, write the project rules, and keep an agent authoring scenes.</p></li>
<li><a href="{{ base_url }}/reference/">Command reference</a><p>Every command and option, generated from the binary's own command tree.</p></li>
</ul>
