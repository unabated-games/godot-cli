---
title: Review and validate generated scene changes
description: Read validation errors, diff scenes at node and property level, and decide whether a generated change is right before committing it.
---

# Review and validate changes

A generated scene is a diff like any other, and the same review question applies: does this file say what someone meant it to say. These commands answer it without opening the editor.

## Validate

```bash
godot-cli scene validate scenes/main.tscn --project-root . --json
godot-cli scene validate-batch scenes/*.tscn --project-root . --json
```

Validation exits 1 when it finds an error, and returns every issue with a line number, a severity, and a machine-readable kind:

| Kind | Severity | What it means |
|------|----------|---------------|
| `duplicate_scene_id` | error | Two ext or sub resources in the file share an id |
| `node_parent_order` | error | A node's `parent` refers to a node declared later in the file, which Godot reads as a parent path that vanished |
| `resource_section_order` | error | An `ext_resource` appears after a `sub_resource` |
| `stale_uid_for_path` | error | A `uid://` reference disagrees with the project's UID cache |
| `nonstandard_scene_id` | warning | An id does not match the shape the editor writes, such as `1_a` instead of `1_abc12` |
| `invalid_node_unique_id` | warning | A node's `unique_id` is not a value Godot would generate |
| `property_type_mismatch` | error | A property's value is the wrong Variant type for its class, e.g. `visible = Vector2(1, 2)` |
| `unknown_signal` | error | A connection names a signal the emitting class does not have, and its script does not declare |
| `connection_node_missing` | error | A connection names a node that is not in the scene |
| `control_under_node2d` | warning | A `Control` under a `Node2D` has no parent rect, so anchors give it no size and it may draw nothing |
| `dangling_ext_resource` | error | A property references an `ExtResource` id nothing declares |

### The checks that read the file the way Godot would

`property_type_mismatch` and `unknown_signal` come from a table generated out of
Godot's own class reference — 520 classes, 3933 properties, 377 signals — so
they catch the two mistakes that otherwise cost a run to find:

```text
[err] property_type_mismatch: Control.visible is bool, and this value is vector2:
      Godot coerces it and the file still loads, so only the running frame shows the damage
[err] unknown_signal: Button does not emit a signal named pressd, and its script does not
      declare one either, so this connection never fires
```

Both are deliberately quiet about anything the table cannot speak for: a class
it does not carry, a `theme_override_*` entry, a `metadata/*` key, a script's
exported variables, and a connection whose endpoint lives inside an instance.
A correct scene is never reported. With `--project-root` the emitting node's
script is read too, so a signal the script declares itself passes.

A real one reads like this:

```json
{
  "severity": "err",
  "kind": "node_parent_order",
  "message": "node 'Player' parent 'Playfield' is declared later in the file (Godot instantiate: parent path vanished)",
  "line": 5
}
```

A validate that found errors exits 1 and answers `ok: false` with a
`checks_failed` failure, keeping the issues in `data` — so `ok`, the exit code,
and the error flag an MCP client sets all agree.

`stale_uid_for_path` needs `--project-root`, since it is a question about the project, not the file on its own. Resources get the same treatment with `resource validate` and `resource validate-batch`.

Validation does not open the files a scene points at. For that, `scene refs` resolves every `ext_resource` to a filesystem path and reports whether it is there:

```bash
godot-cli scene refs scenes/main.tscn --project-root . --json
```

```json
{ "id": "1_a", "type": "Script", "path": "res://missing.gd",
  "filesystem_path": "./missing.gd", "exists": false }
```

## Diff

```bash
godot-cli scene diff before.tscn after.tscn --json
godot-cli scene diff before.tscn after.tscn --properties --json
```

Without `--properties` you get added, removed, and retyped nodes, which is the level to review a structural change at. With it you also get changed property values, which is what you want when the tree is the same and something moved.

The diff is between two files, so keep a copy before an edit, or use a snapshot:

```bash
godot-cli scene apply scenes/main.tscn --patch change.json --project-root . \
  --snapshot scenes/main.before.tscn --json
godot-cli scene diff scenes/main.before.tscn scenes/main.tscn --properties --json
```

## Read the file without reading the text

```bash
godot-cli scene node list scenes/main.tscn --json
godot-cli scene node get scenes/main.tscn /root/Main/Player --json
godot-cli scene inspect scenes/main.tscn --json
```

`inspect` returns each section with its properties parsed: a name, the Variant kind, the raw text, and a typed value where one is available. A property that failed to parse comes back with `parse_error` set rather than failing the whole command, which is how you find a value that is subtly malformed.

## Undo a change

```bash
godot-cli scene restore scenes/main.tscn --snapshot scenes/main.before.tscn
```

Or apply the undo patch that `--write-undo-patch` produced during the edit. Both take `--dry-run`.

## What to check in review

Validation passing means the file is well formed, not that the change is right. The things worth a human eye:

Nodes are in the tree, not created in `_ready()`. `scene node list` shows the structure that will exist when the scene opens; if a HUD is missing from it, the layout is being built in code.

Reused components are instanced, not copied. An instanced component shows as a node with `instance=ExtResource(...)` and no children in the parent scene. A copied one shows as a subtree that duplicates the component.

Presentation is on the nodes, not only in scripts. `scene inspect` lists the theme overrides and layout properties, so a Control with no styling and a script full of `add_theme_*_override` calls is easy to spot.

## In CI

```bash
godot-cli scene validate-batch scenes/*.tscn --project-root . --json
godot-cli catalog validate --project-root . --json
```

Both exit 1 on failure, so they work as build steps. If you generate the catalog digest, regenerate it and check the tree is clean:

```bash
godot-cli catalog export --project-root . --output AGENTS.md
git diff --exit-code AGENTS.md
```
