# Open asks

Everything the agent trials and the maintainers have asked for that is not yet built, as of v0.15.0 (2026-09-08). Trials 9 to 16 built a small 2D slice from an empty folder; trials 17 to 19 modified an existing project; trials 20 to 23 built styled menus and input maps and verified them from a run. Each item names the trials that asked for it, why it matters, and a size: S is an hour or two, M is a day, L is several days.

Items are grouped by area and ordered by how much they would change what an agent produces. Closed asks are listed at the end so the picture is complete.

## Next up, in order

Ranked by how much each would change what an agent produces, weighted by how
often a trial actually hit it. The sections below carry the detail; this is the
order to work through them.

1. **The site describes the tool as it was at 0.10.0** (M). The only item here that decides whether anyone adopts the tool at all — `project run`, clicks, `scene extract`, the input map and the existing-project workflow are all invisible to a new reader. Four releases stale now.
2. **The `scene validate` envelope over MCP** (S). Newly urgent: 0.15.0 adds two more error kinds to validate, so more sessions meet an envelope that says `ok: true` next to `error_count: 2` and exit 1, and an MCP client marks the whole call an error.
3. **Real root type for instanced nodes in `scene node list`** (S). The most-cited item in this file — trials 11, 12, 17 and 18 — and the answer is already in a file the command is handed.
4. **A `script_refs` check after removes, renames, and reparents** (M). The same class of silent breakage as the property and signal checks that just shipped: the scene is right, a script's `$Path` is not, and only a run finds it.
5. **A `scene describe` discovery command** (M). Seven calls to learn one existing scene; the refactoring workflow starts with this every time.
6. **Check a scripted node's signals against its script** (S). Closes the hole the new `unknown_signal` check deliberately leaves open, and lets `scene connection add` refuse a typo at write time.
7. **A core toolset, and an MCP-shaped cheat sheet** (S each). Six trials between them. Cheap, and they cut what every MCP session pays before it does anything.
8. **The refactoring polish**: `scene extract --retarget-dropped-connections`, `project move --import`, fresh ext_resource ids, `--tags`/`--when-to-use`/`--signal-docs` (S each). Each removes a hand step from a refactor that otherwise works.
9. **The `project run` niceties**: a first-and-last frame pair, `--log-lines`, and the headless-click investigation (S each).
10. **The long tail**: undo child order and unique ids, manifest notes in `catalog list`, `manifest_res_path`, a stated minimum Godot version, per-event input device, the engine-dependent `[input]` formatting.

## Correctness and validation

**Check a scripted node's signals against its script.** The `unknown_signal` check skips any node carrying a script, because a script may declare its own signals and the document-level validator cannot read the file. `gdscript_scan` already parses `signal` declarations, so with the project root the check could cover scripted nodes too, and `scene connection add` could refuse a typo at write time rather than at the validate step after it. Size S.

**Record child order and unique ids in undo ops.** Trials 18, 19. An undo patch for a removal re-adds the node at the end of its parent and with a fresh unique id, so the restore is not byte for byte. Size S to M.

**Real root type for instanced nodes in `scene node list`.** Trials 11, 12, 17, 18. Instanced nodes report `PackedScene`. Reading the instanced scene's root type needs the project root, which `scene node list` accepts and ignores today. Size S.

**The `scene validate` envelope over MCP.** Trial 19. Issues come back as `ok: true` with `error_count: 1` and exit code 1, so the MCP client marks the result as an error while the JSON says ok. Either `ok: false` with a failure, or a normal result with issues. This is a design decision about the envelope that every validate-shaped command shares. Size S once decided.

**A `script_refs` check after removes, renames, and reparents.** Trials 17, 18. `scene extract` now lists script lines that reach into the moved subtree; the same scan should run for any structural change, flagging `$Path` and `%Name` references that no longer resolve. Size M.

## Refactoring an existing project

**`scene extract --retarget-dropped-connections root`.** Trial 19. A connection that crosses the extraction boundary is dropped and listed; both existing-project trials then re-created it inside the new scene against the new root and moved the handler into a root script by hand. The option would re-create it and name the method to add. Size S.

**`project move --import`.** Trials 17, 19. Validation reports `uid_path_mismatch` after a move until Godot's import refreshes the uid cache. The move says so now; running the import from the move would make "validate after every edit" hold for that step. Size S.

**Fresh ext_resource ids on extract and move.** Trials 18, 19. The instance created by an extraction keeps the id of the ext_resource it replaced, and `project move` keeps `Script_player` pointing at `hero.gd`. Correct, but before-and-after diffs read oddly. An optional rename with a message. Size S.

**`--tags` and `--when-to-use` on `scene extract`, `--signal-docs` on `catalog add`.** Trials 17, 19. So the catalog entry made during a refactor is as complete as one made deliberately. Size S.

**A `scene describe` discovery command.** Trial 19. Discovering an existing scene took seven calls: node list, inspect, connection list, refs, catalog list and show, node get. One call merging nodes with properties, connections, references, and the script paths that reach into the scene would halve the discovery step. Size M.

## The MCP surface

**A core toolset.** Trials 10, 12, 14, 15. The server lists 90 tools; the quickstart names the ten that cover most sessions, and clients that defer schemas cope. A client that loads every schema up front pays for all 90. A `--toolset core` flag on `mcp`, or a tag in each description, would let a client load the ten in one step. Size S.

**Manifest usage notes in `catalog list`.** Trial 16. `when_not_to_use` and `notes` are only in `catalog show`, so choosing between similar widgets costs a call per candidate. Size S.

**An MCP-shaped cheat sheet.** Trials 15, 16. The quickstart's commands are shell lines; the "Over MCP" section comes last and the `--project-root` table is noise for a bound server. Either a second cheat sheet in tool-and-arguments form, or a variant of the quickstart served only as the MCP resource. Size S.

**`manifest_res_path` in `catalog add` output.** Trial 16. Comes back empty with no explanation. Size S.

## `project run`

**A first-and-last frame pair.** Trial 16. `--frame-at` keeps one chosen frame; a before-and-after comparison in one run would want frame 0 as well. Size S.

**A `log-lines` option and a frames upper hint.** Trial 15. The log tail is fixed at 40 lines. Size S.

**Why clicks do not reach Controls under `--headless`.** A headless `--click` run now says it verified nothing, which closes the false pass, but the cause is still open. With the installed Godot 4.8.dev4 the button's signal never fires headless while the same run with a window fires it; the headless root viewport is also 64x64 rather than the project's size. Godot master's `DisplayServerHeadless::process_events` does flush buffered input and `--press` arrives headless either way, so this may be specific to GUI routing or to that build. Worth pinning to a released Godot, and the smoke test should then assert a click *did* something rather than that the option parsed. Size S to investigate.

**A specific input device on an event.** `project input apply` writes `"device":-1` (All Devices) on every event; a binding pinned to one joypad index is not expressible. Size S.

**The `[input]` section's formatting is engine-build dependent.** godot-cli writes each event object inline, which matches Godot master's `VariantWriter` and the committed fixture, but the installed 4.8.dev4 writes one property per line, so a save from that editor reformats the whole section and makes a noisy diff. Values round-trip identically either way and Godot parses both. Worth pinning to a released Godot before changing anything. Size S once the target version is decided.

## Docs and site

**The site describes the tool as it was at 0.10.0.** Maintainer. `project run`, presses and clicks, the image result, `scene extract`, and the existing-project workflow exist only in the changelog and the agent docs. The run-and-capture page still teaches four shell commands, the agent-setup page does not say an MCP agent can run the game, and the landing page's "Built for agents" section predates all of it. A "Verify with project run" how-to, a "Refactor an existing project" how-to, and a landing update. Size M.

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
