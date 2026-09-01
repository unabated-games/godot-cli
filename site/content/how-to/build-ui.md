---
title: Build Godot UI from the command line
description: Author Control trees whose look lives in the scene file, with anchors, containers, theme overrides, and unique names.
---

# Build UI

UI is where generated scenes go wrong most often. A model writes a `Control` tree with no styling, then puts the presentation in `_ready()` with `add_theme_font_size_override`. The game looks right when it runs and wrong in the editor, and nobody can review the layout without playing it.

The rule that avoids this: anything static goes in the scene file. Runtime code updates values that change during play, such as a score counter.

## Set presentation as scene properties

The properties the editor writes are the ones to set:

| What you want | Property |
|---------------|----------|
| Font size | `theme_override_font_sizes/font_size` |
| Padding on a container | `theme_override_constants/margin_left`, `_right`, `_top`, `_bottom` |
| Position and anchoring | `anchors_preset`, `anchor_*`, `offset_*` |
| How a child fills its parent | `size_flags_horizontal`, `size_flags_vertical` |
| A stable cell width | `custom_minimum_size`, for example `Vector2(160, 0)` |
| Tint or fill colour | `modulate`, or `color` on a `ColorRect` |

```bash
godot-cli scene node add hud.tscn --parent /root/HUD/Row --name Score --type Label \
  --property theme_override_font_sizes/font_size --value 35 --project-root .
```

Quote string values so they survive the shell and reach the Variant parser as strings:

```bash
godot-cli scene set-property hud.tscn --node-name Score --property text --value '"0"' --project-root .
```

## A top bar, as the editor would build it

```json
{
  "ops": [
    { "op": "node_add", "parent": "/root/Main", "name": "HUD", "type": "Control",
      "properties": { "anchors_preset": "10", "offset_bottom": "48.0" } },
    { "op": "node_add", "parent": "/root/Main/HUD", "name": "Background", "type": "ColorRect",
      "properties": { "anchors_preset": "15", "color": "Color(0, 0, 0, 0.6)" } },
    { "op": "node_add", "parent": "/root/Main/HUD", "name": "Margin", "type": "MarginContainer",
      "properties": { "anchors_preset": "15", "theme_override_constants/margin_left": "16",
                      "theme_override_constants/margin_right": "16" } },
    { "op": "node_add", "parent": "/root/Main/HUD/Margin", "name": "Row", "type": "HBoxContainer" }
  ]
}
```

The background is a sibling under the same `Control` rather than a parent, so it fills the bar without affecting layout. Content sits in a `MarginContainer` so padding is a container property rather than offsets on each child.

For a row with items pushed left, centre, and right, give the spacers `size_flags_horizontal` of 3 and leave the items at their natural size.

## Unique names instead of long paths

`$HUD/Margin/Row/Score` breaks the moment someone adds a container. Mark the node as a unique name and scripts on the owner scene can use `%Score`:

```bash
godot-cli scene node add hud.tscn --parent /root/HUD/Row --name Score --type Label \
  --unique-name --project-root .
```

In a patch, the same thing is `{ "op": "node_set", "path": "/root/HUD/Row/Score", "property": "unique_name_in_owner", "value": "true" }`.

## Reusable widgets need @tool

When a widget's root script drives its children from `@export` variables, mark the script `@tool` and apply values through setters. Without it, the editor shows the unstyled scene and only Play looks right.

```gdscript
@tool
extends MarginContainer

@export var label_text: String = "Health":
    set(value):
        label_text = value
        _apply_label()

func _ready() -> void:
    _apply_label()

func _apply_label() -> void:
    var label := get_node_or_null("Label")
    if label:
        label.text = label_text
```

`get_node_or_null` matters because the editor calls the setter before the tree is ready. With this in place, an instance of the widget can be configured from the parent scene with `instance_override` on `label_text`, and the editor viewport updates as the value changes.

Once a widget is worth reusing, give it a catalog manifest so agents find it: [teach an agent your sub-scenes]({{ base_url }}/how-to/your-own-components/).

## Check it without opening Godot

```bash
godot-cli scene inspect hud.tscn --json      # parsed property values, with types
godot-cli scene node list hud.tscn --json    # the Control tree
godot-cli scene validate hud.tscn --project-root . --json
```

`inspect` reports each property's Variant kind, which catches a colour written as a string or an anchor written as a float where an int was meant.
