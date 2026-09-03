---
title: Godot basics a coding agent needs
description: The assumptions Godot makes about projects, scenes, and Control layout that an agent does not know, and what to put in its rules so it stops guessing.
---

# Godot basics a coding agent needs

Two trial runs of the same task, with two different agents, made the same mistake: a pause menu positioned with `anchors_preset` and nothing else. The scene validated, Godot loaded it without a warning, and the panel sat clipped in the top-left corner, because `anchors_preset` is a label the editor uses and the runtime reads `anchor_*`. Nothing in the tool can catch that. The rules can prevent it.

This page is the short list. The agent quickstart installed at `$GODOT_CLI_HOME/docs/agent_quickstart.md` carries the same text, so an agent reading that gets it without you pasting anything.

## Projects

A project is a folder with `project.godot` at its root, and `res://` means that folder. A scene created outside it cannot resolve a single `res://` path, which is the first thing an agent does when it writes to the wrong place.

The main scene is a setting, and it is the setting a fresh project is missing:

```bash
godot-cli project settings set --project-root . --section application --key run/main_scene --value res://scenes/main.tscn
```

After adding scripts or scenes from outside the editor, Godot has to import once before UIDs exist:

```bash
godot --headless --path . --import --quit
```

## Scenes

A scene has exactly one root node, and the root has no `parent` attribute. Pick the root type for the job: `Node2D` for 2D worlds, `Node3D` for 3D, `Control` for UI screens. Every other node names its parent, and godot-cli takes those as viewport paths (`/root/Main/HUD`) so an agent never writes the relative form by hand.

## Control layout

`anchors_preset` is an editor label only. Runtime layout comes from `anchor_left`, `anchor_top`, `anchor_right`, `anchor_bottom` (0 to 1 of the parent), `offset_*` (pixels from those anchors), and `grow_horizontal` and `grow_vertical`. A `Control` with default anchors is 0 by 0 pixels, and anything centred inside it lands at the top-left corner.

The three layouts that cover most UI:

| Layout | Properties |
|--------|------------|
| Fill the parent | `anchors_preset = 15`, `anchor_right = 1.0`, `anchor_bottom = 1.0`, `grow_horizontal = 2`, `grow_vertical = 2` |
| Centred | `anchors_preset = 8`, all four anchors `0.5`, `grow_horizontal = 2`, `grow_vertical = 2` |
| Top-left with padding | anchors at 0, `offset_left` and `offset_top` |

As a patch, the fill-the-parent case reads:

```json
{ "op": "node_add", "parent": "/root/Main", "name": "HUD", "type": "Control",
  "properties": { "anchors_preset": "15", "anchor_right": "1.0", "anchor_bottom": "1.0",
                  "grow_horizontal": "2", "grow_vertical": "2" } }
```

Containers lay their children out; plain Controls do not. `VBoxContainer` and `HBoxContainer` stack children. `MarginContainer`, `PanelContainer`, and `CenterContainer` are built for one child, and put several on top of each other. Leaf controls such as `ProgressBar` and `TextureRect` need a `custom_minimum_size`, or a container gives them no room.

## The rule that catches the rest

Validation checks the file, not the picture. The line to keep in the rules is the one that runs the game and reads the frame:

```markdown
Finish every change with:
  godot-cli scene validate <scene> --project-root . --json
  mkdir -p capture && touch capture/.gdignore
  godot --headless --path . --import --quit
  godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 60 --log-file capture/godot.log --no-header
Look at the highest-numbered capture/shot*.png and read capture/godot.log before reporting done.
```

An agent that can see images checks its own layout. One that cannot still gets the log, and a person gets a frame to look at instead of opening the editor.
