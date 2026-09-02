---
title: Keep godot-cli output byte-compatible with Godot
description: How save preparation, id sessions, and the UID cache work, and how to check output against a file the editor wrote.
---

# Stay byte-compatible with Godot

Writing a scene Godot can open is not hard. Writing the scene Godot itself would have written is harder, and it is what keeps generated files out of your diffs as noise.

## What save preparation does

Every write goes through the same save path unless you pass `--no-prepare-save`. It repairs and renumbers ids that do not match the editor's shape, sorts `ext_resource` entries, recounts `load_steps`, and orders sections so resources come before nodes and parents before children.

```bash
godot-cli scene normalize scenes/main.tscn --output scenes/main.tscn \
  --project-root . --resource-path res://scenes/main.tscn --godot-save-format
```

`--godot-save-format` aims for byte-identical output against what the editor would write for the same content. `--normalize-properties` goes further and rewrites every property value through the Variant parser, so float formatting and class aliases end up consistent across a file that several tools have edited.

## Ids, and why seeding matters

Godot generates ext and sub resource ids from a per-file seed. Two runs over the same scene will not naturally produce the same ids, which shows up as a diff with no content change.

`--project-root` and `--resource-path` give the writer the `res://` path to seed from. On top of that, the id session cache at `.godot/scene_id_cache.json` remembers which id was used for which referrer, so repeated edits keep the ids the editor last wrote.

To adopt the ids from a scene Godot just saved:

```bash
godot-cli uid session import --referrer res://scenes/main.tscn \
  --from scenes/main_godot_saved.tscn --project-root .
```

Resource UIDs are separate: `uid://` values come from a hash of the resource path, implemented from `core/io/resource_uid.cpp`.

```bash
godot-cli uid encode 1350303725746704497
godot-cli uid decode uid://tidkmw585t0t
godot-cli uid create-for-path --project-name MyGame --resource-path res://main.tscn main.tscn
godot-cli uid cache list --project-root .
```

`.godot/uid_cache.bin` is Godot's own index of UIDs to paths. godot-cli reads it to resolve references, to detect a stale `uid://`, and to repair a catalog manifest whose scene moved.

## Check against the editor

The strongest check is a comparison with a file Godot wrote:

```bash
godot-cli scene compare-godot scenes/main.tscn scenes/main_godot_saved.tscn --json
```

```json
{ "matches_godot_save": true, "summary": "matches: scenes/main.tscn vs Godot reference scenes/main_godot_saved.tscn" }
```

`scene round-trip <path> --dry-run` is the weaker, faster check: parse the file, write it back, parse again, and confirm the structure survived.

The project runs the strong version in CI. Godot 4.7 saves a fixture scene headless, godot-cli normalizes the same scene, and the two files are compared with `cmp`. That test is why the parser follows Godot's source rather than a description of it: `src/godot/hash.zig` comes from `core/templates/hashfuncs.h` and `core/string/ustring.cpp`, `src/godot/resource_uid.zig` from `core/io/resource_uid.cpp`, and Variant text from `core/variant/variant_parser.cpp`, with a line map in `src/godot/variant/godot_ref.zig` pointing at the functions each rule came from.

## Variant values

Property values are parsed into typed values, not carried around as strings, which is what makes `scene inspect` useful and what keeps `16.0` on a property while a component of the same value is written `2`, matching the editor in both places. The parser covers booleans and numbers, strings and StringNames, vectors, rects, transforms, colors, node paths, `Object(...)` bodies, arrays and dictionaries including typed ones, packed arrays including base64 `PackedByteArray`, and ext or sub resource references.

Anything it cannot parse is preserved verbatim and reported with `parse_error` instead of being rewritten, so an unknown construct survives an edit untouched.

## Version support

The round-trip suite is verified against Godot 4.7. Text scene format 3 is what Godot 4 writes. Binary `.scn` and `.res` files are not supported.
