# Open asks

Everything the agent trials and the maintainers have asked for that is not yet built, as of v0.12.0 (2026-09-04). Trials 9 to 16 built a small 2D slice from an empty folder; trials 17 to 19 modified an existing project. Each item names the trials that asked for it, why it matters, and a size: S is an hour or two, M is a day, L is several days.

Items are grouped by area and ordered by how much they would change what an agent produces. Closed asks are listed at the end so the picture is complete.

## Correctness and validation

**Type-check property values against the node class.** Asked by trials 17, 18, 19. A `visible = Vector2(1, 2)` or `font_size = "big"` passes `scene validate` and runs clean; Godot coerces it and only the frame shows the damage. On an existing project a silently coerced value looks like existing behaviour. Needs a table of common classes and their property types, generated from Godot's class reference XML in the engine checkout for Control, Node2D, and the usual subclasses. Size L. This is the largest remaining gap in "the file is right".

**Warn when a connected signal does not exist on the node type or its script.** Trial 19. A typo in `--signal` validates clean and fails only at run time. Needs the same class table for builtin signals, plus the existing GDScript signal scan for script-declared ones. Size M, and cheap once the class table exists.

**Record child order and unique ids in undo ops.** Trials 18, 19. An undo patch for a removal re-adds the node at the end of its parent and with a fresh unique id, so the restore is not byte for byte. Size S to M.

**Real root type for instanced nodes in `scene node list`.** Trials 11, 12, 17, 18. Instanced nodes report `PackedScene`. Reading the instanced scene's root type needs the project root, which `scene node list` accepts and ignores today. Size S.

**Op index on `invalid_property_value` for patch ops.** Trial 19. Intent steps carry `step`; a patch with several `node_set` ops on `position` does not say which failed. Size S.

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

**Input event and keycode reference for `project input apply`, and an `assign_ext` worked example.** Trial 16. The accepted event types and keycode spellings are only discoverable from the example intent. Size S.

**`manifest_res_path` in `catalog add` output.** Trial 16. Comes back empty with no explanation. Size S.

## `project run`

**Move the mouse away after a click.** Trial 15. The synthetic cursor stays over the clicked node, so the frame shows its hover style and the `normal` style cannot be verified in the same run. Size S.

**A first-and-last frame pair.** Trial 16. `--frame-at` keeps one chosen frame; a before-and-after comparison in one run would want frame 0 as well. Size S.

**A `log-lines` option and a frames upper hint.** Trial 15. The log tail is fixed at 40 lines. Size S.

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
