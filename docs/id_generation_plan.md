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

**Status:** Documented; validate when parsing node sections (Phase 6).

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
  id_validate.zig
  text_format/
    tag.zig
    document.zig
```

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

### Phase 3 — Text format read path ✅ (headers + validation)

- [x] Section header parser (`[gd_scene]`, `[ext_resource]`, `[sub_resource]`, `[node]`, `[resource]`)
- [x] Parse `id`, `uid`, `path`, `type` attributes
- [x] Store property lines as raw text (full Variant parsing deferred)
- [x] CLI: `scene inspect`, `resource inspect` (read-only)
- [x] Basic ID validation in inspect output (`issues` array)

### Phase 4 — Text format write path

- [ ] Round-trip AST → text with Godot ordering conventions
- [ ] Reuse cached ext/sub IDs when present (`set_id_for_path` behaviour)
- [ ] Assign new IDs only when needed (match `resource_format_text.cpp` save logic)
- [ ] CLI: `scene set-property`, `resource set-property`

### Phase 5 — Batch / integration

- [ ] JSON command shapes for MCP (already defined in `docs/development_principles.md`)
- [ ] Multi-file operations (bulk rename, retarget ext_resource paths)
- [ ] Optional: invoke installed Godot headless for validation diffs

### Phase 6 — ID integrity detection (planned)

Goal: detect when an LLM or manual edit has left a scene/resource in an invalid or inconsistent ID state.

**Checks to implement** (building on `src/godot/id_validate.zig`):

| Check | Kind | Description |
|-------|------|-------------|
| `invalid_uid_text` | error | `uid://` string does not decode |
| `uid_not_in_cache` | warning | UID not in `.godot/uid_cache.bin` (when `--project-root` given) |
| `uid_path_mismatch` | error | `ext_resource` uid/path disagree with cache |
| `empty_scene_id` / `invalid_scene_id_char` | error | Malformed `id=` attribute |
| `unexpected_scene_id_suffix` | warning | Suffix not from `generate_scene_unique_id` alphabet |
| `nonstandard_scene_id` | warning | Legacy or hand-edited id format |
| `duplicate_scene_id` | error | Same `id=` used twice in one file |
| `dangling_ext_reference` | error | `ExtResource("…")` in properties with no matching `ext_resource` |
| `dangling_sub_reference` | error | `SubResource("…")` with no matching `sub_resource` |
| `stale_uid_for_path` | warning | File bytes imply a different `create_id_for_path` than declared uid |

**CLI (planned):**

```bash
godot-cli scene validate path/to/main.tscn --project-root .
godot-cli resource validate path/to/material.tres --project-root .
```

`scene inspect` / `resource inspect` already include an `issues` array when validation is enabled (default). A dedicated `validate` command would exit non-zero on errors for CI/MCP.

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
