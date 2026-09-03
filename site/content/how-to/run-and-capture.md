---
title: Run the game and capture a screenshot and the log
description: One Godot command that writes a PNG of the running scene and a log of everything it printed, so a person or an agent can see what a change did.
---

# Run the game and capture a screenshot and the log

`scene validate` tells you a file is well formed. It cannot tell you the HUD ended up behind the background, or that a script threw on the first frame. For that you run the game, and Godot can do that from a terminal with no extra tooling.

## The command

Frames written inside the project get imported as textures on the next run, along with a `shot.wav` Godot writes beside them, and the project fills with `.import` files. So the output goes in a folder Godot is told to skip:

```bash
mkdir -p capture && touch capture/.gdignore
```

A `.gdignore` file makes Godot ignore that folder entirely. Then:

```bash
godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 60 --log-file capture/godot.log --no-header
```

That launches the project's main scene, writes one PNG per frame as `capture/shot00000000.png`, `capture/shot00000001.png`, and so on, quits after five frames, and writes everything the game printed to `godot.log`. Use the highest-numbered frame; the first one or two can be captured before the scene has drawn.

To run a specific scene, put its path after `--path .`:

```bash
godot --path . scenes/main.tscn --write-movie capture/shot.png --quit-after 5 --log-file capture/godot.log
```

`--write-movie` needs a display. On a machine without one, drop it and keep `--headless` for the log alone.

## What ends up in the log

Everything: `print()` output, `push_warning`, `push_error`, and script errors with a GDScript backtrace.

```
hello from _ready
ERROR: deliberate error
   at: push_error (core/variant/variant_utility.cpp:1024)
   GDScript backtrace (most recent call first):
       [0] _ready (res://scenes/noisy.gd:4)
SCRIPT ERROR: Invalid call. Nonexistent function 'call_something' in base 'Nil'.
   at: _ready (res://scenes/noisy.gd:7)
```

An agent can grep that for `ERROR` and `SCRIPT ERROR` and treat a hit as a failed change. Godot also prints the same text to stdout and stderr, so `2>&1 | tee godot.log` works when you would rather not pass a flag.

## Import first after adding files

Godot keeps a UID for every resource, and it assigns them when it imports the project. A script or scene added from outside the editor has no entry until then, and a run before that logs:

```
WARNING: res://main.tscn:3 - ext_resource, invalid UID: uid://d0ldlsj0t7bwh - using text path instead
```

The id godot-cli wrote is the one Godot will assign (it is derived from the path the same way), so the fix is to let Godot catch up:

```bash
godot --headless --path . --import --quit
```

Opening the project in the editor does the same. Run it once after creating files, before the capture run.

## For agents

The rules file is the place to put this, next to the validate step:

```markdown
After a scene change, run the game and check the result:
  mkdir -p capture && touch capture/.gdignore
  godot --headless --path . --import --quit
  godot --path . --resolution 640x360 --write-movie capture/shot.png --quit-after 60 --log-file capture/godot.log --no-header
Read the highest-numbered capture/shot*.png and capture/godot.log. Any ERROR or SCRIPT ERROR
line means the change is not done.
```

Agents that can read images will look at the frame. Those that cannot still get the log, which is where a broken script shows up.

`godot` has to be on `PATH`. On macOS the binary is inside the app bundle at `/Applications/Godot.app/Contents/MacOS/Godot`; a symlink or a `GODOT` variable in the rules file saves the agent guessing.
