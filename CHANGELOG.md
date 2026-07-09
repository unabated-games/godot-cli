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
- Example intents: `wasd_movement.json`, `main_scene.json`, `display_stretch.json`, `physics_layers.json`, `autoload_game_state.json`, `enable_sample_plugin.json`, `rendering_forward_plus.json`.
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

- Godot parse failure when applying texture after `player_2d` (`Unknown tag 'ext_resource'`) caused by `ext_resource` sections appended after `sub_resource`.
- `player_2d` could not be used twice in one scene (`DuplicateResourceId` on `CapsuleShape2D_shape`).
- Second `player_2d` with `texture` failed when `res://icon.svg` was already an `ext_resource` (now deduped via `assign_ext`).
- `scene validate` did not catch invalid ext/sub section order.
