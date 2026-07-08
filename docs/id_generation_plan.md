# Godot-compatible ID generation and scene I/O plan

## Goal

Build a Zig CLI that can load Godot `.tscn` / `.tres` files, edit them in ways that produce byte-identical or semantically identical output to Godot, and save them back. This is **not** an engine runtime — it is a file-format and project-metadata tool for batch operations, scripting, and LLM/MCP integration.

The first milestone is **ID compatibility**: every identifier Godot writes into scene and resource files must be generatable and parseable the same way.

## What Godot uses (from `../godot/core` and `../godot/scene`)

Godot uses several distinct ID systems. They must not be conflated.

### 1. Resource UIDs (`uid://…`)

**Source:** `core/io/resource_uid.cpp`

| Concern | Detail |
|--------|--------|
| Purpose | Stable project-wide identity for imported resources |
| Text form | `uid://` + base-34-ish alphabet (`a`–`y`, `0`–`8`) |
| Integer form | Signed 63-bit (`& 0x7FFFFFFFFFFFFFFF`) |
| `create_id()` | Crypto-random 63-bit (not yet needed for save round-trip) |
| `create_id_for_path()` | Deterministic: `project_name.hash64() * path.to_lower().hash64() * md5(file).hash64()` → PCG seed → 63-bit ID |
| Cache | `.godot/uid_cache.bin` maps UID ↔ path |

**Compatibility note:** encoding uses an off-by-one alphabet size (GH-83843); we must preserve it.

**Status in this repo:** Implemented in `src/godot/resource_uid.zig`, verified against Godot 4.7 stable.

### 2. Scene-local resource IDs (`ext_resource` / `sub_resource` `id=`)

**Source:** `core/io/resource.cpp`, `scene/resources/resource_format_text.cpp`

| Concern | Detail |
|--------|--------|
| Purpose | References within a single `.tscn` / `.tres` file |
| Format | `{index}_{5chars}` for external refs, `{ClassName}_{5chars}` for sub-resources |
| Generator | `Resource::generate_scene_unique_id()` — 5 chars from PCG |
| Seeding | `Resource::seed_scene_unique_id(p_path.hash())` at save time → deterministic per save path |
| Collision handling | Saver retries until unused |

**Status in this repo:** Implemented in `src/godot/scene_id.zig`. When seeded with `path.hash()` (as Godot does on save), output is deterministic and PCG-compatible.

### 3. Node `unique_id` (scene instances)

**Source:** `scene/resources/packed_scene.cpp`

| Concern | Detail |
|--------|--------|
| Purpose | Stable node identity across scene edits / instantiation |
| Format | Positive `int32` in `[node … unique_id=N]` |
| Generation | `ResourceUID::create_id() & 0x7FFFFFFF`, skip 0, retry on collision |

**Status:** Implemented in `src/godot/node_id.zig` with deterministic seeding for CLI saves; validated in `id_validate.zig`.

### 4. Object IDs / RIDs

Runtime-only (`object_id.h`, `rid.h`). **Out of scope** for file tooling.

## Architecture

```
src/godot/
  hash.zig
  pcg.zig
  resource_uid.zig
  scene_id.zig
  uid_cache.zig
  id_session.zig
  project_config.zig
  id_validate.zig
  text_format/
    tag.zig
    document.zig
    writer.zig
    save_prepare.zig
    godot_format.zig
    roundtrip.zig
    batch.zig
  variant/
    parse.zig
```

`src/io_util.zig` — synchronous file writes (workaround for Zig 0.16 threaded Io EINVAL after write).

CLI commands under `godot-cli uid …`, `godot-cli scene …`, `godot-cli resource …`.

## Phased delivery

### Phase 1 — IDs ✅

- [x] Port hash + PCG primitives
- [x] `ResourceUID` text ↔ integer + `create_id_for_path`
- [x] `generate_scene_unique_id` with explicit seed
- [x] CLI: `uid encode`, `uid decode`, `uid create-for-path`
- [x] CLI: `uid scene-id generate` (seeded sequence)
- [x] Godot reference fixtures in `test_fixtures/`

### Phase 2 — UID cache ✅

- [x] Parse/write `uid_cache.bin` (`ResourceUID::encode_binary_cache` format)
- [x] Resolve `uid://` references using project `.godot/` data
- [x] CLI: `uid cache list`, `uid cache lookup`

### Phase 3 — Text format read path ✅

- [x] Section header parser (`[gd_scene]`, `[ext_resource]`, `[sub_resource]`, `[node]`, `[resource]`)
- [x] Parse `id`, `uid`, `path`, `type` attributes
- [x] Store property lines as raw text (full Variant parsing deferred)
- [x] CLI: `scene inspect`, `resource inspect` (read-only)

### Phase 4 — Text format write path ✅

- [x] Serialize documents back to text (`text_format/writer.zig`)
- [x] Preserve blank lines between sections on round-trip
- [x] `setSectionProperty` — update or append property lines
- [x] CLI: `scene set-property`, `resource set-property`
- [x] Save preparation (`text_format/save_prepare.zig`): seed from path hash, repair ext/sub IDs, remap references
- [x] Sort `ext_resource` sections by id (Godot `ResourceSort`)
- [x] Update `load_steps` when present
- [x] CLI: `scene normalize`, `resource normalize` (and automatic prepare on save unless `--no-prepare-save`)
- [x] Round-trip structure test (`text_format/roundtrip.zig`) + CLI `round-trip`
- [x] Godot reference fixture (`test_fixtures/project/sample_godot_saved.tscn`, `zig build test-godot`)
- [x] Semantic Godot save compare (`documentsMatchGodotSave` — ext id remaps, default sub_resource fields)
- [x] Byte-identical round-trip vs Godot headless save (with `--godot-save-format` + id session cache)
- [x] Ext resource id session cache (`id_session.zig`, `.godot/scene_id_cache.json`)
- [x] CLI: `scene compare-godot`, `resource compare-godot`
- [x] Node `unique_id` assignment on save (`node_id.zig`, `save_prepare.assignNodeUniqueIds`)
- [x] Variant parser: Color, Vector2/3/4, Rect2, NodePath, arrays, dictionaries (`variant/parse.zig`)
- [x] `uid_cache.bin` fixture via `tools/import_fixtures.sh`

### Phase 5 — Batch / integration ✅

- [x] CLI: `scene validate-batch`, `resource validate-batch`
- [x] CLI: `scene retarget-ext`, `resource retarget-ext`
- [x] Options after positionals in argv parser (`scene validate file.tscn --json`)
- [x] Single-threaded Io in CLI main (fixes stdout after file I/O)
- [x] JSON command shapes for MCP (`docs/mcp_tools.json`, examples below)
- [x] Optional: invoke installed Godot headless for validation diffs in CI (`zig build test-godot`)

- [x] Core checks in `id_validate.zig` (uid text, scene ids, duplicates, uid cache)
- [x] Dangling `ExtResource` / `SubResource` reference detection
- [x] CLI: `scene validate`, `resource validate` (exit code 1 on errors, JSON includes `issues`)
- [x] `scene inspect` / `resource inspect` include `issues` by default
- [x] `stale_uid_for_path` (compare file bytes to `create_id_for_path` when `--project-root` given)
- [x] Node `unique_id` validation (range + duplicates)

### Phase 6 — ID integrity detection ✅ core checks

Goal: detect when an LLM or manual edit has left a scene/resource in an invalid or inconsistent ID state.

**Implemented** in `src/godot/id_validate.zig` and exposed via `validate` / `inspect`:

| Check | Kind | Status |
|-------|------|--------|
| `invalid_uid_text` | err | ✅ |
| `uid_not_in_cache` | warning | ✅ |
| `uid_path_mismatch` | err | ✅ |
| `empty_scene_id` / `invalid_scene_id_char` | err | ✅ |
| `unexpected_scene_id_suffix` | warning | ✅ |
| `nonstandard_scene_id` | warning | ✅ |
| `duplicate_scene_id` | err | ✅ |
| `dangling_ext_reference` | err | ✅ |
| `dangling_sub_reference` | err | ✅ |
| `stale_uid_for_path` | warning | ✅ |
| `invalid_node_unique_id` / `duplicate_node_unique_id` | err | ✅ |

**CLI:**

```bash
godot-cli scene validate path/to/main.tscn --project-root .
godot-cli resource validate path/to/material.tres --project-root .
```

`validate` returns exit code `1` when any `err`-severity issue is found (JSON `issues` still emitted).

## Verification strategy

1. **Unit tests** — fixed vectors from Godot 4.7 (`test_fixtures/project/`, `id_reference.gd`).
2. **Round-trip** — parse → modify nothing → save → `diff` against Godot-saved file.
3. **Godot headless** — `/Applications/Godot.app/Contents/MacOS/Godot --headless --path <project> --script …` for reference output when needed.

## CLI reference

```bash
# Resource UID
godot-cli uid encode 1350303725746704497
godot-cli uid decode uid://tidkmw585t0t
godot-cli uid create-for-path --project-name TestProject --resource-path res://test.tscn <file>
godot-cli uid scene-id generate --seed 1290995245 --count 5

# UID cache (requires Godot to have imported the project once)
godot-cli uid cache list --project-root test_fixtures/project
godot-cli uid cache lookup --project-root test_fixtures/project uid://tidkmw585t0t

# Inspect scenes/resources
godot-cli scene inspect path/to/main.tscn --json
godot-cli scene inspect path/to/main.tscn --project-root . --json
godot-cli resource inspect path/to/material.tres --json
```

## References (Godot source)

| File | Relevance |
|------|-----------|
| `core/io/resource_uid.cpp` | UID alphabet, create_id_for_path, uid_cache.bin |
| `core/io/resource.cpp` | generate_scene_unique_id |
| `core/math/random_pcg.h` | PCG wrapper |
| `thirdparty/misc/pcg.cpp` | PCG algorithm |
| `core/string/ustring.cpp` | hash / hash64 |
| `core/templates/hashfuncs.h` | murmur3, djb2 |
| `scene/resources/resource_format_text.cpp` | Save/load text scenes, ID assignment |
| `scene/resources/packed_scene.cpp` | Node unique_id assignment |
| `core/variant/variant_parser.cpp` | Section header parsing |

## Non-goals (for now)

- Running scenes or scripts
- Binary `.scn` / `.res` format (text first)
- Full Variant type system (grow incrementally by property types we need to edit)
- Editor-only metadata unless required for round-trip
