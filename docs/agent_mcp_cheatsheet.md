# godot-cli over MCP

The same commands as the shell cheat sheet, in the form a tool call takes.
There is **no `project-root` argument** here: a server started with
`--project-root` is bound to that project, adds the option to every call, and
refuses paths outside it. `project_show` reports the absolute root.

## The thirteen that cover most sessions

A server started with `--toolset core` serves exactly these, for a client that
loads every schema up front.

| Tool | Arguments | For |
|------|-----------|-----|
| `project_new` | `name`, `main-scene`, `width`, `height` | An empty folder becomes a Godot project |
| `project_show` | — | Main scene, window size, autoloads, the absolute root |
| `project_input_apply` | `intent-json: {"actions": [...]}` | The input map, keyboard and controller |
| `scene_new` | `output`, `root-name`, `root-type` | A new scene file |
| `scene_describe` | `file` | The whole scene in one call before changing it |
| `scene_apply` | `file`, `intent-json` or `patch-json` | Any number of edits as one write |
| `scene_instance_add` | `file`, `parent`, `name`, `catalog-id` or `scene` | Reuse a scene you already have |
| `scene_connection_add` | `file`, `from`, `signal`, `to`, `method` | Wire a signal in the scene, not in `_ready()` |
| `resource_new` | `output`, `type`, `properties` | A `.tres` the editor would have saved |
| `catalog_list` | — | What this project already has to reuse |
| `catalog_add` | `file`, `id`, `summary` | Register a component so agents find it |
| `scene_validate` | `file` | Ids, references, property types, signal names |
| `project_run` | `frames`, `click`, `press`, `type` | Run it and look at the frame |

Everything else — renames, reparents, extracts, moves, diffs, the batch runner
— is a tool too; `tools/list` has all ninety-one.

## A session, start to finish

```json
{"name": "scene_describe", "arguments": {"file": "scenes/main.tscn"}}
```

```json
{"name": "scene_apply", "arguments": {
  "file": "scenes/main.tscn",
  "intent-json": {"steps": [
    {"recipe": "add_node", "parent": "/root/Main", "name": "HUD", "type": "Control",
     "properties": {"anchor_right": 1.0, "anchor_bottom": 1.0}},
    {"recipe": "instance_catalog", "parent": "/root/Main/HUD", "name": "Health",
     "catalog_id": "ui/health_bar"}
  ]}
}}
```

```json
{"name": "scene_connection_add", "arguments": {
  "file": "scenes/main.tscn", "from": "/root/Main/HUD/Play",
  "signal": "pressed", "to": "/root/Main", "method": "_on_play_pressed"
}}
```

```json
{"name": "scene_validate", "arguments": {"file": "scenes/main.tscn"}}
```

```json
{"name": "project_run", "arguments": {"frames": 40,
  "type": ["/root/Main/%Email@10=someone@example.com"],
  "click": ["/root/Main/Box/Submit@20"]}}
```

The run returns the last frame as an image alongside the log, so the loop ends
by looking at what you built rather than by asserting it is done.

## Reading a result

Every tool returns the CLI's envelope:

```json
{"ok": true, "data": { … }, "messages": [ … ], "failure": null}
```

`ok` follows the exit code, so a `scene_validate` that found errors comes back
`ok: false` with `failure.kind: "checks_failed"` **and** its issues in `data`.
A failure caused by the call itself names what to fix:

```json
{"ok": false, "failure": {"kind": "invalid_property_value", "details":
  {"op": "node_add", "field": "text", "value": "Paused",
   "hint": "not valid Variant text; for a string write \"\\\"Paused\\\"\""}}}
```

`messages` is where a tool tells you something it did that you did not ask for
— marking an instance editable, say, or that a headless run has no frame to
show you what the click landed on.

## Values

Property values are Godot Variant text, not plain strings: `"Vector2(1, 2)"`,
`"1.5"`, `"true"`, and a string carries its own quotes, `"\"Paused\""`. In a
`properties` object numbers and booleans are JSON. A bare word is rejected
before anything is written, and so is a field the op or recipe does not take.

## Resources worth reading

| URI | What |
|-----|------|
| `godot-cli://docs/quickstart` | The one-page guide; read before the first edit |
| `godot-cli://docs/recipes` | Every intent recipe and its fields |
| `godot-cli://docs/godot-basics` | Anchors, containers, and what Godot assumes |
| `godot-cli://docs/scene-authoring` | The full patch and intent reference |
| `godot-cli://catalog` | This project's components, live |
