# Open asks

Everything the agent trials and the maintainers have asked for that is not yet built, as of v0.18.0 (2026-09-08). Trials 9 to 16 built a small 2D slice from an empty folder; trials 17 to 19 modified an existing project; trials 20 to 23 built styled menus and input maps and verified them from a run. Each item names the trials that asked for it, why it matters, and a size: S is an hour or two, M is a day, L is several days.

Items are grouped by area and ordered by how much they would change what an agent produces. Closed asks are listed at the end so the picture is complete.

## Next up, in order

Ranked by how much each would change what an agent produces, weighted by how
often a trial actually hit it. The sections below carry the detail; this is the
order to work through them.

1. **The `project run` niceties**: a first-and-last frame pair, `--log-lines`, and the headless-click investigation (S each).
2. **The long tail**: undo child order and unique ids, manifest notes in `catalog list`, `manifest_res_path`, a stated minimum Godot version, per-event input device, the engine-dependent `[input]` formatting.

## Correctness and validation

**Record child order and unique ids in undo ops.** Trials 18, 19. An undo patch for a removal re-adds the node at the end of its parent and with a fresh unique id, so the restore is not byte for byte. Size S to M.

## Refactoring an existing project

## The MCP surface

**Manifest usage notes in `catalog list`.** Trial 16. `when_not_to_use` and `notes` are only in `catalog show`, so choosing between similar widgets costs a call per candidate. Size S.

**`manifest_res_path` in `catalog add` output.** Trial 16. Comes back empty with no explanation. Size S.

## `project run`

**A first-and-last frame pair.** Trial 16. `--frame-at` keeps one chosen frame; a before-and-after comparison in one run would want frame 0 as well. Size S.

**A `log-lines` option and a frames upper hint.** Trial 15. The log tail is fixed at 40 lines. Size S.

**Why clicks do not reach Controls under `--headless`.** A headless `--click` run now says it verified nothing, which closes the false pass, but the cause is still open. With the installed Godot 4.8.dev4 the button's signal never fires headless while the same run with a window fires it; the headless root viewport is also 64x64 rather than the project's size. Godot master's `DisplayServerHeadless::process_events` does flush buffered input and `--press` arrives headless either way, so this may be specific to GUI routing or to that build. Worth pinning to a released Godot, and the smoke test should then assert a click *did* something rather than that the option parsed. Size S to investigate.

**A specific input device on an event.** `project input apply` writes `"device":-1` (All Devices) on every event; a binding pinned to one joypad index is not expressible. Size S.

**The `[input]` section's formatting is engine-build dependent.** godot-cli writes each event object inline, which matches Godot master's `VariantWriter` and the committed fixture, but the installed 4.8.dev4 writes one property per line, so a save from that editor reformats the whole section and makes a noisy diff. Values round-trip identically either way and Godot parses both. Worth pinning to a released Godot before changing anything. Size S once the target version is decided.

## Docs and site

**A stated minimum Godot version.** Trial 10. Every `[node]` line carries `unique_id=`, which older Godot 4 releases do not understand, and nothing says which versions are supported beyond the CI matrix. Size S.

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
- 0.16.0: `scene describe`; instanced nodes resolved to their real class; script references reported after remove, rename and reparent; `ok` following the exit code; the site brought up to date; `--project-root` on `scene connection list`.
- 0.17.0: connecting a signal to a node inside an instance (marking it editable); `scene extract --editable`; scripted nodes' signals checked against their scripts; `mcp --toolset core`; the MCP cheat sheet resource.
- 0.18.0: `scene extract --retarget-dropped-connections`, `--editable` and the catalog prose options; `project move --import` and `--rename-ids`; `catalog add --signal-doc`; `scene set-property` refusing a header attribute.
- Unreleased: the site brought up to date — a "verify a change by running the game" how-to, a "refactor an existing project" how-to, the run loop and the class-table checks on the landing page, and `--project-root` accepted by `scene connection list` like its siblings.
