---
title: Build a scene with godot-cli
description: Create a scene, add nodes and properties, work with sub-resources and external files, and restructure a tree without breaking it.
---

# Build a scene

Every command here takes a viewport path such as `/root/Main/Player`, so you name nodes the way you think about them rather than by line number.

## Create the scene

```bash
godot-cli scene new --output scenes/main.tscn --root-name Main --root-type Node2D --project-root .
```

That writes a `gd_scene` header and a single root node. To start from something bigger, copy a built-in template:

```bash
godot-cli scene template list --json
godot-cli scene template copy 2d/top_down_player --output scenes/player.tscn --project-root .
```

The templates are `2d/character_body`, `2d/top_down_player`, `2d/camera_rig`, `3d/static_body`, and `ui/control_root`. `scene template show <id>` prints the node tree before you copy, and `--rename-node Player:Hero` renames as it copies.

## Add nodes and set properties

```bash
godot-cli scene node add scenes/main.tscn --parent /root/Main --name Player \
  --type CharacterBody2D --project-root .

godot-cli scene set-property scenes/main.tscn --node-name Player \
  --property position --value "Vector2(320, 180)" --project-root .
```

Property values go through the Variant parser, so a float lands as `16.0` on a property and as `2` inside `Vector2(2, 1.5)`, which is what the editor writes for each. Pass `--raw-value` when you have already formatted the text yourself.

`scene node add` also takes `--property` and `--value` directly, which saves a second command when the value is known at creation time.

## Sub-resources

A collision shape, a gradient, or a material stored inside the scene is a `sub_resource`. Create it, then reference its id from a node:

```bash
godot-cli scene sub add scenes/main.tscn --type CapsuleShape2D \
  --property radius --value 16.0 --project-root . --json
```

```json
{ "id": "CapsuleShape2D_f8o8q", "type": "CapsuleShape2D", "summary": "added sub_resource CapsuleShape2D_f8o8q" }
```

```bash
godot-cli scene node add scenes/main.tscn --parent /root/Main/Player --name Collision \
  --type CollisionShape2D --property shape --value 'SubResource("CapsuleShape2D_f8o8q")' --project-root .
```

Ids are generated the way Godot generates them. To get a predictable one, use a patch with `id_hint`, which produces `CapsuleShape2D_player` instead of a random suffix.

## External files

Scripts, textures, and other scenes are `ext_resource` entries. `scene ext add` registers one, but the usual case is registering and assigning in a single step, which the `assign_ext` patch op does:

```json
{
  "ops": [
    { "op": "assign_ext", "path": "/root/Main/Player", "property": "script",
      "type": "Script", "res_path": "res://scripts/player.gd" },
    { "op": "assign_ext", "path": "/root/Main/Player/Sprite", "property": "texture",
      "type": "Texture2D", "res_path": "res://art/player.png" }
  ]
}
```

```bash
godot-cli scene apply scenes/main.tscn --patch attach.json --project-root . --json
```

When the path is already registered, `assign_ext` reuses the existing id instead of adding a second entry, so several sprites can share one texture safely.

To see what a scene depends on and whether those files exist:

```bash
godot-cli scene refs scenes/main.tscn --project-root . --json
```

## Restructure without breaking the tree

Godot stores a node's parent as a path relative to the scene root, so renaming a node means rewriting the `parent` attribute of everything under it. This is the edit that goes wrong by hand.

```bash
godot-cli scene node rename scenes/main.tscn /root/Main/Player --name Hero --project-root .
godot-cli scene node reparent scenes/main.tscn /root/Main/Hero --parent /root/Main/Playfield --project-root .
```

After both commands the descendants have followed:

```text
[node name="Playfield" type="Node2D" parent="." unique_id=248520651]

[node name="Hero" type="CharacterBody2D" parent="Playfield" unique_id=1278869255]

[node name="Sprite" type="Sprite2D" parent="Playfield/Hero" unique_id=1745944107]
```

`scene node remove <path>` deletes a node, and takes `--recursive` when it has children.

## Check the result

```bash
godot-cli scene node list scenes/main.tscn --json
godot-cli scene inspect scenes/main.tscn --json
godot-cli scene validate scenes/main.tscn --project-root . --json
```

`node list` gives the tree with paths and types. `inspect` gives sections with parsed property values, including the Variant type of each. `validate` exits 1 on duplicate ids, out-of-order sections, missing `res://` targets, or stale UIDs.

## Next

Longer edits are better described once and applied in one write. See [batch edits with intents and patches]({{ base_url }}/how-to/batch-edits/).
