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

**Today godot-cli helps read and patch** (inspect, node list, set-property) but cannot **create or restructure** the tree. Agents still have to emit raw TSCN for new nodes — which is where quality collapses.

---

## Design principles

1. **Tree operations, not text edits.** Agents call `scene node add`, not “insert these lines after line 42.”
2. **Every mutation validates.** Return structured errors (duplicate name, unknown parent, invalid type) before write.
3. **Godot save path on write.** All mutations go through existing `save_prepare` (IDs, `load_steps`, ordering).
4. **JSON in, JSON out.** Batch ops via `--request` / patch documents; human argv for shell use.
5. **Templates over imagination.** Ship canonical mini-scenes (2D player, UI, 3D body) agents copy and specialize.
6. **Inspect before and after.** `node list`, `inspect`, and `validate` are the agent feedback loop.

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

### Phase D — PackedScene instancing

**Problem:** LLMs constantly confuse `instance`, `instance=ExtResource`, and child overrides.

**Commands:**

```bash
godot-cli scene instance add main.tscn --parent /root/Main \
  --scene res://enemies/slime.tscn --name Slime
godot-cli scene instance add main.tscn --parent /root/Main --scene res://ui/hud.tscn \
  --name HUD --editable
```

**Behaviour:**

- Add `ext_resource type="PackedScene" path="..." id="N_xxxx"`
- Add node with `instance=ExtResource("N_xxxx")` and correct `parent`
- Optional `--editable` (Godot `instance=ExtResource(...)` editable children pattern — match Godot 4.x save format from fixture)
- Document in agent guide: when to instance vs duplicate inline

**Fixtures:** `test_fixtures/project/instanced_child.tscn` — minimal parent + instanced child, Godot-saved reference.

**Done when:** `test-godot` or compare against Godot save for instance fixture.

---

### Phase E — Scene templates (built-in patterns)

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

### Phase F — Declarative patch (batch authoring)

**Problem:** Ten sequential CLI calls are slow and brittle for agents.

**Command:**

```bash
godot-cli scene apply main.tscn --patch patch.json --output main.tscn
```

**Patch schema (sketch):**

```json
{
  "ops": [
    { "op": "node_add", "parent": "/root/Main", "name": "Player", "type": "CharacterBody2D",
      "properties": { "position": "Vector2(100, 200)" } },
    { "op": "sub_add", "type": "CircleShape2D", "id_hint": "shape",
      "properties": { "radius": 8.0 } },
    { "op": "node_add", "parent": "/root/Main/Player", "name": "Collision",
      "type": "CollisionShape2D", "properties": { "shape": "SubResource(\"CircleShape2D_shape\")" } },
    { "op": "ext_add", "type": "Script", "path": "res://player.gd", "id_hint": "script" },
    { "op": "node_set", "path": "/root/Main/Player", "property": "script", "value": "ExtResource(\"1_script\")" }
  ]
}
```

**Behaviour:**

- Apply ops in order; collect all errors or fail fast (`--strict`)
- `id_hint` maps to generated ext/sub IDs within the patch
- `--dry-run` returns planned diff / resulting tree JSON without write

**Done when:** Single patch builds Phase B–D equivalent of sample scene; round-trip validates.

---

### Phase G — Agent ergonomics (no MCP required)

- **`docs/agent_scene_authoring.md`** — recipes: “add 2D player”, “instance UI”, “fix parenting”
- **Cursor rule / skill** pointing at `mcp_tools.json` + templates
- **`scene plan`** (optional) — read natural language / JSON intent, emit patch JSON only (no write); keeps logic in CLI

Defer MCP server; CLI + patch JSON is enough.

---

## Priority order (recommended)

| Order | Phase | Rationale |
|-------|-------|-----------|
| 1 | A | Document mutations | **done** |
| 2 | B | Node CRUD + scene refs | **done** |
| 3 | C | ext/sub resources | **done** |
| 4 | E | Templates | **next** |
| 5 | D | Instancing is common but error-prone — needs good fixtures |
| 6 | F | Batch patch once single ops are stable |
| 7 | G | Documentation and agent workflows |

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
