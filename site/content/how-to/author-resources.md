---
title: Author .tres resources from the command line
description: Create materials, themes, shapes, and other Godot resources as files the editor would have saved, with sub-resources and external references.
---

# Author resources

A `.tres` is a Godot Resource saved as text: a material, a theme, a collision shape, a curve, a custom Resource subclass. Scripts load them, scenes reference them, and the editor's Inspector edits them. An agent asked for a theme has two choices, hand-write the file or reach for `Theme.new()` in a script, and both are the runtime-code workaround the tool exists to avoid. So resources get the same commands scenes have.

## Create one

```bash
godot-cli resource new --output materials/wood.tres --type StandardMaterial3D \
  --property albedo_color --value "Color(0.6, 0.4, 0.2, 1)" \
  --property roughness --value 0.8 --project-root .
```

```text
[gd_resource type="StandardMaterial3D" format=3]

[resource]
albedo_color = Color(0.6, 0.4, 0.2, 1)
roughness = 0.8
```

That is byte for byte what Godot writes for the same material. Values are Variant text, as everywhere else: `Vector2(64, 16)` for a `RectangleShape2D` size, `0.8` for a float, `"\"text\""` for a string. A missing parent folder is created.

## Sub-resources and external files

A theme is the common case with parts inside it. A `StyleBoxFlat` for a button lives in the theme file as a sub-resource, and a font lives outside it as an external reference:

```bash
godot-cli resource new --output themes/main.tres --type Theme --project-root .

godot-cli resource sub add themes/main.tres --type StyleBoxFlat \
  --property bg_color --value "Color(0.1, 0.1, 0.1, 1)" \
  --property corner_radius_top_left --value 6 --project-root . --json
```

```json
{ "id": "StyleBoxFlat_vpj74", "summary": "added sub_resource StyleBoxFlat_vpj74" }
```

```bash
godot-cli resource set-property themes/main.tres --property Button/styles/normal \
  --value 'SubResource("StyleBoxFlat_vpj74")' --project-root .
godot-cli resource set-property themes/main.tres --property Label/colors/font_color \
  --value "Color(1, 1, 1, 1)" --project-root .
godot-cli resource set-property themes/main.tres --property Label/font_sizes/font_size \
  --value 20 --project-root .

godot-cli resource ext add themes/main.tres --type FontFile --path res://fonts/ui.ttf --project-root .
```

Theme entries are properties named `Type/category/name`: `Button/styles/normal`, `Label/colors/font_color`, `Label/font_sizes/font_size`, `Panel/styles/panel`. `resource set-property` targets the `[resource]` section when no target is given.

`resource sub remove` and `resource ext remove` take the id and refuse while anything still references it. `resource inspect --json` reads a file back with every property parsed and typed, and `resource validate` checks ids and references the way `scene validate` does.

## Use it from a scene

A scene points at a resource file through an external reference, which `assign_ext` writes in one op:

```json
{ "op": "assign_ext", "path": "/root/Main/Crate", "property": "material",
  "type": "Material", "res_path": "res://materials/wood.tres" }
```

or on the command line with `scene ext add` followed by `scene set-property ... --value 'ExtResource("...")'`. For a theme, set `theme` on the root Control of a UI scene the same way, and every child picks it up.

## What it does not do

There is no schema of Godot's classes in the tool, so `resource new --type Fooo` writes a file Godot will refuse to load, and a misspelt property name is written as given. `resource validate` catches ids and references, and running the game catches the rest; the [capture recipe]({{ base_url }}/how-to/run-and-capture/) applies to resources as much as scenes.
