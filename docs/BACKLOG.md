# Open asks

**Nothing is outstanding.** Every ask from the agent trials and from the
maintainers has shipped, as of v0.20.1 (2026-09-09). The record of what they
were is below, by release; the changelog carries the detail.

## How this list is kept

A trial that hand-edits a `.tscn`, works around a tool, or spends five calls on
something that should take one is reporting a gap, and each of those becomes an
entry here with the trials that hit it and a size (S is an hour or two, M a
day, L several days). Entries are ranked by how much they would change what an
agent produces, weighted by how often a trial actually hit it, and worked
through in that order.

Four trials in a row hand-edited a scene file at some point, and every one of
them was pointing at a real bug or a real gap rather than being careless: a
generated id that collided, a connection that could not cross an instance
boundary, a header attribute written as a property. That is the signal worth
chasing first when the next one turns up.

## Closed since 0.7.0

For the record, the trials' asks that have shipped, by release. The changelog carries the detail.

- 0.7.1: the one-page quickstart and the Godot basics doc.
- 0.8.0: the MCP server, positional arguments in the command tree.
- 0.9.0: `project new`, inline intents and patches, `--properties` objects, the freed-invocation fix, `unique_name` with `properties`, the quoting doc fix, named missing files.
- 0.10.0: intent and patch shapes in the tool help, `unknown_recipe`, `properties` on instances, integer options, the session prompt as a resource, the absolute root from `project show`, `scene recipes`, `color` on static bodies, the default icon, window settings in `project show`, plumbing flags hidden from MCP, the empty `scene_uid` message.
- 0.11.0: `project run` and `project import` with presses, clicks, the log tail, the image result, and the project's resolution; header uids on new files; required options in the schemas; float coercion; step-indexed intent failures; `assign_ext` inference; `camera_2d` position; the header-uid stale check; uids on scene and resource references.
- 0.12.0: `scene extract` with catalog registration and script-reference messages; the recursive-remove undo fix; properties on `scene node get`; op aliases; scalar `node_set` values; details on every failure; `control_under_node2d`; `--frame-at`; the reparent undo fix; snapshot cleanup on a rejected apply.
- 0.13.0: the cursor moves off the node after `project run --click`, so the frame shows the `normal` style, with `--keep-cursor` to hold the hover style; unknown fields on patch ops and intent steps rejected with the accepted list; `id_hint` named when a generated id collides; `step` on every patch op failure.
- 0.14.0: the whole of Godot's keyboard and controller reachable from `project input apply`, with mouse buttons, modifier flags, raw numbers, the reference in its help, and the `axis_value` float fix; `project run --press`/`--click` working on projects with autoloads; a headless `--click` saying it verified nothing.
- 0.15.0: property type checking and unknown-signal detection in `scene validate`, from a generated Godot class table; a colliding generated sub_resource id takes a suffix instead of failing; `properties` on `node_set` and `scene set-property`; `unique_name` on the `node_add` op.
- 0.16.0: the site brought up to date (a "verify a change by running the game" how-to, a "refactor an existing project" how-to, the run loop and the class-table checks on the landing page, `--project-root` on `scene connection list`); `scene describe`; instanced nodes resolved to their real class; script references reported after remove, rename and reparent; `ok` following the exit code; the site brought up to date; `--project-root` on `scene connection list`.
- 0.17.0: connecting a signal to a node inside an instance (marking it editable); `scene extract --editable`; scripted nodes' signals checked against their scripts; `mcp --toolset core`; the MCP cheat sheet resource.
- 0.18.0: `scene extract --retarget-dropped-connections`, `--editable` and the catalog prose options; `project move --import` and `--rename-ids`; `catalog add --signal-doc`; `scene set-property` refusing a header attribute.
- 0.19.0: repeatable `--frame-at` and `--log-lines`; a headless click that cannot reach its target reported instead of passing silently; undo patches restoring child order and unique ids; a `properties` object on the `node_set` recipe.
- 0.20.0: usage prose in `catalog list`; `manifest_res_path` under a relative project root (and with it the id seed); a stated minimum Godot version; a per-event input device; the `[input]` formatting question answered.
