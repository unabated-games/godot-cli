---
title: Instance a scene inside another scene
description: Add a PackedScene instance, override its exported values, and use editable children, the way the Godot editor writes them.
---

# Instance and override

Putting one scene inside another needs three things in the file: an `ext_resource` of type `PackedScene`, a node carrying `instance=ExtResource("...")`, and `load_steps` counting correctly. Getting one of them wrong gives you a scene Godot opens with an error, which is why this is worth a command rather than an edit.

## Instance by path or by catalog id

```bash
godot-cli scene instance add scenes/main.tscn --parent /root/Main \
  --scene res://enemies/slime.tscn --name Slime --project-root .
```

If the scene has a catalog manifest, use its id instead. The agent-facing version of this workflow is in [teach an agent your sub-scenes]({{ base_url }}/how-to/your-own-components/):

```bash
godot-cli scene instance add scenes/main.tscn --parent /root/Main \
  --catalog-id ui/health_bar --name PlayerHealth --project-root .
```

Either way the file gets both halves:

```text
[gd_scene format=3 load_steps=2]

[ext_resource type="PackedScene" path="res://ui/health_bar/health_bar.tscn" id="1_gpo7l"]

[node name="PlayerHealth" parent="." instance=ExtResource("1_gpo7l") unique_id=1278869255]
```

Add `--unique-name` to set `unique_name_in_owner`, which is Godot's "Access as Unique Name". Scripts on the owner scene can then use `%PlayerHealth` instead of a path that breaks when the layout changes.

## Override values on the instance

An instance keeps its own values for anything exported by the instanced scene's root script. Set them with the `instance_override` patch op:

```json
{
  "ops": [
    { "op": "instance_override", "path": "/root/Main/PlayerHealth", "property": "max_health", "value": "150" },
    { "op": "instance_override", "path": "/root/Main/PlayerHealth", "property": "label_text", "value": "\"Player\"" }
  ]
}
```

```bash
godot-cli scene apply scenes/main.tscn --patch override.json --project-root . --json
```

String values keep their quotes inside the JSON string, as `"\"Player\""` above, because the value is Variant text, and a Variant string carries its own quotes. `catalog show <id>` lists the export names and their types if you are not sure what an instance accepts.

## Editable children

To change a node inside the instanced scene, as opposed to the instance root, mark the instance editable and target the child:

```bash
godot-cli scene instance add scenes/main.tscn --parent /root/Main \
  --scene res://ui/hud.tscn --name HUD --editable --project-root .
```

```json
{ "op": "instance_override", "path": "/root/Main/HUD", "child": "Bar/Label",
  "type": "Label", "property": "text", "value": "\"Score\"" }
```

That writes an `[editable path="..."]` section, the same thing the editor writes when you tick "Editable Children". Reach for it when the alternative is a copy of the component, and prefer an `@export` on the component's root when the value is something instances legitimately vary.

## Wire a signal

A button that does something needs its `pressed` signal connected to a method somewhere, and the editor stores that in the scene as a `[connection]` section. So does godot-cli:

```bash
godot-cli scene connection add scenes/main.tscn --from /root/Main/Menu/Resume --signal pressed \
  --to /root/Main/Menu --method _on_resume_pressed --project-root .
```

```text
[connection signal="pressed" from="Menu/Resume" to="Menu" method="_on_resume_pressed"]
```

The method lives in the receiving node's script, which you still write. What you no longer write is `$Resume.pressed.connect(_on_resume_pressed)` in `_ready()`, which is where an agent puts it when the scene has no way to hold it. Open the scene in Godot and the Node dock shows the connection like any other.

`--deferred`, `--one-shot`, `--binds '["quit"]'`, and `--unbinds 1` map to Godot's connect flags. `scene connection list` prints every connection with viewport paths, `scene node get` includes the ones touching a node, and `scene diff` reports connections added or removed. Renaming or reparenting a node rewrites its connections' paths, and removing a node removes them.

## Removing an instance

`scene node remove <path>` deletes the instance node. The `ext_resource` stays, since another node may still reference it. To drop that too:

```json
{ "op": "ext_remove", "id": "1_gpo7l" }
```

The op fails if anything still references the id, so removing in that order is safe.
