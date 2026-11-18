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
| `duplicate_scene_id` | error | Two ext_resources, or two sub_resources, share an id. An ext_resource and a sub_resource may share one, as older files often do |
| `node_parent_order` | error | A node's `parent` refers to a node declared later in the file, which Godot reads as a parent path that vanished. A parent inside an instanced scene needs no section of its own |
| `resource_section_order` | error | An `ext_resource` appears after a `sub_resource` |
| `stale_uid_for_path` | error | A `uid://` reference disagrees with the project's UID cache |
| `nonstandard_scene_id` | warning | An id does not match the shape the editor writes, such as `1_a` instead of `1_abc12` |
| `invalid_node_unique_id` | warning | A node's `unique_id` is not a value Godot would generate |
| `property_type_mismatch` | error | A property's value is the wrong Variant type for its class, e.g. `visible = Vector2(1, 2)` |
| `unknown_signal` | error | A connection names a signal the emitting class does not have, and its script does not declare, nor any script it extends |
| `unknown_method` | warning | A connection calls a method the receiving node does not have: not in its script, nor in what the script extends, nor in its class. Godot logs "Method not found" each time the signal fires |
| `unknown_property` | warning | A property neither the node's class nor its script declares. With `--project-root` the script, the scripts it extends and an instanced scene's root are read too. Godot sets nothing, logs nothing, and the editor's next save drops the line |
| `unknown_theme_override` | warning | A theme override the node's class has no theme item for, such as `theme_override_colors/font_colour`, or one whose value is the wrong type. Nothing draws with it, and the editor's next save drops it |
| `connection_node_missing` | error | A connection names a node that is not in the scene |
| `property_not_stored` | warning | A 3D node placed with `position`, `rotation`, `scale` or the like, which the editor's next save turns into `transform` |
| `control_under_node2d` | warning | A `Control` under a `Node2D` has no parent rect, so anchors give it no size and it may draw nothing |
| `dangling_ext_resource` | error | A property references an `ExtResource` id nothing declares |

### The checks that read the file the way Godot would

`property_type_mismatch`, `unknown_signal` and `unknown_property` come from a
table generated out of Godot's own class reference (718 classes, 4422
properties, 399 signals, 4350 methods), and `unknown_theme_override` from the
theme items each class offers, as the engine lists them. They catch the
mistakes that otherwise cost a run to find:

```text
[err] property_type_mismatch: Control.visible is bool, and this value is vector2:
      Godot coerces it and the file still loads, so only the running frame shows the damage
[err] unknown_signal: Button does not emit a signal named pressd, and its script does not
      declare one either, so this connection never fires
[warn] unknown_property: HUD sets max_helht, which neither ProgressBar (the root of
      res://ui/health_bar.tscn) nor res://ui/bar.gd declares, so Godot sets nothing and says
      nothing: the value never reaches the node, and the editor's next save drops the line.
      Did you mean max_health?
[warn] unknown_theme_override: Title sets theme_override_constants/font_shadow_color, which
      Label has no theme item for: the override is stored, nothing draws with it, and the
      editor's next save drops the line. Did you mean theme_override_colors/font_shadow_color?
```

`unknown_property` is a warning rather than an error because a property can
come from places the check cannot always read. On a node with a script it
reads the script, built-in ones included, and the scripts it extends by path or
by `class_name`. On an instanced node it reads the instanced scene's root and
that root's script. That needs `--project-root`; without it, scripted and
instanced nodes are skipped. A script that answers properties itself
(`_set`, `_get_property_list`), a C# script, a binary `.scn` and an imported
model are skipped too. So are `metadata/level` and the handful of names Godot
registers as internal, `layout_mode` and `anchors_preset` among them, which
the editor writes into every scene it touches and the class reference never
mentions.

They stay quiet about anything they cannot speak for: a class the table does
not carry, a `metadata/*` key, a script they cannot read, an override inside
another scene's instance, and a connection whose endpoint lives inside an
instance.

If a run answers `uid_cache_unreadable`, the damaged file is Godot's
`.godot/uid_cache.bin` and not the scene you passed. Delete it and run the
project once to rebuild it. `scene validate` itself does not fail on that any
more; it skips the `stale_uid_for_path` check and says so in `messages`.

**So read a clean `scene validate` for what it is.** It says nothing here was
found wrong; it does not say every property is real, every signal exists, or
every value is right. A property on a node whose script cannot be read
passes unchecked, and without `--project-root` so does every property on a
scripted or instanced node. A partial check that says
nothing reads exactly like a complete one that found nothing, which is why the
step after validating is [running the game]({{ base_url }}/how-to/verify-a-change/)
rather than calling it done.
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
`checks_failed` failure, keeping the issues in `data`, so `ok`, the exit code,
and the error flag an MCP client sets all agree.

Two of the checks also run when a command writes. A write that adds a 3D
node's `position`, or a connection to a method the receiver does not have,
says so in `messages` straight away, on a `--dry-run` too, rather than leaving
it for the next `scene validate`.

Every check has been swept against the 533 scenes and resources in Godot's own
demo projects, files the editor saved itself. Apart from the layout warning
`control_under_node2d`, the only issues reported there are three connections
to methods the demos' scripts really do not define.

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

Without `--properties` you get added, removed, and retyped nodes, which is the level to review a structural change at. With it you also get changed property values, which is what you want when the tree is the same and something moved. Both levels list the resources too: ext_resources added, removed, or changed in type or uid, and sub_resources by id. A node whose `unique_id` changed at the same path is reported as `unique_id_changed`.

The diff is between two files, so keep a copy before an edit, or use a snapshot. A session keeps one for you: the MCP server, or a shell with `GODOT_CLI_SESSION` set to any name, copies each scene to `.godot/godot-cli/session/<its path>` before the session's first write to it, and the result's `messages` say where. `scene diff .godot/godot-cli/session/scenes/main.tscn scenes/main.tscn` then shows everything the session changed. A scene the session created has no earlier state, so its copy is the scene as `scene new` wrote it. To keep a copy of your own:

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
