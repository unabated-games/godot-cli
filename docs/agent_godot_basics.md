# Godot basics for agents

What Godot assumes about projects, scenes, and Control layout, and how to run the game and read the result. Read once; the quickstart points here.

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


## Seeing movement

A `Camera2D` under the player follows it, so the player stays centred and the world slides. If nothing else is drawn, that looks like nothing happening. Give walls and floors something visible: the `static_body_2d` recipe takes `"color": "Color(0.3, 0.5, 0.8, 1)"` for a filled polygon the size of the collision box, or `"texture"` for a tiled sprite. Or put the camera under the root while testing; a root camera sits at the origin unless the recipe's `position` puts it where the player starts. Input actions bound with `physical: true` are the keyboard positions of W, A, S, D, not the arrow keys.

## Run the game and check the result

After a scene change, `scene validate` proves the file is well formed. To see the result, run the game. `godot-cli project run --project-root . --json` does the whole loop below and returns the last frame, the log path, and the error lines, failing when there are any. By hand, Godot writes a frame and a log with no extra tooling:

```bash
mkdir -p capture && touch capture/.gdignore          # Godot skips this folder, so frames are not imported
godot --headless --path . --import --quit          # once after adding files, so Godot assigns UIDs
godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 60 --log-file capture/godot.log --no-header
```

Read the highest-numbered `capture/shot*.png` and `capture/godot.log`. Sixty frames is one second at 60 FPS, long enough for gravity and a camera to settle; five is enough for a static UI screen. The log holds every `print()`, `push_warning`, `push_error`, and script error with a backtrace; any `ERROR` or `SCRIPT ERROR` line means the change is not done. Without a display, drop `--write-movie` and add `--headless` to get the log alone.


## Node section order

Godot instantiates nodes in file order, so a child declared before its parent fails to load. Writes run save preparation, which orders sections and repairs ids; if `scene validate` reports `node_parent_order` on a file edited elsewhere, run `scene normalize`. Never use Godot headless as a scene pretty-printer. In a multi-step patch, add a parent before reparenting children onto it.
