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
godot-cli uid read assets/level.res
```

`uid read` takes the UID a file records from the file itself: a scene or
resource header, binary `.res` and `.scn` included, a script's `.uid` sidecar,
or an asset's `.import` file. It needs no cache, so it works on a fresh clone.

`.godot/uid_cache.bin` is Godot's own index of UIDs to paths. godot-cli reads it to resolve references, to detect a stale `uid://`, and to repair a catalog manifest whose scene moved.

## Check against the editor

The strongest check is a comparison with a file Godot wrote:

```bash
godot-cli scene compare-godot scenes/main.tscn scenes/main_godot_saved.tscn --json
```

```json
{ "matches_godot_save": true, "summary": "matches: scenes/main.tscn vs Godot reference scenes/main_godot_saved.tscn" }
```

You do not need the editor open to get that reference. `project resave` has
Godot save a copy under `.godot/godot-cli/resave/`, never over the file itself:

```bash
godot-cli project resave scenes/main.tscn --project-root . --json
```

It saves a scene the way the editor does. Godot runs headless with the editor
hint, builds the scene in a viewport the project's size, sends the pre-save
notification, packs it and saves it. So the copy holds what the editor would
store, not only what the file says: a 3D node's `position` comes back as
`transform`, and editor-only lines such as `anchors_preset` are kept. Nothing
outside `.godot/` is written. `--no-build` loads and saves the file as it is,
the old behaviour. An `AnimationPlayer` or `AnimationTree` with
`reset_on_save` has its RESET animation applied first, as the editor does.

A difference names the node and what differs: properties on one side only
(`here only: position; the Godot save only: transform`), or the first value
that differs. Two kinds of difference are listed under `skipped` rather than
failing the match:

- what a save to a new path always changes: ext_resource ids, renumbered, and
  uids, left out
- sub_resources in another order, or properties in another order. The editor writes its class order, and so
  does every godot-cli write, but a file written elsewhere may not; the
  editor's next save reorders it without changing what it says

An empty `skipped` with a match means the files agree everywhere.

Run over all 396 scenes in Godot's demo projects with Godot 4.8-beta1, it saved
every scene but the 20 that use C#, which that build cannot load. Of the 343
that a plain load-and-save also handles, 325 come out the same. The rest differ
in nodes inside imported `.glb` models, which a reimport assigns afresh, in
lines an older editor wrote, or in values the scene computes when it is built
(an IK chain, a pawn a `@tool` script snaps to its grid), which a plain save
leaves as the file had them.

`scene round-trip <path> --dry-run` is the weaker, faster check: parse the file, write it back, parse again, and confirm the structure survived.

The project runs the strong version in CI, once per Godot version in a matrix. Godot saves a fixture scene headless, godot-cli normalizes the same scene, and the two files are compared with `cmp`. That test is why the parser follows Godot's source rather than a description of it: `src/godot/hash.zig` comes from `core/templates/hashfuncs.h` and `core/string/ustring.cpp`, `src/godot/resource_uid.zig` from `core/io/resource_uid.cpp`, and Variant text from `core/variant/variant_parser.cpp`, with a line map in `src/godot/variant/godot_ref.zig` pointing at the functions each rule came from.

## Variant values

Property values are parsed into typed values, not carried around as strings, which is what makes `scene inspect` useful and what keeps `16.0` on a property while a component of the same value is written `2`, matching the editor in both places. The parser covers booleans and numbers, strings and StringNames, vectors, rects, transforms, colors, node paths, `Object(...)` bodies, arrays and dictionaries including typed ones, packed arrays including base64 `PackedByteArray`, and ext or sub resource references.

Anything it cannot parse is preserved verbatim and reported with `parse_error` instead of being rewritten, so an unknown construct survives an edit untouched.

## Version support

**Godot 4.6 is the minimum.** Every `[node]` line godot-cli writes carries a
`unique_id`, which the engine added in 4.6 ([`faddd60c40`](https://github.com/godotengine/godot/commit/faddd60c40), first released in 4.6-stable) to support
refactoring base and instantiated scenes. Earlier 4.x releases never wrote that
field and are not supported.

### The `[input]` layout depends on the Godot version

Input events are `Object(...)` values, and Godot 4.8 changed how it writes
them (engine commit [`d3a753d31d`](https://github.com/godotengine/godot/commit/d3a753d31d)).
Godot 4.8 puts each property of an event on its own line, with a space after
the colon. Godot 4.7 and earlier write an event on one line, with no spaces,
and end it with a line break. Both parse to the same events.

`project input apply` writes the layout of the project's own version, read from
`config/features` in `project.godot`, so the editor's next save leaves the
section alone. A project the editor has never opened names no version, and gets
the 4.8 layout. The 4.7 and 4.8 editors' own saves are test fixtures, and
godot-cli's output matches each byte for byte.

The round-trip suite runs against Godot 4.7 and 4.7.2, which must pass, and against the newest 4.8 prerelease, which is reported but does not block a push. It passes on all three today. Text scene format 3 is what Godot 4 writes. Binary `.scn` and `.res` files are not supported.
