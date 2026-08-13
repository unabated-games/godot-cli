# Scene authoring roadmap (LLM-first)

**Goal:** Let LLMs fully author Godot scenes — nodes, parenting, sub-resources, instanced scenes — without editing raw `.tscn` text or falling back to “create everything in GDScript at runtime.”

**Context:** [ABOUT.md](ABOUT.md) describes what godot-cli is today. Phases 1–6 (IDs, parse/write, inspect, variants) are done. This roadmap is the next major capability gap.

---

## The problem

LLMs are bad at Godot scene authoring for predictable reasons:

| Failure mode | Why it happens |
|--------------|----------------|
| Broken parenting | `parent="."` vs `parent="Root"` vs `parent="Root/Arm"` is implicit, not path-based |
| Orphan / duplicate nodes | Adding a `[node]` section without updating sibling `parent` attrs |
| Wrong section order | Godot expects `gd_scene` → ext/sub resources → nodes; `load_steps` must match |
| ID collisions | New ext/sub-resource IDs and `unique_id` must be unique and Godot-shaped |
| Instancing mistakes | PackedScene needs `ext_resource` + `instance=ExtResource(...)` + often overridden children |
| “Just use a script” workaround | `_ready()` spawns children because the model cannot reason about the file tree |
| Property syntax | Variant text is easy to get subtly wrong even when structure is right |

**Today godot-cli can create and restructure scenes** via tree commands (`scene node add`, `scene instance add`, ext/sub resources). Agents should use those instead of editing raw TSCN or spawning nodes in `_ready()`.

---

## Design principles

1. **Editor scenes, not runtime spawning.** Persist nodes, instances, and properties in `.tscn` the way a human would in the Godot editor. Use `scene node add` / `scene instance add` — not `load().instantiate()` in GDScript — for static UI and level structure. See [ABOUT.md — North star](ABOUT.md#north-star-editor-like-scene-authoring).
2. **Tree operations, not text edits.** Agents call `scene node add`, not “insert these lines after line 42.”
3. **Every mutation validates.** Return structured errors (duplicate name, unknown parent, invalid type) before write.
4. **Godot save path on write.** All mutations go through existing `save_prepare` (IDs, `load_steps`, ordering).
5. **JSON in, JSON out.** Batch ops via `--request` / patch documents; human argv for shell use.
6. **Catalog over imagination.** Project manifests and builtins tell agents *which* PackedScene to instance and when — not ad-hoc `load()` paths.
7. **Inspect before and after.** `node list`, `inspect`, and `validate` are the agent feedback loop.

---

## Architecture (build on what exists)

```
src/godot/
  node_tree.zig          # read: list, paths, find  →  extend: mutate, validate tree invariants
  text_format/
    document.zig         # add: insertSection, removeSection, moveSection
    scene_edit.zig       # NEW: add/remove/reparent/rename node; add ext/sub resources
    save_prepare.zig     # already: IDs, load_steps, godot format
  scene_templates/       # NEW: built-in + project template catalog
```

**Parent attribute model** (Godot on-disk, not viewport paths):

- Scene root: no `parent` field
- Direct child of root: `parent="."` (or sometimes root name — normalize on save)
- Deeper nodes: `parent="Ancestor/..."` relative to scene root name

`node_tree` already resolves viewport paths (`/root/Root/Player`). Mutations accept **viewport paths** and translate to Godot `parent` attrs, including rewriting descendant `parent` attrs on reparent/rename.

---

## Phased plan

Implement one phase at a time; each ships with tests, fixtures, and `mcp_tools.json` entries.

### Phase A — Document mutations (foundation) — **done**

**Deliverables:**

- `insertSection` / `removeSection` / `appendSection` in `document.zig`
- `section_index` on `NodeInfo` for reliable in-memory edits (not just `section_line`)

---

### Phase B — Core node CRUD — **done**

**Commands:**

```bash
godot-cli scene new --output main.tscn --root-type Node2D --root-name Main
godot-cli scene node add main.tscn --parent /root/Main --name Player --type CharacterBody2D
godot-cli scene node remove main.tscn /root/Main/Player
godot-cli scene node rename main.tscn /root/Main/Player --name Hero
godot-cli scene node reparent main.tscn /root/Main/Hero/Sprite --parent /root/Main
godot-cli scene refs main.tscn --project-root .
```

**Project context (lightweight, not full walk):** `scene refs --project-root` resolves `ext_resource` `res://` paths to filesystem paths and reports `exists`. Enough for agents editing one scene to validate script/PackedScene paths without indexing the whole project. Full project walk deferred until instancing/templates need it.

**Implementation:** `src/godot/scene_edit.zig`, `src/godot/scene_refs.zig`

---

### Phase C — Resources in scenes (sub_resource + ext_resource) — **done**

**Commands:**

```bash
godot-cli scene ext add main.tscn --type Script --path res://player.gd
godot-cli scene sub add main.tscn --type RectangleShape2D --property size --value "Vector2(16, 32)"
godot-cli scene ext remove main.tscn 1_abc12
godot-cli scene sub remove main.tscn RectangleShape2D_abc12
godot-cli scene node add main.tscn --parent /root/Main/Player --name Collision \
  --type CollisionShape2D --property shape --value 'SubResource("RectangleShape2D_abc12")'
```

**Implementation:** `src/godot/scene_resources.zig`

---

### Phase D — PackedScene instancing — **done**

**Problem:** LLMs constantly confuse `instance`, `instance=ExtResource`, and child overrides — or fall back to `load().instantiate()` in scripts.

**Commands:**

```bash
godot-cli scene instance add main.tscn --parent /root/Main \
  --scene res://enemies/slime.tscn --name Slime
godot-cli scene instance add main.tscn --parent /root/Main --scene res://ui/hud.tscn \
  --name HUD --editable
godot-cli scene instance add main.tscn --parent /root/Main \
  --catalog-id ui/button --name MyButton --project-root .
```

**Behaviour:**

- Add `ext_resource type="PackedScene" path="..." id="N_xxxx"`
- Add node with `instance=ExtResource("N_xxxx")` and correct `parent`
- Optional `--editable` adds `[editable path="..."]` (Godot 4.x save format)
- `--catalog-id` resolves scene path from project catalog manifests (not builtins)

**Implementation:** `src/godot/scene_instance.zig`

**Fixtures:** `test_fixtures/project/instanced_child.tscn`, `instanced_child_godot_saved.tscn`

---

### Phase E — Component catalog (replaces simple template folder)

**Design:** [catalog_design.md](catalog_design.md)

**Problem:** LLMs need project semantics (which button, which player ship, when to use builtins) — not just TSCN syntax. Cold-start skeletons are a subset of this.

**Authoring:** `godot-cli catalog add` writes a `*.manifest.json` beside the scene — see [catalog design](catalog_design.md).

**Consumption:** `godot-cli catalog scan|list|show|validate|search|export` + builtin JSON (`godot/ui/Button`, document-only).

---

### Phase E (legacy note) — Scene templates (built-in patterns)

Superseded by the component catalog for project entries. Builtin **document-only** Godot entries replace shipping `.tscn` template files into user projects.

**Problem:** Cold-start authoring is hardest. Templates give LLMs a correct skeleton to modify.

**Layout:**

```
templates/
  2d/
    character_body.tscn      # CharacterBody2D + CollisionShape2D + Sprite2D placeholders
    top_down_player.tscn
  3d/
    static_body.tscn
    character_body_3d.tscn
  ui/
    control_root.tscn        # Control + MarginContainer + VBox
```

**Commands:**

```bash
godot-cli scene template list --json
godot-cli scene template show 2d/character_body --json
godot-cli scene template copy 2d/character_body --output player.tscn \
  --rename-node Player:Hero --set-property /root/Player/Collision/shape=...
```

**Behaviour:**

- Templates ship inside repo (or `share/godot-cli/templates` after install)
- `template show` returns node tree + section summary (like inspect)
- `template copy` copies file, optional rename/map properties, runs save_prepare

**Done when:** Agent can `template copy` → `node add` → `validate` without reading raw TSCN.

---

### Phase F — Declarative patch (batch authoring) — **done**

**Problem:** Ten sequential CLI calls are slow and brittle for agents.

**Command:**

```bash
godot-cli scene apply main.tscn --patch patch.json --output main.tscn --project-root .
```

**Patch schema:** see [agent_scene_authoring.md](agent_scene_authoring.md#patch-format).

**Implementation:** `src/godot/scene_patch.zig`

**Done when:** Single patch builds Phase B–D equivalent of sample scene; round-trip validates.

---

### Phase G — Agent ergonomics (no MCP required) — **done**

- **`docs/agent_scene_authoring.md`** — **done** — recipes, patch reference, anti-patterns, `scene plan` workflow
- **Cursor rule** `.cursor/rules/godot-scene-authoring.mdc` — **done**
- **`scene plan`** — **done** — expand intent JSON to patch JSON; optional dry-run preview; `--write-patch`

Defer MCP server; CLI + patch JSON is enough.

---

### Phase H — Verification and iteration — **done**

- **`scene diff`** — **done** — node tree + `--properties` for property-level diff
- **`scene apply --intent`** — **done** — one-shot expand + apply
- **Undo snapshots** — **done** — `--snapshot`, `--auto-snapshot`, `--write-undo-patch`, `scene restore`
- **More intent recipes** — **done** — `camera_2d`, `ui_panel`, `tilemap_layer`, `audio_player`

---

### Phase I — Polish and agent throughput — **done**

- **`scene apply --dry-run`** — **done** — returns `preview_diff` (node tree; `--preview-properties` for property diffs)
- **`ext_remove` / `sub_remove` patch ops** — **done** — with undo via `ext_add` / `sub_add` capture
- **`instance_override` patch op** — **done** — instance property or editable child override (`child`, `type`, `editable`)
- **`scene template list|show|copy`** — **done** — built-ins in `templates/` (`2d/character_body`, `ui/control_root`)
- **`godot-cli batch`** — **done** — multi-step workflows; modes `stop`, `continue`, `atomic`; see [agent_batch_commands.md](agent_batch_commands.md)

Defer MCP server; CLI + batch + patch JSON is enough.

---

## Priority order (recommended)

| Order | Phase | Rationale |
|-------|-------|-----------|
| 1 | A | Document mutations | **done** |
| 2 | B | Node CRUD + scene refs | **done** |
| 3 | C | ext/sub resources | **done** |
| 4 | E | Component catalog | **done** (scan/list/show/validate/search/export) |
| 5 | D | PackedScene instancing | **done** |
| 6 | F | Batch patch | **done** |
| 7 | G | Documentation and agent workflows | **done** |
| 8 | H | Verification (`diff`, apply intent, recipes, undo) | **done** |
| 9 | I | Dry-run diff, resource remove ops, instance overrides, templates, batch CLI | **done** |

---

## Success criteria (overall)

An LLM with no Godot editor can:

1. Create a new 2D scene with player body, collision, and sprite **via CLI only**
2. Instance a sub-scene under a parent **without** hand-written `ext_resource` lines
3. Reparent a node **without** breaking child `parent` attrs
4. Run `scene validate` and get actionable JSON errors
5. Never need `_ready()` node spawning for static hierarchy

---

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| Godot parent attr quirks | Normalize on save; test against Godot-saved fixtures |
| Editable instance children | Phase D scoped to common case first; fixture-driven |
| Template drift vs Godot version | Generate template references with `save_rich_fixtures.gd`-style scripts |
| Patch op explosion | Start with 6–8 ops; add only when single commands prove insufficient |

---

## Session checklist (per phase)

- [ ] Read Godot save path in `resource_format_text.cpp` / `godot_ref.zig` for affected features
- [ ] Implement `scene_edit` + tests
- [ ] CLI commands + `--json` envelope
- [ ] Fixture(s) + Godot reference save where applicable
- [ ] Update `mcp_tools.json` and `agent_scene_authoring.md`
- [ ] Tick phase in this doc

---

## References

| Path | Purpose |
|------|---------|
| `src/godot/node_tree.zig` | Path resolution (extend for mutation) |
| `src/godot/text_format/document.zig` | Section model |
| `src/godot/text_format/save_prepare.zig` | Post-edit save |
| `test_fixtures/project/sample.tscn` | Minimal hierarchy reference |
| [mini_roadmap.md](mini_roadmap.md) | Prior items 1–5 |
