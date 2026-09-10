# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once tagged releases exist.

## How to update

When you merge or land user-facing work, add bullets under **`[Unreleased]`** in the right section (`Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`). On release, rename `[Unreleased]` to a dated version heading and start a new empty `[Unreleased]` section.

Agent/tooling changes that affect LLM workflows belong here too (docs, skills, install, error shapes).

---

## [Unreleased]

## [0.23.3] — 2026-09-10

### Fixed

- **`uid cache list` and `uid cache lookup` answered a damaged cache with the bare word `Corrupt`.** 0.23.2 stopped `scene validate` failing on it, but left the two commands someone reaches for *to diagnose that* saying nothing: no path, no cause, no remedy. They now fail with `uid_cache_unreadable`, naming `.godot/uid_cache.bin` and how to rebuild it. Failing is still right there — the cache is what those commands are about — but the answer has to say which file. Prompted by the reporting session's observation that the original failure named the file you passed, "which is exactly where the problem is not".

## [0.23.2] — 2026-09-10

### Fixed

- **A gap in the ext_resource numbering closed a scene to further additions.** The generated id took the *count* of ext_resources plus one, which is only free while the numbering is dense. Remove `2_abc12` from a file holding `1..4` and every later `scene ext add`, `scene instance add`, `assign_ext` and `instance_add` proposed `4_abc12` — already taken — and failed with `DuplicateResourceId`. Neither `--no-id-session` nor `scene normalize` offered a way back. The id is now allocated past the highest index present and stepped forward until free, in one function both the command and the patch paths call. Reported by another agent's session, which had to abandon a scene node and instantiate from code instead — the exact shape this tool exists to avoid.
- **`scene validate` reported `Corrupt` on scenes that were not corrupt.** The word came from the project's `.godot/uid_cache.bin`, not the file being validated: an unreadable cache failed the whole command with `{"kind": "command_failed", "message": "Corrupt"}` on a `scene validate <file>` call, while `scene describe` and Godot itself read the same scene without complaint. The cache belongs to the project and feeds one check, so an unreadable one now costs `stale_uid_for_path` and says so in `messages`, naming the cache path and how to rebuild it. `catalog validate` already tolerated this; the two paths disagreed.
- An unknown option on a command that has subcommands and no options of its own answered `this command takes ` and stopped. It names the subcommands now. Introduced in 0.22.0 by the message that fixed the previous version of this problem.

### Notes

- `scene normalize` still does not renumber ids to close a gap, and should not. Godot renumbers only as a side effect of rebuilding a file from a live scene tree, where it also discards every resource nothing references — checked against 4.8-dev4, which dropped two unreferenced `ext_resource` lines and renumbered the third. Reproducing half of that would write a file Godot would not have written; reproducing all of it would silently delete resources. Allocating past the highest index removes the need.

## [0.23.1] — 2026-09-10

### Fixed

- **A component with no script read as a component whose script could not be parsed.** `catalog show` reported `exports_source: "gdscript_heuristic"` and `script_parse_complete: false` for a scene carrying no script at all — the same answer a script the parser choked on would give — so a correct empty export list was indistinguishable from a failure to read one. There are three states now: `gdscript_heuristic`/`true` (a script was read), `none`/`true` (there is no script, so nothing to export), and `none`/`false` (a script is named and could not be read, which is the only one worth acting on). Found by another agent's session reasoning around it correctly on a bare `LinkButton` entry.
- `script_parse_complete` meant "a script interface was obtained", not what its name and the documentation said. The heuristic parser's own `parse_complete` was hardcoded true and never read, so no value of the field ever indicated a partial parse; the dead flag is gone and the documented meaning now matches the behaviour.

## [0.23.0] — 2026-09-10

### Added

- **Every manifest field the catalog reads can be written by `catalog add`.** `export_root_script`, `function_docs` and `prefer_over_ids` were read by the schema, surfaced by `catalog validate`, and settable only by hand-editing the manifest — in a tool whose first rule is not to hand-edit. New flags: `--export-doc <property>=<meaning>`, `--function-doc <function>=<meaning>`, `--prefer-over-ids`, `--export-root-script`. Reported by another agent's session with 12 catalogued components, six carrying root scripts with 21 exports between them.
- **`@export` documentation, scaffolded the way signals already were.** `catalog add` leaves a row per export the root script declares, `--export-doc` fills it in, and `catalog show` returns each export's `doc` alongside its name, type and default, with `doc_source` saying whether a person wrote it or it is just what the parser found. The script parse gives a caller the names of what it can set; only a person can say what setting one does. The result also reports `exports_scaffolded` and names the rows still blank, since an undocumented export reads to the next caller exactly like one nobody needed to explain.
- **`unresolved_catalog_reference`**: a `related_ids` or `prefer_over_ids` entry naming no component in the project and no builtin is a warning from `catalog validate` rather than a pointer that silently goes nowhere. Listed in the catalog design doc since the beginning and never implemented.

### Changed

- The validation guide and the skill's reference say plainly what a clean `scene validate` does **not** prove. `unknown_property` skips more than it checks — any node with a script, any instanced node, and every namespaced name — and a partial check that says nothing reads exactly like a complete one that found nothing. Raised by the session the check came from.
- The components guide and the skill cover documenting exports, the four new flags, and what `doc_source` means. `export_root_script` had never been documented anywhere a user would look: it is the script to read exports and signals from when they are not on the root node's own.

## [0.22.0] — 2026-09-09

### Fixed

- **`unknown_option` named neither the option nor the command.** `{"kind": "unknown_option", "message": "unknown option", "details": null}` with an empty `command` was the whole answer, which is close to invisible in a piped `--json` workflow. It now names the flag, the command it was given to, every option that command accepts, and the nearest accepted spelling when there is one — and the envelope's `command` is filled in, which it could not be before because the failure happened before the invocation existed. The same details reach MCP clients, where the envelope is all a client gets. Reported by another agent's session, which lost a scene: a rejected `scene node reparent --to` went unnoticed, and a `scene node remove --recursive` ran next on the subtree the reparent had not moved.
- **A missing required option answered with the bare word `Usage`.** No usage text, no name of the option. Required options are enforced in the parser now rather than in each handler, so every command answers with the missing option, the synopsis `--help` would print, and the full set the command requires.

### Added

- **`scene validate` reports a property the class does not have** — `unknown_property`, the thing Godot keeps in the file and silently ignores, so the setting does nothing and nothing says so. A warning rather than an error, because the class table cannot see everything a property may come from: a node with a script attached or an instanced node is skipped entirely, along with namespaced names (`theme_override_constants/…`, `metadata/…`) and the properties Godot registers as internal. `layout_mode` and `anchors_preset` are in that last group, are written into every scene the editor touches, and are absent from the class reference — an earlier draft of this check called every editor-saved scene broken, which is why the exclusions are there and tested.

## [0.21.0] — 2026-09-09

### Fixed

- **`--frames N` did not mean N frames, so input scheduled late in a run never happened.** Godot paces physics off the wall clock while `--quit-after` counts main-loop iterations, and only `--write-movie` forces the two together — which a windowed run gets and a headless one did not. A 40-frame headless run reached physics frame 18 on the machine this was found on, and fewer on a busier one, so `--click …@20` was silently dropped: `ok: true`, `errors: 0`, `clicks: 1`, and a handler that never ran. `--press move@10..30` was held for 9 frames on one run and 10 on the next instead of 21. The run now passes `--fixed-fps` set to the project's `physics/common/physics_ticks_per_second`, so one iteration is one physics step and one frame means the same thing in both modes, on any machine. Reported from another agent's session against 0.20.1.
- **`--click` works under `--headless` now, rather than being documented as not working.** The headless display server reports no window size, which leaves the root viewport at 64×64 with every `Control` laid out in that corner — so a click computed from a real layout landed outside it. The run puts the project's viewport size back before the first click, and layout and input picking then match a windowed run: a `Button` centred at (960, 540) in a 1920×1080 project is pressed at (960, 540) and its `pressed` signal fires. This makes a button's wiring checkable on a machine with no display. What headless still cannot give you is the frame, which is what the run now says instead.
- The claim that clicks need a window is gone from the `--headless` and `--click` help, the verification guide, the skill's troubleshooting table and the MCP cheat sheet. It was mine, and it was wrong twice over: the 64×64 viewport is fixable, and the guard that was supposed to catch a click landing outside it could not fire, because the frame it was scheduled on was never reached.

## [0.20.1] — 2026-09-09

### Added

- **The documentation caught up with eight releases in a day.** The validation guide lists the checks that arrived with the class table (`property_type_mismatch`, `unknown_signal`, `control_under_node2d`) and the `checks_failed` envelope; the project-settings guide carries the whole input vocabulary — every key, mouse button, joypad button and axis name, the modifier flags, and the per-event device; the batch guide covers `properties` on `node_set`, `unique_id`/`index`, and the id suffix; the instance guide covers connecting to a node inside an instance; the components guide covers `--signal-doc` and the prose now in `catalog list`; the refactor guide covers `--retarget-dropped-connections`, `--editable`, `--import` and `--rename-ids`. The README states the 4.6 minimum and shows the run loop.
- A test that fails if `agent_quickstart.md` stops naming a tool the `--toolset core` list serves, since two lists of the same thing drift.

### Fixed

- **The MCP session prompt told agents something that had stopped being true.** It said two `sub_add` ops of one type need an `id_hint` each or their ids collide — which 0.15.0 fixed by giving a colliding generated id a numbered suffix. It now says `id_hint` is for naming a sub-resource a later op must reference. The prompt also leads with `scene_describe` for discovery and says what `scene_validate` checks.
- **The rules block people paste into `AGENTS.md` never told an agent to run the game.** It finished with `scene validate` and `scene node list`, so an agent following it reported "done" from a file it had never seen drawn. It finishes with `scene validate` and `project run` now, with a click example for proving a button works, and says why that line is the one that changes what an agent delivers.
- The skill and its reference name `scene describe`, the validate checks, `scene extract`, the input map, `project move --import --rename-ids`, the `checks_failed` envelope, and the new failure kinds in its troubleshooting table.

## [0.20.0] — 2026-09-08

### Added

- **`catalog list` carries the prose that tells two components apart** — `when_to_use`, `when_not_to_use` and `notes`, when a manifest has them. Choosing between `ui/health_bar` and `ui/meter` cost a `catalog show` per candidate before. Trial 16.
- **An input event can name a device**: `{"type": "joypad_button", "button": "a", "device": 0}` pins a binding to one joypad, for local multiplayer. The default is Godot's `-1`, All Devices, which is what the editor writes.
- **A stated minimum Godot version: 4.6.** Every `[node]` line godot-cli writes carries the `unique_id` the engine added in 4.6 (`faddd60c40`, first released in 4.6-stable), so earlier 4.x is not supported. Said in the README, the getting-started page, the compatibility guide and the agent basics doc. Trial 10.

### Fixed

- **`manifest_res_path` came back empty under `--project-root .`** — the form the quickstart tells every agent to use. `filesystemToResPath` could not relate two relative paths, and returned nothing. The same function seeds resource id generation, so **a scene authored with a relative project root was seeding its ids from the wrong string**: the same scene now gets the same ids whether the root is spelled `.` or absolutely. Reported as a cosmetic gap by trial 16; it was neither cosmetic nor confined to the catalog.

### Closed without a change

- **The `[input]` section's formatting.** A script's `ProjectSettings.save()` rewrites the section with each event property on its own line, which looked like godot-cli writing the wrong shape. It is Godot's *Dictionary* writer; the engine's object writer is inline, which is what godot-cli produces and what the editor saves, and the two parse identically. Matching the dictionary shape would have moved the output away from the editor's. Explained in the compatibility guide.

## [0.19.0] — 2026-09-08

### Added

- **`--frame-at` is repeatable**, so one run can keep frame 0, a mid-run frame, and the last — a before-and-after pair without running twice. The paths come back in `frames_at`. Trial 16.
- **`--log-lines`** sets how much of the log comes back inline; it was fixed at 40. Trial 15.
- **The `node_set` recipe takes a `properties` object**, like the patch op it expands to. Trial 29 wrote the object form first, as two earlier trials did for the op.
- **Undo patches restore a node where it was, with the id it had.** A removal's undo re-added the node as its parent's last child and let save preparation invent a fresh `unique_id`, so the restore was equivalent but never byte for byte. `node_add` takes `unique_id` and `index` now, and a remove records both: applying the undo of a removed middle child reproduces the file exactly. Trials 18 and 19.

### Fixed

- **A click that cannot reach its target fails the run instead of passing quietly.** The headless display server pins the viewport to 64×64 whatever the project's window size says, and ignores any attempt to resize it, so a click computed from a node laid out beyond that corner reached nothing while the run reported success. The harness now compares the point against the viewport and reports where the node was and how big the viewport is. Clicks *do* work headless within that area — the earlier blanket warning that they never arrive was wrong, and the message, the option help and the site guide all say so accurately now.

## [0.18.0] — 2026-09-08

### Added

- **`scene extract --retarget-dropped-connections`** re-points a connection whose emitter moved at the new scene's root instead of dropping it, and names the method the root now needs. Both existing-project trials did that by hand.
- **`scene extract` takes the catalog prose options** — `--tags`, `--when-to-use`, `--when-not-to-use` beside `--summary` — so the entry a refactor produces is as complete as one written deliberately. Trials 17 and 19.
- **`catalog add --signal-doc <signal>=<what it means>`**, repeatable, fills the rows `catalog add` scaffolds for a root script's signals instead of leaving them blank to edit by hand.
- **`project move --import`** runs Godot's headless import after the move, so its uid cache stops mapping the old path and `scene validate` stops reporting `uid_path_mismatch` — which makes "validate after every edit" hold for a move. Trials 17 and 19.
- **`project move --rename-ids`** re-seeds an `ext_resource` id from the new file name, so a `Script_player` id stops naming a file called `hero.gd`. Ids already in use, and Godot's own `1_ab12c` form, are left alone.

### Fixed

- **`scene set-property` refuses a section header attribute** instead of writing a body line the engine ignores. Setting `path` on an `ext_resource` left the header pointing at the old file and added a meaningless `path = …` line, and the command reported success; trial 28 corrupted a scene that way and hand-edited it back. The failure now names the command that does the job — `scene retarget-ext` or `project move` for a path, `scene node rename` or `reparent` for a node's name or parent.

## [0.17.0] — 2026-09-08

### Added

- **`scene connection add` can connect a node inside an instance**, marking the instance editable the way the editor makes you before you can pick the child, and saying so in `messages`. It used to answer `NodeNotFound`; two trials in a row hand-edited a `.tscn` at exactly that point, which is the failure mode this tool exists to prevent. With `--project-root` the child is checked against the scene it lives in, so a typo fails here rather than silently at run time.
- **`scene extract --editable`** leaves the new instance open, so the connection dropped by the extraction can be re-created immediately instead of removing and re-adding the instance.
- **A scripted node's signals are checked against its script.** The `unknown_signal` check used to skip any node carrying a script, since a script can declare signals of its own; with a project root the script is read and only a signal that is neither builtin nor declared is reported. Without one, scripted nodes stay exempt.
- **`mcp --toolset core`** serves the thirteen tools that cover most sessions instead of all ninety-one, for a client that loads every schema up front. Asked for by trials 10, 12, 14 and 15.
- **`godot-cli://docs/mcp-cheatsheet`**, the surface in tool-and-arguments form: the core thirteen, a session end to end, how to read a result, and the resources worth reading. The quickstart's cheat sheet is shell lines; this one is calls. Trials 15 and 16.

## [0.16.0] — 2026-09-08

### Added

- **`scene describe`**: the tree with every node's properties, connections, external references with whether they resolve, and the scripts attached, in one call. Trial 19 spent seven calls learning one existing scene before it could touch it.
- **`scene node list` and `scene describe` resolve an instanced node to the class it really is** when given `--project-root`, instead of reporting `PackedScene` — the most-cited item in the backlog (trials 11, 12, 17, 18). The node also carries `instance_of: "PackedScene"` and the `res://` path it came from.
- **`scene node remove`, `rename` and `reparent` list the script lines that named the node.** `$HUD/Score`, `get_node("HUD/Score")` and `%Score` all still parse after the change and resolve to nothing; the commands report each file and line now, the way `scene extract` already did. Trials 17 and 18.
- **Two site guides the tool had outgrown.** "Verify a change by running the game" covers the loop `project run` exists for — run, read the frame and the log, click a button to prove its wiring, hold an input action for movement — with the headless and frame-numbering caveats; the older run-and-capture page stays as the by-hand version. "Refactor an existing project" covers `scene extract`, `project move`, rename and reparent, undo patches, and the script references a structural change leaves behind. Every command on both pages was run against a real project before publishing.
- The rules block on the agent-setup page and the skill's checklist name `scene describe` as the discovery step, so an agent reaches for one call instead of five.
- The landing page shows the run loop and the class-table checks, and says an MCP agent can run the game and look at the frame; the agent-setup guide says the same where it explains the server.

### Changed

- **`ok` in the JSON envelope follows the exit code.** A `scene validate` that found errors, or a `project run` whose log held one, used to answer `ok: true` beside `error_count: 2` and exit 1, so an MCP client marked the call an error while the body said it was fine. Those commands report `ok: false` with a `checks_failed` failure carrying the summary now, and keep their `data` so the issues are still there to read. Trial 19; the envelope contract in `development_principles.md` and the scripting guide document the shape.

### Fixed

- **A connection into an instance's child is no longer reported as missing.** A scene with `[editable path="Panel"]` and a connection to `Panel/CloseButton` is what Godot writes and the game runs clean, but `scene validate` called it `connection_node_missing` and failed — a false report on a correct scene, which is the worst kind for a check that gates an agent's work. An endpoint that descends into an instanced node is now left alone, since this document cannot see inside the other scene; a genuinely absent node is still caught. Trial 26.
- `scene connection list` accepts `--project-root` like every sibling read command. The quickstart told agents to pass it and the command rejected it with `unknown_option`.

## [0.15.0] — 2026-09-08

### Added

- **`scene validate` type-checks property values against the node's class.** `visible = Vector2(1, 2)` or `text = 5` used to pass every check and run: Godot coerces the value, the file loads, and only the running frame shows the damage. Asked for by trials 17, 18 and 19, and the largest remaining gap in "the file is right". Property and signal types come from a table generated from Godot's own class reference XML (`tools/gen_class_table.py`, 520 classes, 3933 properties, Godot 4.8.0) and committed, so no engine checkout is needed.
- **A connection to a signal the emitter's class does not emit is an error** (`unknown_signal`) — `pressd` for `pressed` used to cost a whole run to find. Trial 19.
- Both checks are conservative by construction: a class or property the table does not carry (`theme_override_*`, `metadata/*`, a script's exported variables), a value that does not parse, and a connection from a scripted node are all left alone. Verified against every scene the trials have produced — 38 of them — with no false report.
- The validator's `control_under_node2d` warning now knows every Control and Node2D class rather than the fifty each its hand-written lists named.

### Changed

- **A generated `sub_resource` id steps aside instead of colliding.** The id is seeded from the scene path and the resource type, so a second `sub_add` of one type in a scene produced the same id and failed `DuplicateResourceId`. It now takes a numbered suffix (`StyleBoxFlat_ab12c_2`), which Godot preserves through a save. Three trials in a row hit this; the last one hand-edited the `.tscn` to get past it, which is the one thing the tool exists to prevent. An `id_hint` you chose yourself still fails when it collides — that name is yours, so a clash is worth hearing about.
- **`node_set` takes a `properties` object**, like `node_add`, instead of one property and value per op; `scene set-property` likewise takes `--properties` and repeatable `--property`/`--value`. Two trials and the maintainer each wrote the object form first and had it rejected.
- **`node_add` takes `unique_name`**, the field its `add_node` recipe already took. It used to be dropped silently, and since 0.13.0 was rejected outright.

## [0.14.0] — 2026-09-08

### Fixed

- **A `--click` under `--headless` now says it verified nothing.** There is no window, so the click never reaches the Control: the run reported `clicks: 1` and exited clean while the button was never pressed — a passing result for the one flag whose job is verification. It comes back with a message saying so. `--press` does work headless (measured: both the polled action state and the `InputEventAction` arrive).
- **`project run --press` / `--click` failed on any project with an autoload.** The generated harness loaded the scene from `_init()`, which Godot runs while it instantiates the custom main loop — before it registers autoload names as script globals (`main.cpp` sets the main loop, loads autoloads, then calls initialize). Any script naming an autoload failed to *compile*, so the scene never loaded and the run died before the game started, while a plain `project run` was fine. The harness loads from `_initialize()` now, which runs after that startup step and keeps press and click frames on the same numbers as before. Reported by a session hitting it on the first button it tried to click; autoloads are near-universal, so in practice these flags only worked on toy projects.
- **The input map could not express half of Godot's controller.** `joypad_button` named 8 of the 26 `JoyButton` values — no shoulders, no stick clicks, no start/back/guide, no paddles — and `joypad_motion` named 4 of the 6 axes, leaving both triggers out. All of them have names now (`left_stick`/`l3`, `right_shoulder`/`rb`, `trigger_left`/`LT`, …), matched without case, and `button` accepts a raw `JoyButton` number the way `axis` already did.
- **Mouse buttons could not be bound at all.** `project input apply` knew `key`, `joypad_button` and `joypad_motion`; Godot's own action map editor also takes `InputEventMouseButton`, so "fire on the left mouse button" had no expression. There is a `mouse_button` event now — `left`, `right`, `middle`, `wheel_up`/`wheel_down`/`wheel_left`/`wheel_right`, `xbutton1`/`xbutton2`, or a number — with the same modifier flags, written with the property shape Godot's own `var_to_str` produces. An unrecognised `type` now lists the four.
- **`key` events reached only letters, digits, space and the arrows.** Escape, Enter, Tab, Backspace, Delete, Home, End, the page keys, the lock keys and F1-F12 now have names, a raw Godot keycode is accepted, and `"ctrl"`, `"shift"`, `"alt"` and `"meta"` on the event write the modifier flags, so `ui_cancel` on Escape and Ctrl+S are expressible. Verified by reading the written map back through Godot: `Escape`, `Enter`, `Ctrl+S`, `F12`, `Tab`, `Left Stick`, `Left Trigger`, `Right Shoulder`.
- **A whole `axis_value` is written `-1.0`, not `-1`.** Godot's `VariantWriter` appends `.0` to a whole float, so every joypad binding godot-cli wrote differed from what the editor writes on the next save.
- An unknown key, joypad button or joypad axis now fails with the field, the value, and every name it accepts, instead of a bare `UnknownJoypadButton`. `project input apply --help` carries the same reference (asked for by trial 16).

## [0.13.0] — 2026-09-07

### Added

- **A field an op or recipe does not take is rejected** instead of dropped, naming the field, the fields the op accepts, and the op's index. Trial 20 wrote `"id"` where `ext_add` takes `id_hint`; the id was ignored, and the `node_set` that referenced it wrote a dangling `ExtResource("MyStyle")`. The recipe table `scene recipes` prints is what intent steps are checked against, so it now lists every field the expanders read — `connect` takes `deferred`, `one_shot`, `binds` and `unbinds`, `catalog_button` takes `label_text`, `child`, `child_type` and `type`, `player_2d` takes `sprite_texture`, `texture_path` and `shape_id_hint`, `static_body_2d` takes `shape_id_hint`, `assign_ext` takes `type` and `resource_path`, and `instance_override` takes `type`.
- **A colliding generated resource id names `id_hint`.** Two `sub_add` ops of one type in a patch get the same generated id and the second failed with the id alone; the failure now says the id comes from the type and the scene and that an `id_hint` on each fixes it. Trial 20 abandoned inline sub-resources over this and wrote four `.tres` files instead.
- Every patch op failure carries `details.step`, the index of the op that failed, the way intent steps already did (asked by trial 19 for `invalid_property_value`).

### Changed

- **`project run --click` moves the cursor off the node after the release**, so the last frame shows the clicked node in its normal style instead of its hover style. Trial 15 could not verify a button's `normal` styling in the same run that clicked it. `--keep-cursor` restores the old behaviour when the hover style is what you want to see. Only the game's own cursor moves — a synthetic `InputEventMouseMotion` through `Input.parse_input_event`; nothing warps the desktop pointer.

## [0.12.0] — 2026-09-04

### Added

- **`scene extract <scene> <node> --output <new.tscn>`**: the editor's Save Branch as Scene. The subtree moves with its properties, unique ids, the resources it uses, and the connections inside it, rewritten relative to the new root; the source gets an instance in its place; `--catalog-id` registers the new scene. Connections that cross the boundary are dropped and listed. Trial 17 rebuilt a HUD by hand from inspected JSON, transcribing 23 properties, because nothing did this.
- `scene node get` returns the node's parsed properties; the trial had to inspect the whole file to learn what was on one node.
- `scene extract --catalog-id` registers the entry after both scenes are written and reports a catalog problem in messages rather than failing a command that did its work (trial 18 hit `ManifestNotFound` after the writes). It also lists the lines of scripts that reach into the moved subtree by path, and reports `written`.
- Patch ops accept the recipe names as aliases (`add_node`, `connect`, `instance_catalog`, `instance_scene`, `instance_set`), and an unknown op names itself and lists the ops. `node_set` and `instance_override` steps take a JSON number or boolean as `value`. `invalid_intent`, `invalid_patch`, `unknown_patch_op`, and `catalog_manifest` failures carry details.
- `scene validate` warns `control_under_node2d` when a known Control class sits directly under a Node2D, the "runs fine, draws nothing" case both existing-project trials lost a run to.
- `project run --frame-at N` keeps that frame as well as the last, for a mid-run state such as a menu open.
- The undo op for `node_reparent` addresses the node at its new path; an automatic snapshot is removed when the apply is rejected before writing.

### Fixed

- **Undo patches for a recursive `node remove` held freed memory.** The property names in the recorded `node_add` ops pointed into the section text that the removal then freed, so the undo file held garbage keys, and a removed instance was recorded as a typeless node. The Debug guard caught it in trial 17. Keys are copied and instances are recorded as `instance_add` now.
- `scene diff --properties` is a flag, but the MCP schema typed it as an object because its name matched the `properties` option elsewhere; flags are never JSON-typed now.
- `project move --dry-run` reports the sidecars a real move would carry, and a real move says that `uid_cache.bin` is stale until the next import.
- The basics doc says why a Control under a Node2D draws nothing, and `project run` says a passing run can still show a wrong layout.

## [0.11.0] — 2026-09-03

### Added

- Intent failures name the step: `missing_field` and `invalid_property_value` details carry `step` (the index in `steps`), the `recipe`, and the `field`, so a bad entry in a long intent is found without bisecting. `assign_ext` infers `ext_type` from the extension (`.gd`, `.tscn`, images, audio, fonts) as its description claimed; a `.tres` still needs it. `camera_2d` takes `position`. The `file` alias on `project * apply` is hidden from the MCP schemas, and path descriptions drop the `res://` boilerplate.
- **`project run --click <node path>@<frame>`** left-clicks the centre of a Control or Node2D on a physics frame and releases on the next, so a Button's `pressed` signal fires without test code in the game. Presses are sent as real `InputEventAction`s as well as polled state, so a focused Control sees `ui_accept`. The capture folder defaults to `.godot/godot-cli`, which Godot never imports and projects already ignore, so a run leaves nothing in the tree.
- **`stale_uid_for_path` compared scene and resource references against a hash of the file**, which a header uid never matches; it compares against the header now. A reference to a scene or `.tres` without a `uid=` gains the one from the target's header, as the editor writes; script and asset references are left as Godot's own save writes them.
- **`project run --press <action>@<first>..<last>`** holds an input action over a range of physics frames, through a generated SceneTree script that loads the scene, so movement and buttons can be exercised and seen in the frame without a hand-written test path. The result also carries the last 40 log lines, and over MCP the frame comes back as an image block, so a client with no file access sees what the game drew. The default resolution is the project's window size.
- **New scenes and resources get a header uid.** `scene new` and `resource new` stamp `uid="uid://..."` the way the editor does (`--no-uid` skips it), so `catalog add` fills `scene_uid` at once and PackedScene references carry the uid; the editor no longer rewrites the header on first save. The `catalog add` message about an empty uid said to run the import, which cannot help; it says what does now.
- Options a command cannot run without are marked required: help and the reference say so, and the MCP schemas list them in `required`, so a client validates before the call is made.
- JSON integers for float properties (`offset_*`, `anchor_*`, `rotation`, `radius`, and other names the editor always writes as floats) are written as `8.0`, matching editor output; the recipes and tool descriptions say why.
- Trial 13 fixes: `scene validate` reports `resource` for a `.tres`; the inline intent and patch options carry a worked example; `assign_ext` documents its `ext_type` values; `static_body_2d` says its size is centred on position; the server instructions name the ten core tools and the prompt's resource fallback; the quickstart has an "Over MCP" section.
- **`project run`**: the verify loop as one command. It creates the `.gdignore`d capture folder, runs the headless import, runs the main scene or `--scene` for `--frames` frames with `--write-movie`, keeps only the last frame (and drops the `.wav`), and returns the frame path, the log path, and every `ERROR` or `SCRIPT ERROR` line with its backtrace. It exits 1 when Godot did not exit cleanly or the log holds an error. `--headless` gives the log alone, `--user-arg` passes flags to `OS.get_cmdline_user_args()`, and the binary comes from `--godot`, `$GODOT`, `PATH`, or the macOS app bundle. Over MCP it is `project_run`, which is the step an agent without a shell could not do; both MCP trials had to borrow Bash for it. `project import` runs the import pass alone.

## [0.10.0] — 2026-09-03

### Added

- `scene plan` and `scene apply` describe the intent and patch shapes and list every recipe in their help text, and `project apply` describes its sections, so an agent reading the MCP tool description does not need the 37 KB guide to learn a recipe's fields. An unknown recipe now fails as `unknown_recipe` with the known names in the details.
- A `properties` object on instances: the `instance_add` patch op, the `instance_catalog` and `instance_scene` recipes, and `scene instance add --properties`. Positioning an instanced widget was eight `node_set` steps in the MCP trial.
- The session prompt is also the resource `godot-cli://prompts/session`, because several clients hide prompts.
- `project show` reports the absolute `project_root`, and the server instructions and quickstart say that the MCP server has no `project-root` argument and why.

### Changed

- Options that take a whole number (`project new --width` and `--height`, `scene connection add --unbinds`, `set-property --section-line`) are declared as integers: the parser rejects anything else and the MCP schema says `integer`.
- `invalid_property_value` names the property that failed rather than `value`, so a multi-property object points at the right entry.
- The quickstart's "Read next" table gives each document's MCP resource URI.
- **`scene recipes`** lists every intent recipe with its required and optional fields, from the same table the expander uses; the MCP server serves it as `godot-cli://docs/recipes`, under 2 KB. Trial 12 read the 37 KB guide for exactly this.
- **`static_body_2d` takes `color`** and adds a filled `Polygon2D` the size of the collision box. Trial 12's walls were collision-only, and with the camera under the player, movement was invisible; the basics doc now says why.
- `project new` writes Godot's default `icon.svg` beside `project.godot` unless one exists (`--no-icon` skips it), since the examples reference `res://icon.svg`.
- `project show` reports the window size and stretch settings.
- The MCP tool schemas leave out the save-preparation and id-session plumbing (`id-session`, `no-id-session`, `godot-save-format`, `normalize-properties`, `no-prepare-save`, `resource-path`) unless the server is started with `--all-options`; the CLI still accepts them everywhere.
- Each `project <section> apply` describes its own intent shape instead of the shared one; `docs/mcp_tools.json` is served as `godot-cli://docs/mcp-tools`; `scene node list` reports instanced nodes as `PackedScene` rather than an empty type; `catalog add` says when `scene_uid` is empty and what to run; the five tool descriptions that still said `--project-root` no longer do; and `set-property` no longer contradicts itself about normalisation.

## [0.9.0] — 2026-09-03

### Added

- **`project new --name`**: creates `project.godot` in an empty folder with the project manager's header, `config_version=5`, and the name, plus `--main-scene`, `--width`, and `--height`. Both agent trials that started from nothing had to hand-write the file, which the rules forbid, because nothing created it. It refuses to overwrite an existing file.
- **Inline JSON for every intent and patch option.** `scene plan` and `scene apply` take `--intent-json` and `--patch-json`; every `project * apply` takes `--intent-json`. An agent working through MCP no longer needs a second tool to write a file into the project first, and the MCP schemas declare these as objects so the model sends JSON rather than a string of JSON.
- **`--properties` on `scene node add`, `resource new`, and `sub add`**: one JSON object instead of parallel `--property` and `--value` lists that have to stay index-aligned. Strings are Variant text, numbers and booleans are formatted. The lists still work and the two can be combined.

### Fixed

- **Results borrowed from a freed invocation through `batch` and the MCP server.** `App.invoke` freed the parsed invocation before the result was serialised, so `scene set-property` returned its property name and value as freed bytes when called as a tool or a batch step. The invocation now lives as long as the arena every caller already provides, and the Debug invalid-UTF-8 guard runs on the server path too.
- The `add_node` recipe dropped `unique_name: true` when the step also carried `properties`, so `%Name` lookups crashed at run time on a scene that validated clean. The two are merged now; the shipped `hud_top_bar.json` combined them.
- The scene-authoring guide claimed strings in `properties` objects are quoted automatically, and `hud_top_bar.json` relied on it; the tool has always required the quotes. The guide and the example match the tool, and `zig build test` plans the example against a scene.
- A missing `project.godot` or intent file failed with a bare `Io` and no path. Both name the path and, for the project file, say to run `project new`.
- The quickstart's `--project-root` table had a paragraph inserted mid-table, which broke its last row.

## [0.8.0] — 2026-09-03

### Added

- **`godot-cli mcp`: a native Model Context Protocol server over stdio.** Every runnable command is a tool, named as `docs/mcp_tools.json` names them, with an input schema generated from the command's options and positional arguments. A call runs in-process and returns the `--json` envelope as text and as structured content, so a failure still carries its details. `--project-root` pins the server to one project: the option is injected into every call, removed from the schemas, and any path argument that resolves outside the project is refused before the command runs. The agent docs and example intents ship inside the binary as `godot-cli://docs/...` and `godot-cli://examples/...` resources, `godot-cli://catalog` is the pinned project's live catalog, and the `godot-scene-session` prompt opens a session with the skill's rules. The server answers both the `initialize` handshake current clients send and the stateless 2026-07-28 revision. A pipe smoke test in `zig build test` exercises both openings.
- Commands declare their positional arguments. `--help` lists them under "Arguments", the man page and the Markdown reference render them, and `reference --format json` carries `positionals` (and now marks `repeatable` options). Before this, the reference knew about options only and an agent had to guess that `scene node remove` takes a file and a node path.

### Fixed

- Seventeen handlers returned their message list as a pointer to a stack temporary (`&.{text}`), which the CLI path survived by luck and the MCP server's Linux build did not. The lists are allocated now.

### Changed

- The mapping from a handler error to a failure envelope, with the duplicate-id, missing-file, node, and patch-field details, is one function shared by the CLI, `batch`, and the MCP server, so every entry point reports the same thing.
- CI runs the Godot round-trip suite as a matrix: 4.7 and 4.7.2 must pass, and the newest 4.8 prerelease (dev4) is reported without blocking. The site and README stop saying newer versions "may work".

## [0.7.1] — 2026-09-03

### Changed

- **The agent quickstart is one page again.** It had grown to 278 lines covering basics, resources, connections, captures, and file moves, and the 2D trial's agent reported its tooling truncating the file mid-read. It now holds the rules, the workflow, a cheat sheet, the capture recipe, and a table of what to read next. The Godot basics and the full capture recipe live in a new `agent_godot_basics.md`; resources, file moves, repeated properties, the follow-ups table, the command examples, and the anti-patterns moved into `agent_scene_authoring.md`. The skill is cut to the same shape. Release archives and `install.sh` ship the new file.

### Added

- Debug builds check every result for invalid UTF-8 before printing it and report `internal_invalid_output` instead. Three bugs today serialised freed memory as JSON strings, each found by an agent reading garbage; the test suite runs Debug builds, so the next one fails a smoke test.

## [0.7.0] — 2026-09-03

### Added

- **`project move --from --to`**: rename or move a file with its `.uid` and `.import` sidecars and repoint everything that referenced it, across every scene and resource in the project, catalog manifests, and `project.godot` settings such as the main scene and autoloads. The refactor trial did this as `mv`, a `grep`, and `scene retarget-ext` per file; it is one command now.
- `scene set-property --section-id <id>` targets an `ext_resource` or `sub_resource` by id, where `--section sub_resource` only ever found the first one.
- `set-property --node` on a path inside an instanced scene fails with `node_not_found` and a hint naming the instance and the `instance_override` op with `child` that reaches it; it returned a bare `Usage`.

### Fixed

- `scene node rename` and `scene node reparent` showed `node add`'s option table in `--help`, the reference, and the completions, and never stated their positional form. Each has its own options and an example in its description.

## [0.6.0] — 2026-09-03

### Added

- `catalog relink` finds a moved scene beside its manifest when there is no `scene_uid` to resolve, which is every scene godot-cli created and Godot has not re-saved, and rewrites the `ext_resource` paths inside the relinked scene that moved with it. A folder move is now one `catalog relink`. Found by the catalog trial, where the documented command could not repair a move at all.
- `catalog export` keeps whatever is in the output file outside the digest: the digest sits between `<!-- godot-cli catalog: begin -->` and `end` markers, replaced in place, so the hand-written rules above it in `AGENTS.md` survive a re-export. A file from before the markers is replaced from its `# Component Catalog` heading.
- `catalog add` takes a project-relative scene path as well as `res://`.
- Templates worth copying: `3d/static_body` ships a `BoxShape3D` and `BoxMesh`, `2d/character_body` a `CapsuleShape2D`, instead of empty collision and mesh nodes.
- Quickstart lists the common `project.godot` keys and the `project apply` sections.

### Fixed

- **`scene validate` inside `batch` reported its path as sixteen bytes of freed memory.** Handlers may return strings borrowed from the step's argv, which the batch runner frees when the step ends; step results are now deep-copied.
- **`scene template show --json` serialised freed memory** for section names and fields, the same class of bug.
- `project input apply` bound a physical Space (and the arrow keys) with both `keycode` and `physical_keycode` set; Godot writes `keycode=0` for a physical binding, and now so does godot-cli.
- `project.godot` sections are written in name order, as `ProjectSettings::_save_settings_text` iterates them, so a section added by `project apply` no longer moves on the editor's next save.
- The `validate` message for `uid_path_mismatch` says the uid cache is stale after a move and how to refresh it.
- The `assign_ext` example in the agent guide showed an id shape the op never produces.

## [0.5.0] — 2026-09-03

### Added

- **Resource authoring.** `resource new --output x.tres --type <Class>` with repeated `--property`/`--value`, `resource sub add|remove`, and `resource ext add|remove`, alongside the existing `resource set-property`, which now targets the `[resource]` section when no target is given (its help said so; it returned a usage error). A material and a shape created this way are byte-identical to Godot's own saves; a theme with a `StyleBoxFlat` sub-resource matches semantically (sub-resource ids are seeded per file). Fixtures saved by Godot 4.8 under `test_fixtures/project/resources/`.
- Intent recipe `static_body_2d`: a `StaticBody2D` with a `RectangleShape2D` collision of `size` and, with `texture`, a `Sprite2D` tiled across it. The 2D trial built its ground from raw patch ops because no recipe covered it.
- `failure.details` on a write that fails names the output path (`{"field": "output", "value": "scenes/main.tscn"}`); it used to be a bare `FileNotFound`.

### Fixed

- `scene new` and `resource new` create a missing parent directory instead of failing.
- A sub-resource added to a `.tres` with no other resources was appended after the `[resource]` section, where Godot does not look for it. Resources now go before the body in both scenes and resource files.
- `project.godot` came back with the blank lines in the wrong places after any `project` edit: three before the first section, none after a header. The writer now lays the file out the way `ProjectSettings::_save_settings_text` does, and a file Godot saved is byte-identical after a settings edit.
- The capture recipe's five frames were too few to see gravity or a following camera act; the recipe and rules text use sixty, one second at 60 FPS.

## [0.4.1] — 2026-09-02

### Added

- `scene node add` and `scene sub add` take `--property`/`--value` more than once, so a Control's anchors go on in one command instead of five. Options declared `repeatable` accumulate in argv order; `Invocation.getOptionAll` reads them.
- Saving with `--project-root` repairs an `ext_resource` `uid=` that disagrees with the project, the situation after copying a component folder in from another project, where Godot warned `invalid UID` on every load until the editor re-saved the scene.

- "Godot project and scene basics" in the agent quickstart and the skill: what a project folder is and why a scene outside it cannot resolve `res://`, one root node per scene, that `anchors_preset` is an editor label and runtime layout needs `anchor_*` and `grow_*` (with the full-rect, centred, and top-left recipes), which containers stack children and which hold one, and the import pass after adding files. Written after two agent trials made the same layout mistake.

### Fixed

- **`scene validate` reported `stale_uid_for_path` after any edit to a script or scene.** It recomputed the UID from the file's current bytes, but Godot assigns a UID once (into a `.gd.uid` sidecar for scripts, into the header for scenes) and keeps it through edits. Scripts are now checked against the sidecar when one exists, scenes against the project's `uid_cache.bin`, and the recomputation is used only for a file Godot has not imported yet. UID lookup for `ext add` and `assign_ext` reads the sidecar first for the same reason.
- The capture recipe wrote frames into the project root, where Godot imported every PNG as a texture on the next run and left a `shot.wav` and a pile of `.import` files behind. The guide, the quickstart, the skill, and the rules text now write into a `capture/` folder holding a `.gdignore`, which Godot skips.

## [0.4.0] — 2026-09-02

### Added

- **Signal connections.** `scene connection list|add|remove` read and write the `[connection signal="pressed" from="Menu/Resume" to="Menu" method="_on_resume_pressed"]` sections the editor's Node dock writes, with `--deferred`, `--one-shot`, `--binds`, and `--unbinds` for Godot's connect flags. Patch ops `connection_add` and `connection_remove`, intent recipe `connect`, undo patches for both, `scene node get` lists a node's connections, and `scene diff` reports added and removed ones. Renaming or reparenting a node rewrites the `from` and `to` paths of its connections; removing a node removes them, as the editor does. This was the one request in the agent trial with no scene-level answer, so the agent connected the button in `_ready()`.
- `scene node list` and `scene node get` report `instance` (the `ext_resource` id) and `instance_path` (its `res://` path) for instanced nodes, which used to show an empty `type`.
- `scene validate` error `connection_node_missing` when a connection's `from` or `to` names a node that is not in the scene.
- Fixture `test_fixtures/project/ui/menu/menu_godot_saved.tscn`, saved by Godot with plain, deferred-with-binds, and one-shot-with-unbinds connections; a smoke test rewrites it byte for byte.

### Fixed

- **Scalar floats were written without the trailing `.0`.** Godot writes `offset_left = 16.0` and `rotation = 1.0` for float properties and drops the `.0` only inside constructors (`Vector2(2, 1.5)`); godot-cli wrote `16` in both places. Verified against a Godot 4.8 save: a scene with both values rewritten by godot-cli is now byte-identical. The site had been stating the wrong rule as a feature.
- **Any scene with signal connections lost byte-exactness on every edit.** The header parser read an unquoted array such as `binds= ["quit"]` as a string and wrote it back quoted (`binds="[\"quit\"]"`), an array containing a space failed to parse the whole file, and the writer put a blank line between connections where Godot writes none. Unquoted header values are kept verbatim, bracketed values are read to their closing bracket, and consecutive connections stay contiguous.

## [0.3.0] — 2026-09-02

### Added

- **`failure.details` for patch and intent errors.** A bare word given as a property value (`"text": "Paused"`) now fails with `invalid_property_value` and details naming the op, the field, the value, and the quoted form to use; it used to be written verbatim as `text = Paused`, which Godot cannot load. A missing required field fails with `missing_field` and the op and field in details instead of a bare `MissingPatchField`. `set-property`, `node add --property`, and `sub add --property` apply the same check unless `--raw-value` is passed.
- `scene set-property --node <viewport path>`, alongside `--node-name`, so it targets nodes the same way every other scene command does.
- The `assign_ext` patch op accepts `ext_type` and the intent recipe accepts `type`, so either spelling works in both places.
- How-to guide [run the game and capture a screenshot and the log](https://unabated-games.github.io/godot-cli/how-to/run-and-capture/), and the same recipe in the agent quickstart and the skill: `--write-movie`, `--quit-after`, and `--log-file` do the whole job, and an import pass after adding files stops the `invalid UID` warning.

- **Documentation site** at [unabated-games.github.io/godot-cli](https://unabated-games.github.io/godot-cli/): an overview, a getting-started guide, and ten how-to guides covering scene authoring, the component catalog, instancing and overrides, batch edits, UI, project settings, review and validation, agent setup, Godot compatibility, and scripting.
- `site/` holds the content and templates; `tools/build_site.py` renders it and fails the build on a broken internal link. The reference page is `docs/commands.md`, regenerated by `zig build docs` during the deploy so the published reference matches the code on `main`.
- `.github/workflows/pages.yml` builds the site on every pull request and deploys it from `main`.

### Fixed

- `scene inspect --json` emitted bare `inf`, `inf_neg`, or `nan` for non-finite floats, which is not JSON. They are emitted as strings using Godot's spellings.
- `scene validate` warned `nonstandard_scene_id` for every id produced by `id_hint` (`Script_pause_menu`, `Texture2D_icon`), so a patch that used the documented feature could never validate clean. Ids of the form `Prefix_name` are accepted; Godot loads any id string and only the editor's generated ids carry the five-character suffix.
- `scene node remove` listed `scene node add`'s options in `--help` and the completions (`--parent`, `--name`, `--type`, ...). It has its own option set now, and `ext remove` and `sub remove` say what their positional argument is.
- The generated Markdown reference escaped nothing, so an option description containing a placeholder such as `<scene>.manifest.json` was read as an HTML tag by Markdown renderers and broke the surrounding table.
- `install.sh` could put a whole URL where the version belonged. When the releases API is unavailable it falls back to the redirect target of the `/latest` page, but it accepted that URL as a tag even when the redirect never reached a tag page — a private repository redirects to a login page — producing a download path with a URL embedded in it. The redirect is now only trusted when it landed on `/releases/tag/`, and the resolved version has to look like one; failing that, the error explains the private-repository case. `tools/test_install_sh.sh` covers both sources failing, lying, and answering, and runs in CI.

## [0.2.0] — 2026-08-28

### Added

- **`godot-cli completions bash|zsh|fish`**, **`godot-cli man`**, and **`godot-cli reference`** — the shell completions, the `godot-cli(1)` man page, and the Markdown command reference are all generated from the same `CommandSpec` tree the parser walks and `--help` prints, so a new command cannot be missing from them.
- `docs/commands.md` — generated reference for every command, option, and exit code.
- `share/completions/` (bash, zsh, fish) and `share/man/man1/godot-cli.1`, both committed and packaged in release archives.
- `zig build docs` regenerates all of the above; `zig build docs-check` fails when the committed copies have drifted, and runs in CI.
- `-Dversion-date` build option — release date of the embedded version, shown in the man page header. Set from a constant rather than the clock so generated output stays byte-stable.
- **`install.sh --from-release`** — installs a published binary instead of building, so godot-cli no longer requires a Zig toolchain. Resolves the latest version (or `--version X.Y.Z`), picks the archive for the running platform, **verifies it against the release `SHA256SUMS` and refuses to install on a mismatch**, and unpacks it into the same prefix layout as a source install. Outside a checkout — piped from `curl` — this is the default mode.
- `install.sh` installs the shell completions and man page, and `env.sh` now sets `MANPATH` and loads completions for the running shell.
- Release archives ship `share/completions/`, `share/man/`, `docs/commands.md`, and `install.sh`, and mirror the repository layout so the installer stages from a release and a checkout identically.
- Releases build for **aarch64 Windows** as well; CI cross-compiles every target a release ships, including `aarch64-linux-musl`.
- Release notes are composed from the CHANGELOG section for the tag (`tools/changelog_section.sh`) plus install and verification instructions, and releases publish directly instead of waiting as a draft.
- Release archives carry a **build provenance attestation** (`gh attestation verify`).
- CI job `generated docs and completions`: `zig build docs-check`, `mandoc -Tlint` on the man page, a parse check of the completions in bash, zsh, and fish, and `shellcheck` over `install.sh` and `tools/*.sh`.
- **`godot-cli reference --format json`** — the whole command surface (every command, option, value kind, and default) as one JSON document, for tools that wrap the CLI.
- `tools/check_mcp_tools.sh` — fails when a runnable command is missing from `docs/mcp_tools.json`, or when the catalog's version does not match the binary's. Runs in CI.
- 13 commands the tool catalog had never listed: `scene template show`, `resource compare-godot`, `catalog add`, `catalog relink`, `project settings set|validate`, `project autoload validate`, `project plugins disable|validate`, `project rendering list|validate`, `project physics list|validate`.

### Fixed

- **`scene sub add --property` wrote freed memory into the scene.** The normalized value was released at the end of the block that produced it, before the document copied it in, so `--value 16.0` could land in the file as `radius = \xfa\xfa`. A smoke test now checks written property text in the file rather than in the command's own output.
- **A write could report failure after succeeding.** With `--project-root` pointing at a project that had never been opened in Godot — no `.godot/` directory — commands wrote the scene and then exited 1 trying to save the id session cache beside it. The directory is created when missing, and a cache that still cannot be written is dropped rather than failing an edit that already landed.
- `scene new` declared `--output` twice — once as required, once inherited from the shared save options. It showed up twice in help and in every completion script. A test now rejects any command that declares an option or subcommand twice.
- `catalog relink --dry-run` was described as generating markdown, which is `catalog export`'s behaviour.
- `catalog scan` still described itself as scanning `.tres` manifests, which 0.1.0 removed.
- Option help lines align in a column again; padding was applied to the value placeholder rather than the whole label, so every description started at a different offset.
- `LICENSE` is the unmodified MIT text again, so GitHub detects the licence. The third-party notice it used to carry lives in `THIRDPARTY.md`, which the README and every release archive already point at.

### Changed

- **README is a landing page**, with the command list moved to the generated reference. New [`docs/getting_started.md`](docs/getting_started.md) covers install, a first scene, `--project-root`, and agent setup; [`docs/README.md`](docs/README.md) indexes every document.
- [`RELEASING.md`](RELEASING.md) documents cutting a release; `.editorconfig`, `.gitattributes` (generated files marked, Godot fixtures never normalised), Dependabot for GitHub Actions, and `CODEOWNERS` added.
- Agent quickstart and catalog design updated: the installer no longer needs a checkout, and the catalog docs no longer describe the `.tres` manifests 0.1.0 removed.
- Global options (`--json`, `--request`, …) are declared once in `cli/spec.zig` and rendered from there by `--help`, the man page, the reference, and every completion script.

## [0.1.0] — 2026-08-14

First public release, under the MIT License.

### Added

- **Catalog manifests are `*.manifest.json`** (`catalog_format_version` 2) — plain data, identified by filename, needing nothing installed in the Godot project to read or write. An agent can author one directly.
- **`catalog add`** — create or update a manifest for a scene. Derives `id` from the scene path, fills `scene_uid` from the scene's `[gd_scene]` header, and scaffolds one row per signal declared by the root script, reusing the GDScript parser behind `catalog show`. `--update` preserves prose already written, drops rows for signals that no longer exist, and adds blank rows for new ones; without it an existing manifest is never overwritten.
- **`catalog relink`** — repoint manifests whose scene has moved. `scene` is a plain path string and Godot does not rewrite it on a move, since its dependency tracking follows `ext_resource` and `uid://` references rather than arbitrary string properties. `scene_uid` survives, so relink resolves it through `.godot/uid_cache.bin` and rewrites the path, preserving `id` and prose. It works from the manifest outward, so it also repairs a manifest that did not travel with its scene. A stale uid cache — a `git mv` with the editor closed — is reported as `unresolved` rather than guessed at. Exits 1 if any manifest is still unrepaired.
- MIT `LICENSE`, `THIRDPARTY.md` recording the Godot Engine (MIT) and PCG (Apache-2.0) code this project ports, and the Apache-2.0 text at `third_party/licenses/`.
- `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue and pull request templates.
- CI runs on push and pull request across Linux and macOS, checks formatting, and cross-compiles every supported target. Release workflow builds tagged binaries for Linux (musl), macOS, and Windows on x86_64 and aarch64.
- `scene validate` error `node_parent_order` when a node's `parent=` refers to a node declared later in the file.
- Fixture `test_fixtures/project/bad_node_order.tscn` and smoke tests for validate + normalize.
- Agent docs: **UI authoring (editor parity)** — scene-first Control styling, `@tool` export pattern, unique names, HUD layout, quoted patch strings (`agent_quickstart.md`, `agent_scene_authoring.md`, skill).
- Example intent `hud_top_bar.json` (top bar with ColorRect, MarginContainer, theme overrides, unique name).
- `--unique-name` flag on `scene node add` and `scene instance add` (sets `unique_name_in_owner`).
- Intent `add_node` recipe: optional `"unique_name": true`.
- `install.sh` — local install to `~/.godot-cli` (binary, templates, docs, examples, `env.sh`); `--install-skill` for Cursor, Claude Code, OpenCode, and `~/.agents/skills/`.
- Agent docs: `docs/agent_quickstart.md`, `docs/agent_scene_authoring.md`, `docs/agent_batch_commands.md`.
- Skill package: `skills/godot-scene-authoring/` (symlinked from `.cursor/skills/`).
- Share examples: `share/examples/intents/` and `share/examples/patches/` (e.g. `player_with_icon.json`).
- Scene authoring pipeline: `scene plan`, `scene apply`, patch JSON ops, `scene diff`, undo/snapshot restore.
- Intent recipes: `player_2d`, `camera_2d`, `ui_panel`, `tilemap_layer`, `audio_player`, `instance_catalog`, `catalog_button`, `assign_ext`, `instance_override`, `node_set`, `add_node`.
- Patch op `assign_ext` — get-or-add `ext_resource` by `res://` path and set a node property in one step (reuses existing ids).
- `resource_uid_lookup` — resolve `uid://` for `ext_resource` from `.import`, uid cache, or `create_id_for_path`.
- Component catalog commands and design (`docs/catalog_design.md`).
- `batch` command for chained apply → validate → diff workflows.
- **`project input`** — read/write Input Map actions in `project.godot` (`list`, `apply`, `validate`); idempotent per-action replace via intent JSON (keys, joypad buttons/motion).
- **`project settings`** — scalar sections (`application`, `display`, `layer_names`, …): `list`, `get`, `set`, `apply`, `validate` (checks `res://` paths).
- **`project autoload`** — autoload singletons: `list`, `apply` (merge by name; optional `replace_all`), `validate`.
- **`project plugins`** — editor plugin enable/disable: `list`, `enable`, `disable`, `apply`, `validate` (no install).
- **`project rendering`** — rendering method and platform drivers via friendly aliases (`method`, `driver_windows`, …).
- **`project physics`** — physics engine and gravity via friendly aliases (`engine_3d`, `gravity_3d`, …).
- **`project show`** — summarize project name, main scene, input/autoload/plugin counts, rendering and physics backends.
- **`project apply`** — unified intent JSON applying any combination of `input`, `settings`, `autoload`, `plugins`, `rendering`, `physics` sections in one write.
- Example intents: `wasd_movement.json`, `main_scene.json`, `display_stretch.json`, `physics_layers.json`, `autoload_game_state.json`, `enable_sample_plugin.json`, `rendering_forward_plus.json`, `physics_jolt.json`, `project_bootstrap.json`.
- `project_godot` parser/writer for INI-style sections and brace multiline values (Input Map blocks).
- Validation error `resource_section_order` when `ext_resource` appears after `sub_resource`.
- `DuplicateResourceId` / `DuplicateExtPath` failure `details` in JSON output (`id`, `path`, `section_name`, `existing_line`, …).

### Changed

- `--project-root` accepted on `scene node list`, `scene node get`, and `scene diff` (optional; ignored for file-only reads). Required for writes, catalog, and validation that touches project paths.
- `player_2d` recipe: per-node collision shape ids (`{name}_shape` → `CapsuleShape2D_{name}_shape`); optional `shape_id_hint`, `position`, `modulate`, `script`, and shared texture via path dedup.
- `ext_add` patch op and CLI `scene ext add`: reuse existing `ext_resource` when `res://` path already registered (no error).
- `ext_resource` / `sub_resource` insertion and save preparation enforce Godot section order (`ext_resource` before `sub_resource`).
- `assign_ext` intent recipe emits `assign_ext` patch op instead of separate `ext_add` + `node_set`.
- `id_hint` on ext resources uses `{Type}_{hint}` (e.g. `Texture2D_icon`) so intent references match patch ids.

### Fixed

- `catalog validate` reported garbage `code` and `message` strings for an entry's existing issues whenever a duplicate `id` or `scene` was also found. `pushIssue` shallow-copied the issue list and then freed the strings the copies pointed at, so the worst output landed in exactly the case you most need it readable.
- **Output written to a redirected file could overwrite the target from byte 0.** stdout and stderr writers were constructed in positional mode, so `godot-cli … > out` and `>> out` wrote at the writer's own offset instead of the file offset owned by the shell — clobbering earlier content and previous invocations. Piped and terminal output were unaffected.
- **The project did not compile for Linux or Windows.** Template root resolution called `std.c.getenv` without libc linked, which is a hard compile error on every non-macOS target. Environment access now goes through `std.process.Environ`, and CI cross-compiles all supported targets to keep it that way.
- `Invocation.deinit` did not free parsed positionals or option values, and a repeated option stranded the value it displaced. Harmless under the CLI's arena, a leak for anything embedding the `godot_cli_tools` module.
- `moveSubtreeAfterReparent` leaked its section list, and could double-free sections on a mid-transfer failure.
- `applyCopyMutations` discarded the owned path returned by `renameNode`.
- `zig build test` now passes; it previously failed the whole step on 25 leaked allocations despite every test passing.
- `scene set-property` and `scene node add --property` wrote garbage for bool values (e.g. `unique_name_in_owner = true`) due to use-after-free when formatting Variant text.
- `node_add` / `node_reparent` could leave `[node]` sections in child-before-parent file order (Godot instantiate: “parent path has vanished”). Save preparation and `scene normalize` now topologically sort node sections; reparent moves the subtree block under the new parent.
- Godot parse failure when applying texture after `player_2d` (`Unknown tag 'ext_resource'`) caused by `ext_resource` sections appended after `sub_resource`.
- `player_2d` could not be used twice in one scene (`DuplicateResourceId` on `CapsuleShape2D_shape`).
- Second `player_2d` with `texture` failed when `res://icon.svg` was already an `ext_resource` (now deduped via `assign_ext`).
- `scene validate` did not catch invalid ext/sub section order.

### Removed

- **Resource-backed (`.tres`) catalog manifests.** They carried a `script_class` and pinned the defining GDScript by path as an `ext_resource`, so a project could not open its own manifests unless that script was installed at exactly that path — a dependency godot-cli itself never had, since it parses the file as text. Manifests are JSON only.
- The manifest `uid` field, which existed so an editor could stamp one and which nothing consumed. `id` is the identity and is already uniqueness-checked.
- `catalog scan` no longer reports `tres_files_scanned`; `manifest_files_found` covers it. `scanProject` and `searchCatalog` no longer take a uid cache, since only the `.tres` path used one.
