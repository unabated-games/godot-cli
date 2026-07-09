# Mini roadmap (post Phase 6)

Context: Phases 1–6 in [id_generation_plan.md](id_generation_plan.md) are complete. The Variant type system lives under `src/godot/variant/` and is wired into `scene set-property`, `resource set-property`, `inspect` (JSON), and `normalize --normalize-properties`.

This roadmap is ordered by priority for MCP/LLM agent use. Implement one item at a time; each should ship with tests and CLI JSON output.

**Godot source of truth for Variant text:** `core/variant/variant_parser.cpp` — line map in `src/godot/variant/godot_ref.zig`.

## Progress (2026-07-08)

| # | Item | Status | Key paths |
|---|------|--------|-----------|
| 1 | Rich `inspect` | **done** | `src/godot/variant/property_line.zig`, `scene inspect` |
| 2 | Node tree commands | **done** | `src/godot/node_tree.zig`, `scene node list/get` |
| 3 | Property normalization on save | **done** | `src/godot/text_format/normalize_properties.zig`, `--normalize-properties` |
| 4 | Variant gaps | **done** | `src/godot/variant/collection.zig`, arrays/dicts/typed/packed byte |
| 5 | Fixture and CI hardening | **done** | `test_fixtures/project/rich_variants.tscn`, `.github/workflows/ci.yml` |
| 6 | Thin MCP server | **deferred** | CLI-first; see [scene_authoring_roadmap.md](scene_authoring_roadmap.md) |
| 7 | Scene authoring (LLM) | **done** | Phases A–H in [scene_authoring_roadmap.md](scene_authoring_roadmap.md) |
| 8 | Batch CLI + Phase I polish | **done** | [agent_batch_commands.md](agent_batch_commands.md), `godot-cli batch` |

**Start next session at scene authoring Phase I extensions** or MCP if needed ([roadmap](scene_authoring_roadmap.md)).

---

## 1. Rich `inspect` (start here) — **done**

### Problem

`scene inspect` and `resource inspect` return section headers and `property_count`, but not property names or values. Agents must read raw file text elsewhere to understand file contents.

### Goal

Expose parsed properties in inspect JSON, using the existing Variant parser.

### Suggested JSON shape

```json
{
  "sections": [
    {
      "line": 10,
      "name": "node",
      "fields": { "name": "Player", "type": "CharacterBody3D" },
      "property_count": 2,
      "properties": [
        {
          "line": 11,
          "name": "visible",
          "kind": "bool",
          "raw": "visible = true",
          "value": true
        },
        {
          "line": 12,
          "name": "script",
          "kind": "ext_resource",
          "raw": "script = ExtResource(\"1_abc\")",
          "value": "1_abc"
        }
      ]
    }
  ]
}
```

Use snake_case. Include `kind` from `variant.Kind`. For complex kinds (`object`, `array`, `dictionary`, `raw`), prefer `raw` text plus `kind`; add structured `value` only when cheap.

### Implementation notes

- Touch: `src/commands/scene.zig` (`inspectHandler`), possibly a small helper in `src/godot/variant/` (e.g. `property_line.zig`) to split `name = value` and call `parsePropertyValue`.
- Reuse `text_format/document.zig` `PropertyLine.raw`; do not change the document model unless needed.
- Options:
  - `--parse-properties` (default on when `--json`?) **or**
  - always parse in JSON mode; keep human output summary-only.
  - `--no-parse-properties` to skip parsing (faster, for huge files).
- On parse failure: emit `kind: "raw"`, `parse_error: true`, keep `raw` — do not fail the whole inspect.
- Update `docs/mcp_tools.json` inspect tool description.
- Tests: unit test for property-line split + parse; CLI test with `--json` on `test_fixtures/project/sample.tscn`.

### Done when

- `godot-cli scene inspect sample.tscn --json` includes `properties` per section with `name`, `kind`, and typed `value` where applicable.
- Existing inspect behaviour (issues, section list) unchanged.
- `zig build test` passes.

---

## 2. Node tree commands — **done**

### Problem

No way to list nodes or resolve paths without mentally parsing `[node]` sections.

### Goal

```bash
godot-cli scene node list path/to/main.tscn --json
godot-cli scene node get path/to/main.tscn /root/Player --json
```

### Suggested JSON (`node list`)

```json
{
  "path": "main.tscn",
  "nodes": [
    {
      "name": "Player",
      "type": "CharacterBody2D",
      "parent": ".",
      "path": "/root/Player",
      "section_line": 8,
      "unique_id": 1290995245
    }
  ]
}
```

### Implementation notes

- New module: `src/godot/node_tree.zig` (or under `text_format/`) — walk `Document` sections where `header.name == "node"`.
- Build paths from `parent` attribute: `"."` = section's local name under root; `"Parent/Child"` style as in Godot saves.
- `node get`: filter by path or by `--node-name` + optional parent.
- Register commands in `src/commands.zig` under `scene` → `node` → `list` / `get`.
- Follow [development_principles.md](development_principles.md) (handler returns `Result`, `--json` envelope).
- Tests: `test_fixtures/project/sample.tscn` — expect Root + Collision nodes.

### Done when

- List and get work with `--json` and human-readable messages.
- Documented in `docs/mcp_tools.json`.

---

## 3. Property normalization on save — **done**

### Problem

`set-property` normalizes a single value via Variant parse → format, but `normalize` / save-prep leaves existing property lines verbatim. Float formatting, alias canonicalization (`Quat` → `Quaternion`), etc. are inconsistent across the file.

### Goal

Optional pass that rewrites every property value through `parsePropertyValue` → `formatForWrite`, preserving property names and section structure.

### CLI

```bash
godot-cli scene normalize main.tscn --normalize-properties
godot-cli resource normalize mat.tres --normalize-properties
```

Or fold into existing `--godot-save-format` if that matches semantics — decide in implementation (prefer explicit flag first).

### Implementation notes

- Touch: `text_format/save_prepare.zig` or new `text_format/normalize_properties.zig`.
- For each `PropertyLine`, split key/value, parse, format, replace `raw` as `key = formatted` (use existing `document.setSectionProperty` pattern).
- Skip or preserve on parse error (`--raw-value` behaviour per property: keep original line).
- Must not break `zig build test-godot` byte-identical compare unless normalization is explicitly requested.
- Tests: round-trip parse → normalize-properties → compare known float/color rewrites.

### Done when

- Flag works on scene and resource normalize.
- Godot round-trip test still passes **without** the flag.
- With flag, known normalizations are tested (e.g. `Vector2(1.0, 2.0)` → Godot float style).

---

## 4. Variant gaps (incremental) — **done**

Still validated or shell-typed only; not structurally parsed:

| Form | Current | Next step |
|------|---------|-----------|
| `[1, 2, Vector3(...)]` | `.array`, raw preserved | Parse elements via `lex.extractValueSlice`, store `[]Value` or normalize on write |
| `{ "a": 1 }` | `.dictionary`, raw preserved | Key/value pairs like `Object()` body parsing |
| `Array[int]([...])` | `.typed_array` | Parse inner array elements |
| `Dictionary[K, V]({...})` | `.typed_dictionary` | Parse inner dict |
| `PackedByteArray("base64...")` | `.packed_array`, raw | Recognize base64 string arg per `variant_parser.cpp` `_parse_byte_array` (~L601) |

Add entries to `constructors.zig` / `kind.zig` as needed. Cross-check `godot_ref.zig` line numbers.

### Done when

Each form has parse + format tests derived from Godot-saved fixture strings.

---

## 5. Fixture and CI hardening — **done**

### Goal

- Richer fixtures from Godot headless save: `Object()`, typed arrays, gradients, `.tres` with colors.
- CI job running `zig build test` and optionally `zig build test-godot` with `-Dgodot=...` on Linux.

### Implementation notes

- Extend `test_fixtures/project/` and `tools/import_fixtures.sh`.
- Add GitHub Actions workflow (or document local CI command) if not present.
- `test-godot` requires Godot binary; make path configurable.

### Done when

- At least one new fixture covering `Object(...)` property on a sub_resource or resource.
- CI runs unit tests on push; Godot test documented or gated.

### Shipped

- `test_fixtures/project/rich_variants.tscn` — `Object(Gradient, ...)`, typed/plain arrays and dicts, `PackedByteArray`, `Color`, sub_resource `Gradient` with packed arrays.
- `test_fixtures/project/sample_material.tres` — `StandardMaterial3D` with color properties.
- `tools/save_rich_fixtures.gd` + `REGENERATE_RICH=1 tools/import_fixtures.sh` for partial Godot regeneration.
- `src/godot/fixtures.zig` — parse tests against committed fixtures.
- `.github/workflows/ci.yml` — manual `workflow_dispatch` only (`zig build test` + `test-godot` jobs).

---

## 6. Thin MCP server (optional) — **deferred**

CLI + `--json` / `--request` is sufficient for agents; revisit only if a client requires MCP registration. See [ABOUT.md](ABOUT.md).

---

## 7. Scene authoring (LLM-first) — **done**

Full plan: **[scene_authoring_roadmap.md](scene_authoring_roadmap.md)** (Phases A–I)

Batch workflows: **[agent_batch_commands.md](agent_batch_commands.md)**

---

## 8. Batch CLI (multi-step agent workflows) — **done**

`godot-cli batch --file workflow.json` runs multiple subcommands in one invocation with `stop` / `continue` / `atomic` failure modes. See [agent_batch_commands.md](agent_batch_commands.md).

---

## Session checklist (copy per item)

- [ ] Read relevant Godot source (`godot_ref.zig` pointers)
- [ ] Implement with tests
- [ ] `zig build test` (and `test-godot` if touching save format)
- [ ] Update `docs/mcp_tools.json` if CLI surface changes
- [ ] Tick item in this doc or move to id_generation_plan when fully done

---

## References

| Doc / path | Purpose |
|------------|---------|
| [id_generation_plan.md](id_generation_plan.md) | Completed phases 1–6 |
| [development_principles.md](development_principles.md) | CLI/JSON contracts |
| [ABOUT.md](ABOUT.md) | Project overview |
| [scene_authoring_roadmap.md](scene_authoring_roadmap.md) | LLM scene authoring plan |
| [mcp_tools.json](mcp_tools.json) | JSON request shapes for every command |
| `src/godot/variant/` | Variant parse/format |
| `src/godot/text_format/document.zig` | Scene document model |
| `src/commands/scene.zig` | Inspect, set-property, normalize handlers |
