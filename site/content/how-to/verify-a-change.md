---
title: Verify a change by running the game
description: One command imports, runs the scene, captures the frame and the log, and fails on any error, so a change is not done until it passes. Presses and clicks exercise movement and buttons without test code in the game.
---

# Verify a change by running the game

`scene validate` tells you the file is well formed and that its property values
are the right types. It cannot tell you the HUD ended up behind the background,
that a button does nothing, or that a script threw on the first frame. For that
you run the game.

```bash
godot-cli project run --project-root . --json
```

That imports the project, runs the main scene for sixty frames while writing a
movie, keeps the last frame, and reads the log back. It exits 1 when Godot did
not exit cleanly or the log holds an `ERROR` or `SCRIPT ERROR` line, which is
the signal that says the change is not finished. Over MCP the same thing is the
`project_run` tool, and the frame comes back as an image the agent can look at.

The result names what you need:

| Field | What it is |
|-------|------------|
| `frame` | Path of the last PNG. Read it — a run can pass with a wrong layout |
| `log`, `log_tail` | The log file, and its last 40 lines inline |
| `errors`, `error_count` | Every `ERROR` / `SCRIPT ERROR` line with its backtrace |
| `exit`, `import_exit` | Godot's exit codes for the run and the import pass |
| `frames_written`, `duration_ms` | What the run actually did |

## The loop

Validate, run, read. In a rules file it is three lines:

```markdown
After a scene change:
  godot-cli scene validate <scene> --project-root . --json
  godot-cli project run --project-root . --json
Read data.frame and data.errors. Any error line means the change is not done.
```

The frame matters as much as the log. A scene with a `Control` under a `Node2D`
loads, runs, logs nothing, and draws nothing; the only thing that shows it is
the picture.

## Prove a button works, not just that it exists

A frame shows the button is there. Clicking it shows the wiring is right:

```bash
godot-cli project run --project-root . --frames 30 \
  --click /root/Main/HUD/PlayButton@20 --json
```

That presses the left mouse button at the centre of the node on frame
20 and releases on the next, so a `Button`'s `pressed` signal fires and whatever
it is connected to runs. Your handler's `print` lands in `log_tail`, which is
the evidence that the connection works.

After the release the game's cursor moves off the node, so the last frame shows
the button in its **normal** style rather than its hover style. To see the hover
style instead, keep the cursor there:

```bash
godot-cli project run --project-root . --frames 30 \
  --click /root/Main/HUD/PlayButton@20 --keep-cursor --json
```

Two runs, two frames, and you have verified both states of a button plus the
signal, without adding a line of test code to the game. Only the game's own
cursor moves; nothing touches the desktop pointer.

This works under `--headless` as well, which is what makes a button's wiring
checkable in CI. The signal fires and the handler's `print` lands in the log;
only the frame is missing.

## Drive a form, so a sign-in is watched rather than reviewed

A screen behind a form cannot be reached by clicking alone. `--type` fills a
field:

```bash
godot-cli project run --project-root . --frames 40 \
  --type '/root/Main/%Email@10=someone@example.com' \
  --type '/root/Main/%Password@14=hunter2' \
  --click /root/Main/Box/Submit@20 --json
```

The field is focused and emptied, then the text goes in as real key events, so
`text_changed` fires and a validating form runs the way it does for a person.
Assigning `LineEdit.text` emits nothing, which is why this does not do that.

The frame number sits between the last `@` of the node path and the first `=`
of the text, so an address in the value and an `=` in a password both survive.
A value can be empty — `%Email@3=` clears the field.

**Leave a frame or two before the click.** The keys are delivered on the frame
after they are sent, so a Submit clicked on the same frame sees the old value.

`--focus <node-path>@<frame>` moves keyboard focus without typing, for a frame
that shows a focus ring or proves a tab order.

Movement works the same way with input actions:

```bash
godot-cli project run --project-root . --frames 60 \
  --press move_right@10..40 --json
```

`move_right@10..40` holds the action from frame 10 to 40. It is sent as a real
`InputEventAction` as well as polled state, so a focused `Control` reacting to
`ui_accept` and a script polling `Input.get_vector` both see it.

## What to watch out for

**`--headless` clicks work; what you lose is the frame.** The headless
display server reports no window size, which would leave the root viewport at
64×64 with every `Control` laid out in that corner, so the run puts the
project's own size back before the first click. Layout and input picking then
match a windowed run, and a `Button` at (960, 540) is pressed at (960, 540).
What headless cannot give you is a picture, so the layout the click landed on
is the part still unverified — run with a window when the layout is the
question.

**A click that cannot reach its target fails the run.** If the node is laid
out beyond the viewport, or an ancestor has moved it off-screen, the run ends
with the node's position and the viewport size rather than reporting a press
that never happened.

**Frames are numbered from 0, presses and clicks from 1.** `--frame-at 20`
keeps that movie frame as well as the last one, for a mid-run state such as a
menu part-way through opening. One frame is one physics step in both modes —
the run pins Godot's frame rate to the project's
`physics/common/physics_ticks_per_second`, so `--frames 40` is 40 frames on
any machine and `--click …@20` happens at the same point every time.

**Autoloads are fine.** The run injects input through a generated script under
the capture folder, and that script loads your scene after Godot has registered
autoload singletons, so a scene whose script names `GameState` runs normally.

**The capture folder is ignored.** Frames and the log go to
`.godot/godot-cli/`, which carries a `.gdignore`, so Godot never imports the
PNGs as textures. Only the last frame is kept unless you pass `--keep-frames`.

## Running it by hand

`project run` is a wrapper around commands you can type yourself, which is
worth knowing when you want to adapt it:

```bash
mkdir -p capture && touch capture/.gdignore
godot --headless --path . --import --quit
godot --path . --resolution 640x360 --write-movie capture/shot.png \
  --quit-after 60 --log-file capture/godot.log --no-header
```

The import pass matters after adding files: Godot assigns UIDs there, and a run
before it logs `invalid UID … using text path instead`. `--write-movie` needs a
display; drop it and keep `--headless` for the log alone.

Everything the game prints ends up in the log — `print()`, `push_warning`,
`push_error`, and script errors with a GDScript backtrace:

```text
hello from _ready
ERROR: deliberate error
   at: push_error (core/variant/variant_utility.cpp:1024)
   GDScript backtrace (most recent call first):
       [0] _ready (res://scenes/noisy.gd:4)
```

Grepping that for `ERROR` and treating a hit as a failed change is exactly what
`project run` does for you, along with pulling out the backtrace lines that
follow each one.
