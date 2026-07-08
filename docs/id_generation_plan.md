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

**Status in this repo:** Implemented in `src/godot/scene_id.zig`. When seeded with `path.hash()` (as Godot does on save), output is deterministic and PCG-compatible. Unseeded Godot editor runs use a time-based seed and will differ.

### 3. Node `unique_id` (scene instances)

**Source:** `scene/resources/packed_scene.cpp`

| Concern | Detail |
|--------|--------|
| Purpose | Stable node identity across scene edits / instantiation |
| Format | Positive `int32` in `[node … unique_id=N]` |
| Generation | `ResourceUID::create_id() & 0x7FFFFFFF`, skip 0, retry on collision |

**Status:** Documented; implement when parsing/saving node sections.

### 4. Object IDs / RIDs

Runtime-only (`object_id.h`, `rid.h`). **Out of scope** for file tooling.

## Architecture (target)

```
src/godot/
  hash.zig           # String::hash / hash64, murmur3 helpers
  pcg.zig              # RandomPCG / PCG32
  resource_uid.zig     # uid:// encode/decode, create_id_for_path
  scene_id.zig         # generate_scene_unique_id, ext/sub id formatting
  uid_cache.zig        # (planned) read/write .godot/uid_cache.bin
  text_format/
    lexer.zig          # (planned) [section] headers, key=value lines
    parser.zig         # (planned) build AST from .tscn/.tres
    writer.zig         # (planned) serialize AST → Godot-compatible text
    variant.zig        # (planned) subset of Variant literal syntax
```

CLI commands grow under `godot-cli uid …` and `godot-cli scene …` / `resource …`.

## Phased delivery

### Phase 1 — IDs (current)

- [x] Port hash + PCG primitives
- [x] `ResourceUID` text ↔ integer + `create_id_for_path`
- [x] `generate_scene_unique_id` with explicit seed
- [x] CLI: `uid encode`, `uid decode`, `uid create-for-path`
- [x] CLI: `uid scene-id generate` (seeded sequence)
- [x] Godot reference fixtures in `test_fixtures/`

### Phase 2 — UID cache

- [ ] Parse/write `uid_cache.bin` (`ResourceUID::encode_binary_cache` format)
- [ ] Resolve `uid://` references using project `.godot/` data
- [ ] CLI: `uid cache list`, `uid cache lookup`

### Phase 3 — Text format read path

- [ ] Lexer for Godot text resources (`[gd_scene]`, `[ext_resource]`, `[sub_resource]`, `[node]`, `[resource]`)
- [ ] Parse `id`, `uid`, `path`, `type` attributes
- [ ] Parse property lines into a typed or raw representation
- [ ] CLI: `scene inspect`, `resource inspect` (read-only)

### Phase 4 — Text format write path

- [ ] Round-trip AST → text with Godot ordering conventions
- [ ] Reuse cached ext/sub IDs when present (`set_id_for_path` behaviour)
- [ ] Assign new IDs only when needed (match `resource_format_text.cpp` save logic)
- [ ] CLI: `scene set-property`, `resource set-property`

### Phase 5 — Batch / integration

- [ ] JSON command shapes for MCP (already defined in `docs/development_principles.md`)
- [ ] Multi-file operations (bulk rename, retarget ext_resource paths)
- [ ] Optional: invoke installed Godot headless for validation diffs

## Verification strategy

1. **Unit tests** — fixed vectors from Godot 4.7 (`test_fixtures/project/`, `id_reference.gd`).
2. **Round-trip** — parse → modify nothing → save → `diff` against Godot-saved file.
3. **Godot headless** — `/Applications/Godot.app/Contents/MacOS/Godot --headless --path <project> --script …` for reference output when needed.

## CLI (phase 1)

```bash
# Resource UID
godot-cli uid encode 1350303725746704497
godot-cli uid decode uid://tidkmw585t0t
godot-cli uid create-for-path --project-name TestProject --resource-path res://test.tscn <file>

# Scene-local 5-char IDs (deterministic with --seed)
godot-cli uid scene-id generate --seed 1290995245 --count 5
```

## References (Godot source)

| File | Relevance |
|------|-----------|
| `core/io/resource_uid.cpp` | UID alphabet, create_id_for_path |
| `core/io/resource.cpp` | generate_scene_unique_id |
| `core/math/random_pcg.h` | PCG wrapper |
| `thirdparty/misc/pcg.cpp` | PCG algorithm |
| `core/string/ustring.cpp` | hash / hash64 |
| `core/templates/hashfuncs.h` | murmur3, djb2 |
| `scene/resources/resource_format_text.cpp` | Save/load text scenes, ID assignment |
| `scene/resources/packed_scene.cpp` | Node unique_id assignment |

## Non-goals (for now)

- Running scenes or scripts
- Binary `.scn` / `.res` format (text first)
- Full Variant type system (grow incrementally by property types we need to edit)
- Editor-only metadata unless required for round-trip
