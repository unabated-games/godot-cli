---
title: Batch scene edits with intents and patches
description: Describe a whole scene change as JSON, preview it, apply it in one write, and undo it.
---

# Batch edits with intents and patches

A scene change is usually several edits that only make sense together. Running them as separate commands parses and writes the file once per step, and a failure halfway leaves the scene in a state nobody asked for.

godot-cli takes the whole change as one document. There are two levels: patches, which are explicit operations, and intents, which are named recipes that expand into patches.

## Patches

A patch is a list of ops applied in order:

```json
{
  "ops": [
    { "op": "node_add", "parent": "/root/Main", "name": "Player", "type": "CharacterBody2D" },
    { "op": "sub_add", "type": "CapsuleShape2D", "id_hint": "player", "properties": { "radius": "16.0" } },
    { "op": "node_add", "parent": "/root/Main/Player", "name": "Collision", "type": "CollisionShape2D",
      "properties": { "shape": "SubResource(\"CapsuleShape2D_player\")" } },
    { "op": "node_add", "parent": "/root/Main/Player", "name": "Sprite", "type": "Sprite2D" },
    { "op": "assign_ext", "path": "/root/Main/Player/Sprite", "property": "texture",
      "type": "Texture2D", "res_path": "res://art/player.png" }
  ]
}
```

```bash
godot-cli scene apply scenes/main.tscn --patch player.json --project-root . --json
```

`id_hint` is what makes the third op possible: it fixes the sub-resource id as `CapsuleShape2D_player` so a later op can reference it. Without a hint, ids are generated the way Godot generates them and you would have to read one command's output to write the next.

The ops are `node_add`, `node_remove`, `node_rename`, `node_reparent`, `node_set`, `ext_add`, `ext_remove`, `sub_add`, `sub_remove`, `assign_ext`, `instance_add`, and `instance_override`. The [command reference]({{ base_url }}/reference/) and `$GODOT_CLI_HOME/docs/agent_scene_authoring.md` carry the required fields for each.

## Intents

An intent is a higher-level description. Recipes such as `player_2d`, `camera_2d`, `ui_panel`, `tilemap_layer`, `audio_player`, `instance_catalog`, and `catalog_button` expand into the ops above:

```json
{
  "steps": [
    { "recipe": "player_2d", "parent": "/root/Main", "name": "Player", "texture": "res://art/player.png" },
    { "recipe": "camera_2d", "parent": "/root/Main", "name": "Camera" },
    { "recipe": "catalog_button", "parent": "/root/Main/HUD", "name": "StartButton",
      "catalog_id": "ui/button", "label": "Start game" }
  ]
}
```

```bash
godot-cli scene apply scenes/main.tscn --intent hud.json --project-root . --json
```

To see the ops an intent expands to without touching the scene, run `scene plan`:

```bash
godot-cli scene plan scenes/main.tscn --intent hud.json --project-root . --write-patch planned.json --json
```

Copy-paste intents ship in `$GODOT_CLI_HOME/examples/intents/`.

## Preview before writing

```bash
godot-cli scene apply scenes/main.tscn --patch player.json --project-root . --dry-run --json
```

The result carries `preview_diff`, the node tree you would end up with. Add `--preview-properties` to include property-level changes. Nothing is written.

## Undo

`--write-undo-patch` writes the inverse edit as the patch is applied:

```bash
godot-cli scene apply scenes/main.tscn --patch player.json --project-root . \
  --write-undo-patch undo.json --json
```

```json
{
  "ops": [
    { "op": "node_remove", "path": "/root/Main/Player/Collision", "recursive": true },
    { "op": "sub_remove", "id": "CapsuleShape2D_player" },
    { "op": "node_remove", "path": "/root/Main/Player", "recursive": true }
  ]
}
```

Applying `undo.json` reverses the change. For a copy of the whole file instead, `--snapshot` writes one before the edit and `scene restore --snapshot <path>` puts it back.

## Several commands in one process

`batch` runs whole commands, not individual ops, which suits apply, then validate, then diff:

```json
{
  "mode": "atomic",
  "rollback": ["scenes/main.tscn"],
  "steps": [
    { "argv": ["scene", "apply", "scenes/main.tscn", "--intent", "intents/hud.json", "--project-root", ".", "--json"] },
    { "argv": ["scene", "validate", "scenes/main.tscn", "--project-root", ".", "--json"] }
  ]
}
```

```bash
godot-cli batch --file workflow.json --json
```

`mode` decides what a failure does. `stop` ends the run at the first failure and reports what happened up to that point. `continue` runs everything and aggregates the counts, which suits a bundle of checks. `atomic` copies each path in `rollback` first and restores them if any step fails, so a multi-step edit cannot leave a scene half-written.

Every step returns its own result, so a failure tells you which step and why rather than which command in a shell script exited non-zero.
