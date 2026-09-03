---
title: godot-cli
description: Build Godot scenes from the command line. Files that match the editor's own saves byte for byte, JSON in and out, and a component catalog so coding agents reuse what you have already built.
layout: landing
---

# Edit Godot scenes safely, without opening the editor

godot-cli edits `.tscn`, `.tres`, and `project.godot` from a terminal. The files it produces match Godot's own saves byte for byte, and every command speaks JSON, which makes it usable by a shell script, a CI job, or a coding agent that has never opened the editor.
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

## Ask an agent for a HUD and watch what comes back

It tends to be this:

```gdscript
func _ready() -> void:
    var bar = load("res://ui/health_bar/health_bar.tscn").instantiate()
    add_child(bar)
```

The game runs, so it looks like a success. Open the scene in the editor and there is nothing in it. The layout exists only while the game is playing. The next tweak goes into the script too, because that is where the HUD now lives, and a few months on the project has two ways of building UI and nobody is sure which screens use which.

Agents write this because scene text is hard to write blind. A `.tscn` has resource ids with a particular shape, sections in a particular order, a `load_steps` count that has to be right, and a float format where a property is `16.0` but a vector component is `Vector2(2, 1.5)`. Faced with all that, GDScript is the safer bet, and the agent takes it.

godot-cli removes the reason. The same request is one command, and wiring the button afterwards is another (`scene connection add`), which writes the `[connection]` section the Node dock would:

```bash
godot-cli scene instance add hud.tscn --parent /root/HUD --name PlayerHealth \
  --catalog-id ui/health_bar --project-root .
```

The scene file gets what dragging the scene into the tree would have produced, ids and all:

```text
[ext_resource type="PackedScene" path="res://ui/health_bar/health_bar.tscn" id="1_gpo7l"]

[node name="PlayerHealth" parent="." instance=ExtResource("1_gpo7l") unique_id=1278869255]
```

We make games in Godot, and we think the scene file should be the source of truth. If you have to press Play to find out what a screen looks like, something has gone wrong. This tool exists so that an agent, a script, or a person at a terminal can work that way without hand-writing scene text.

## It writes what the editor writes

Being able to write a scene Godot can open is a low bar. The bar we care about is writing the scene Godot itself would have saved, because anything less shows up as noise in every diff and a pile of "reformatted by tool" commits.

So we ported the rules instead of guessing at them. `src/godot/hash.zig` is a port of `core/templates/hashfuncs.h` and `core/string/ustring.cpp`. `src/godot/resource_uid.zig` comes from `core/io/resource_uid.cpp`. Variant text (vectors, colors, `Object(...)` bodies, typed arrays, packed byte arrays in base64) follows `core/variant/variant_parser.cpp`, and the parser carries a line map back into that file so you can check any rule against the engine source yourself.

The test that keeps us honest runs on every push, against Godot 4.7, 4.7.2, and the newest 4.8 prerelease. Godot saves a fixture scene headless. godot-cli writes the same scene. `cmp` compares the two files. When it fails, the tool is wrong and the editor is right, and we fix the tool.

`project.godot` gets the same treatment. Input actions are brace blocks full of serialized `InputEventKey` objects, and autoloads carry a leading asterisk for singletons. godot-cli parses the file and writes it back, so an input map applied twice replaces the actions by name instead of doubling them.

## One document, one write

Adding a player is never one edit. It is a node, a collision shape, a sub-resource for the shape, a sprite, and a texture reference. Six commands means six parses and six writes, and if the fourth one fails you have a scene with a shape that nothing uses.

godot-cli takes the whole change as one JSON document and applies it in a single pass:

```bash
godot-cli scene apply level.tscn --intent player.json --project-root . \
  --dry-run --json
```

With `--dry-run` you get the node tree you would end up with and nothing is written. Without it, `--write-undo-patch` produces the inverse edit as it goes, and rolling back means applying that patch instead of digging through git history. If any step fails, the file on disk is untouched.

Twelve patch ops cover the primitives (add, remove, rename, reparent, set, instance, override, resource add and remove). Intents sit on top: `player_2d` expands into the five ops above, `catalog_button` into an instance plus a label override. For a run of several commands, `batch` does apply, then validate, then diff in one process, with `atomic` mode putting back the files you listed if anything fails.

## It knows what you have already built

Every project accumulates its own parts: a button with your styling, a health bar, an enemy scene already wired to your spawner. An agent starts each session knowing none of this, so it builds a fresh `Panel` and `Label` out of raw nodes and you review the same thing again next week.

A catalog manifest sits beside a scene and says what it is for:

```json
{
  "id": "ui/health_bar",
  "scene": "res://ui/health_bar/health_bar.tscn",
  "summary": "Health bar with a label, used in the HUD",
  "when_to_use": "Any screen showing player or enemy health",
  "when_not_to_use": "Non-health meters; use ui/meter instead"
}
```

`catalog add` writes it for you and fills in what it can read: the scene path, its UID, and a row for every signal the root script declares. `catalog show` merges that with the node tree and the `@export` variables parsed out of the GDScript, so an agent asking about `ui/health_bar` gets an interface. `catalog export` turns the whole thing into a markdown digest you drop into `AGENTS.md` or `CLAUDE.md`, and from then on the agent knows the health bar exists, knows when to use it, and instances it by id.

Godot's own controls are in the catalog too, marked as documentation only, so an agent that needs a plain `Button` is told to create the node. We think that distinction (instance yours, create Godot's) is most of what keeps generated scenes looking like scenes a person made.

[The full walkthrough, step by step]({{ base_url }}/how-to/your-own-components/)

## Built for agents, usable by hand

`--json` on any command returns one envelope: `ok`, `data`, `messages`, `failure`, and a stable exit code. `godot-cli mcp` serves the same commands over the Model Context Protocol, one tool per command with schemas built from the command tree, the agent docs as resources, and the project catalog as a live resource, so Claude Code, Cursor, and OpenCode can call them without a shell. Anything you can type as argv you can also send as a JSON request, and `godot-cli reference --format json` prints the whole command surface as data for anyone generating their own bindings.

For people there is `--help` on everything, a man page, and completions for bash, zsh, and fish, all generated from the same command tree the parser uses. The skill for Cursor, Claude Code, and OpenCode installs with one flag and carries the rules an agent needs, including the one about `_ready()`.

A single binary with no runtime dependencies, built in Zig, for Linux, macOS, and Windows on x86_64 and aarch64. MIT licensed.

## What it is not

It does not run gameplay, physics, or scripts. It does not read binary `.scn` or `.res`. It will not replace the editor when you are nudging a sprite two pixels to the left by eye. The round-trip suite runs against Godot 4.7 and 4.7.2 on every push, and against the newest 4.8 prerelease as a check that does not block; it passes there today, and a 4.8 format change will show up in CI before it shows up in your project.

## Start here

<ul class="cards">
<li><a href="{{ base_url }}/getting-started/">Getting started</a><p>Install, author a first scene, and learn when <code>--project-root</code> matters.</p></li>
<li><a href="{{ base_url }}/how-to/your-own-components/">Teach an agent your sub-scenes</a><p>From a scene on disk to an agent instancing it by id, every command shown with its output.</p></li>
<li><a href="{{ base_url }}/how-to/agent-setup/">Set up an agent</a><p>Install the skill, write the project rules, and spot when an agent drifts back to building nodes in code.</p></li>
<li><a href="{{ base_url }}/reference/">Command reference</a><p>Every command and option, generated from the binary's own command tree.</p></li>
</ul>
