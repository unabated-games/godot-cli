# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once tagged releases exist.

## How to update

When you merge or land user-facing work, add bullets under **`[Unreleased]`** in the right section (`Added`, `Changed`, `Fixed`, `Removed`, `Deprecated`). On release, rename `[Unreleased]` to a dated version heading and start a new empty `[Unreleased]` section.

Agent/tooling changes that affect LLM workflows belong here too (docs, skills, install, error shapes).

---

## [Unreleased]

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

### Fixed

- `LICENSE` is the unmodified MIT text again, so GitHub detects the licence. The third-party notice it used to carry lives in `THIRDPARTY.md`, which the README and every release archive already point at.

### Changed

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
