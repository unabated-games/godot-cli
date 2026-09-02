---
title: Edit project.godot from the command line
description: Set the main scene, build an input map, register autoloads, enable plugins, and switch rendering or physics backends.
---

# Edit project settings

`project.godot` is an INI-style file with a few shapes that resist line editing: input actions are brace blocks containing serialized `Object(...)` values, autoloads carry a leading asterisk for singletons, and section order matters. godot-cli parses the file and writes it back rather than matching patterns over lines.

## Look at what is there

```bash
godot-cli project show --project-root . --json
```

```json
{
  "project_name": "Demo",
  "main_scene": "res://main.tscn",
  "input_action_count": 4,
  "autoload_count": 1,
  "enabled_plugin_count": 0
}
```

## Scalar settings

```bash
godot-cli project settings set --project-root . \
  --section application --key run/main_scene --value res://main.tscn

godot-cli project settings list --project-root . --json
godot-cli project settings get --project-root . --section application --key config/name --json
```

Strings are quoted for you. Pass `--raw` when the value is already Godot-formatted, such as a `Vector2(...)` or a boolean.

`project settings validate --project-root .` checks that `res://` paths in settings point at files that exist, which catches a main scene that was renamed.

## Input map

Input actions are the fiddliest part of the file, so they are described as an intent and applied as a unit:

```json
{
  "actions": [
    {
      "name": "move_left",
      "events": [
        { "type": "key", "keycode": "A", "physical": true },
        { "type": "joypad_motion", "axis": "left_x", "axis_value": -1.0 }
      ]
    }
  ]
}
```

```bash
godot-cli project input apply --project-root . --intent input.json --json
```

```
applied 4 input action(s) (4 added, 0 replaced)
```

What lands in the file is the full serialized event Godot expects:

```text
[input]
move_left={
"deadzone": 0.5,
"events": [Object(InputEventKey,"resource_local_to_scene":false,"resource_name":"","device":-1,...,"physical_keycode":65,...)]
}
```

Applying the same intent twice replaces each action by name instead of appending a second copy, so re-running after an edit is safe. A ready-made WASD intent ships at `$GODOT_CLI_HOME/examples/intents/wasd_movement.json`.

## Autoloads

```json
{ "autoloads": [ { "name": "GameState", "path": "res://scripts/game_state.gd", "singleton": true } ] }
```

```bash
godot-cli project autoload apply --project-root . --intent autoload.json --json
godot-cli project autoload validate --project-root . --json
```

```text
[autoload]
GameState="*res://scripts/game_state.gd"
```

The asterisk is how Godot marks a singleton. Autoloads merge by name; pass `replace_all` in the intent when the list should be exactly what you supplied.

## Editor plugins

```bash
godot-cli project plugins list --project-root . --json
godot-cli project plugins enable --project-root . --plugin my_addon
godot-cli project plugins disable --project-root . --plugin old_plugin
godot-cli project plugins validate --project-root . --json
```

This toggles plugins that already exist at `addons/<name>/plugin.cfg`. godot-cli does not install from the Asset Library.

## Rendering and physics

Both take short aliases in place of the raw setting keys:

```bash
godot-cli project rendering list --project-root . --json
godot-cli project rendering apply --project-root . --intent rendering_forward_plus.json --json
godot-cli project physics apply --project-root . --intent physics_jolt.json --json
```

`project rendering validate` and `project physics validate` check the values against the ones Godot accepts, so a typo in a driver name fails before you next open the project.

## One intent for everything

`project apply` takes a single document containing any combination of the sections above and writes them in one pass:

```json
{
  "settings": { "application": { "run/main_scene": "res://main.tscn" } },
  "input": { "actions": [ ... ] },
  "autoload": { "autoloads": [ ... ] },
  "rendering": { "method": "forward_plus" }
}
```

```bash
godot-cli project apply --project-root . --intent bootstrap.json --json
```

`$GODOT_CLI_HOME/examples/intents/project_bootstrap.json` is a working example. Every command here takes `--dry-run` to apply in memory and report what would change.
