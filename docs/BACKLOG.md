# Open asks

Four asks are open, from trial 35 (2026-09-25), the pre-release trial for
0.26.0. It passed everything it was set, and a Godot re-save of its scene
matched byte for byte. These are what it found beyond that. Everything else
has shipped, and the record is below, by release.

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

## Open

1. **`scene compare-godot` ignores UIDs.** (S) It reports `matches_godot_save: true` for a scene whose ext_resource carries the wrong `uid=`. That was reproduced on trial 35's own scene by swapping a mesh's UID. A match should mean the UIDs agree too. At least where both sides carry one, a difference should be a mismatch. And the description should say what the comparison covers, and why it takes both `reference` and `saved`.
2. **There is no godot-cli way to make the Godot save that `compare-godot` compares against.** (S–M) Trial 35 wrote a GDScript and ran Godot headless by hand to re-save its scene under `.godot/`. `project import` and `project run` already drive Godot, so a `project resave <scene> --output <path>` would make "is this editor-clean?" one call.
3. **`scene normalize --dry-run` does not say whether a write would change anything.** (S) Its result is "prepared scene save", so it cannot answer "is this file already editor-clean?". A `changed` field, or the `preview_sections` that `scene apply` now returns, would.
4. **Nothing helps place or aim a 3D node.** (M) The recipes are mostly 2D, with `camera_2d` but no `camera_3d`, and there is no look-at helper. Trial 35 worked out a camera's rotation matrix by hand, and it checked the row-major basis order in the frame, not the docs. The docs now state that order.

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
- Unreleased: trial 30's four asks. UID numbers are decimal strings in JSON; a missing uid cache is `uid_cache_missing`; MCP descriptions name fields, not flags, and `properties` has a constructor example; consecutive ext_resources stay adjacent, as Godot writes them. Clearing that last one turned up two more field-order gaps and five tests that had never run, all fixed. Then trial 31's three: `scene diff --properties` lists an added node's properties and resolves an instanced node's class; the agent rules give the `--scene res://...` fallback for a scene with no catalog entry; `project import` and `project run` say what the import writes into the project. Then trial 32's five, and a `scene node get` failure seen in passing: a pinned server's refusal of an outside path says where a scratch copy can go; `scene diff` reports resources and `unique_id` changes; a node or instance add dry run returns the section it would write; `scene validate` flags a 3D node's placement written as `position` and the like, swept against 218 classes Godot saved first; the agent rules cover MCP, the import's files, and camera-less 3D frames; and a missing node is `node_not_found`. Then trial 33's three: `--snapshot` on every write and `--auto-snapshot` under `.godot/`; `preview_sections` on `scene apply --dry-run`; the rules block's frame count. Then the last two: a whole-number float property keeps its `.0`, decided by the class table; and `project run` notes a 3D scene with no camera.
