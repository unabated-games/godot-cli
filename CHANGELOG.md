# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once tagged releases exist.

## How to update

When you merge or land user-facing work, add bullets under **`[Unreleased]`** in the right section (`Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`). On release, rename `[Unreleased]` to a dated version heading and start a new empty `[Unreleased]` section.

Agent/tooling changes that affect LLM workflows belong here too (docs, skills, install, error shapes).

---

## [Unreleased]

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
