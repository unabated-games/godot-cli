# Open asks

Trial 37 (2026-10-07) added a light to a 3D level, diffed it and proved it
against Godot's save, with no failed call and no hand edit. Its asks, ranked:

1. **A `compare-godot` match does not cover the editor's choice of
   properties** (M). `project resave` has Godot load the scene and save it
   without building it, so a line the editor would replace survives into the
   reference: `position = Vector3(...)` on a 3D node matched, where the editor
   writes `transform`. `scene validate` warns on that case
   (`property_not_stored`), and both descriptions now say so. The full fix
   is a resave that builds the scene first, as the editor does. Tried: an
   `instantiate(GEN_EDIT_STATE_MAIN)` then `pack()` in a headless script
   writes `transform` correctly, but against the 11 fixture scenes it dropped
   a script and an inline Gradient and rewrote a parent path with `#`. So it
   needs a real look at what the editor does differently, not a swap.
2. **Warn at write time, not only in validate** (S). `scene node add` with
   `position` on a 3D node returned no message, so the trial switched to
   `transform` on its own judgement. The `property_not_stored` check could
   run on the section a write produces and come back in `messages`.
3. **Say what `compare-godot` left out** (S). A match skips ext_resource ids
   and uids by design, and the trial diffed the files by hand to be sure of
   the rest. List the skipped differences in the result.
4. **A "before" copy without asking for one** (M). `--snapshot` has to be
   on the first write, or there is nothing to diff against outside git. A
   per-scene snapshot taken on a session's first write would make
   `scene diff` work after the fact.
5. **A capture of a camera-less 3D scene shows nothing** (M). `project run`
   says so (`no_camera_3d`). The trial suggested a temporary camera framing
   the scene's bounds, added for the run and never written to the file.

Trials 38 to 40 (2026-10-12) set up and repaired export presets with the new
`project export` commands. Their asks that are still open, ranked:

6. **Say what an apply changed, per preset** (S). Trial 40 grepped both files
   to confirm the teammate's settings and secrets survived a repair. Return
   each preset's changed keys and options, old value to new (secrets by
   name only).
7. **Check Android readiness before a full export** (M). Godot refuses an
   Android export for things outside the project: no Java or Android SDK in
   the editor settings, no debug keystore. `project export build` reports
   them only after a full Godot run. Reading the editor settings file would
   let `validate` say so up front.
8. **`project new` writes the `.gitignore` the project manager would** (S).
   Godot's project manager writes one ignoring `.godot/`. godot-cli's does
   not, so secrets written to `.godot/export_credentials.cfg` are one
   `git add .` from being committed. `apply` warns, but cannot fix it.
9. **Export every preset in one call** (S). Trials 38 to 40 each made one
   `build` call per preset. A `--all` that carries on past a failure and
   reports each would be one.
10. **Point a warning about a secret at the credentials file** (S). A
    missing-keystore warning points at the `[preset.N]` header, but the value
    lives in `.godot/export_credentials.cfg`.
11. **Check that a connection's method exists** (M). `scene connection add`
    checks the signal against the emitter's class, but not that the
    receiver's script defines the method. Trial 41 connected `_on_sitt` in a
    dry run without a warning; the typo would only show at run time. The
    script is GDScript, so this means finding `func <name>(` in it and in the
    scripts it extends.
12. **Show the events, not just a count** (S). `project input list` gives
    `event_count` per action, and an apply's `--dry-run` gives only names and
    counts, so trial 42 read raw `Object(...)` text to confirm its bindings.
    Each event as a line such as "A (physical)" or "left_x -1.0" would make
    both self-checking.
13. **Say how to check a settings-only change** (S). The rules end every
    change with `scene validate` and `project run`. An input-map change has no
    scene, and a project with no main scene cannot run. Trial 42 built a
    throwaway scene to test its bindings. A line on `project input validate`
    and `project run --scene ... --press` would cover it.
14. **`scene new --script`** (S). Attaching a script to a new scene takes
    `scene new`, `scene ext add` and `scene set-property script`. Trial 42
    needed all three for a one-node test scene.

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
- 0.26.0: trial 30's four asks. UID numbers are decimal strings in JSON; a missing uid cache is `uid_cache_missing`; MCP descriptions name fields, not flags, and `properties` has a constructor example; consecutive ext_resources stay adjacent, as Godot writes them. Clearing that last one turned up two more field-order gaps and five tests that had never run, all fixed. Then trial 31's three: `scene diff --properties` lists an added node's properties and resolves an instanced node's class; the agent rules give the `--scene res://...` fallback for a scene with no catalog entry; `project import` and `project run` say what the import writes into the project. Then trial 32's five, and a `scene node get` failure seen in passing: a pinned server's refusal of an outside path says where a scratch copy can go; `scene diff` reports resources and `unique_id` changes; a node or instance add dry run returns the section it would write; `scene validate` flags a 3D node's placement written as `position` and the like, swept against 218 classes Godot saved first; the agent rules cover MCP, the import's files, and camera-less 3D frames; and a missing node is `node_not_found`. Then trial 33's three: `--snapshot` on every write and `--auto-snapshot` under `.godot/`; `preview_sections` on `scene apply --dry-run`; the rules block's frame count. Then the last two: a whole-number float property keeps its `.0`, decided by the class table; and `project run` notes a 3D scene with no camera. Then trial 35's four: `compare-godot` compares uids and names the first difference; `project resave` makes the Godot save it compares against; `normalize` reports `changed`, with a preview on a dry run; and the `camera_3d` and `place_3d` recipes place and aim a 3D node.
- 0.27.0: trial 36's ask, `scene diff` taking `before`/`after` and `compare-godot` taking `file`/`reference`, with the old names still accepted over MCP. Trial 37's: `scene set-property` reports the text it wrote as `written`. A user session's: `project export` for export presets, which godot-cli had no way to write, then trials 38 to 40's `.gdignore`, Godot's refusal reasons, and repair of a hand-written file. Another session's: `scene node move` and `--index`, reparent warnings only for references that break, and `project input apply` in each editor's own layout. Trial 41's: `unknown_command` for a missing subcommand, Godot's own window size, and an early quit said as one. Trial 42's: `no_main_scene`, and a run summary that points at `log_tail`.
