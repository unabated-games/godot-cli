# Component catalog design

**Goal:** Give LLM agents and automation a **project-aware catalog** of instancable scenes — what exists, when to use it, how to wire signals, and which exports form the public interface.

Manifests are plain `*.manifest.json` files. `godot-cli catalog add` scaffolds them, `catalog scan` reads them, and nothing needs to be installed in the Godot project for either to work.

**Related:** [Scene authoring roadmap](scene_authoring_roadmap.md) Phase D (instancing) consumes catalog ids via `scene instance add --catalog-id …`.

---

## Problem

LLMs fail at Godot scene work for **project semantics**, not just TSCN syntax:

- Which button scene is the project standard?
- When should a raw Godot `Button` be used instead?
- What signals should be connected, and what do exports mean on a composite control?

Parsing and editing `.tscn` files is necessary but not sufficient. Agents need a **curated, searchable catalog** with human-authored guidance.

---

## Architecture overview

```
┌─────────────────────────────────────────────────────────────────────┐
│  godot-cli catalog add / relink                                     │
│  *.manifest.json beside each scene — plain data, no addon needed    │
└───────────────────────────────┬─────────────────────────────────────┘
                                │  files on disk under res://
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│  godot-cli catalog                                                  │
│  scan → validate → list / show / search / export                    │
│  + builtin JSON (godot/ui/Button, …) — document-only                │
│  + GDScript heuristic parser (exports, signals on root script)        │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
              scene instance add --catalog-id …   (Phase D, later)
```

### Two catalog sources

| Source | Id namespace | Storage | Instancing |
|--------|--------------|---------|------------|
| **Builtins** | `godot/…` e.g. `godot/ui/Button` | JSON inside godot-cli repo | Document-only — agents add raw nodes, no PackedScene |
| **Project** | Semantic path e.g. `ui/widgets/animated_button` | `*.manifest.json` in project | PackedScene from manifest `scene` path |

---

## Manifest format

A manifest is a `*.manifest.json` file sitting beside the scene it describes:

```
res://ui/button/button.tscn
res://ui/button/button.manifest.json
```

Manifests are identified by filename, so the scan rejects candidates without reading
them. `catalog_format_version` is `2`.

Keeping manifests as plain data rather than Godot `Resource` files is deliberate: a
`.tres` carrying a `script_class` pins the defining script by path as an
`ext_resource`, so the project cannot open its own manifests unless that script is
installed at exactly that path. JSON has no such coupling — an agent can write one
directly, and nothing has to be installed to read it.

### Schema

```json
{
  "catalog_format_version": 2,
  "id": "ui/button",
  "scene": "res://ui/button/button.tscn",
  "scene_uid": "uid://byhqeak2spha2",
  "tags": ["ui", "button", "input"],

  "summary": "Project standard animated UI button",
  "when_to_use": "Adding a button to a player-facing UI scene",
  "when_not_to_use": "Debug panels — use godot/ui/Button instead",
  "notes": "",

  "related_ids": ["godot/ui/Button"],
  "prefer_over_ids": [],
  "export_root_script": "",

  "signals": [
    {
      "name": "button_pressed",
      "doc": "Emitted when the user left-clicks the control.",
      "connect_example": "MyButton.button_pressed.connect(_on_my_button)"
    }
  ],
  "functions": [
    { "name": "pulse", "doc": "Play the attention animation.", "when_to_call": "After a failed submit." }
  ]
}
```

Required: `catalog_format_version`, `id`, `scene`. Everything else is optional and
should be **omitted rather than written empty**, so diffs show only what was
actually said. `scene_uid` is derived from the scene's `[gd_scene]` header when
absent, and a mismatch is reported as a `scene_uid_mismatch` warning.

### Authoring with `catalog add`

```bash
godot-cli catalog add res://ui/button/button.tscn --project-root . \
  --summary "Project standard animated UI button" \
  --when-to-use "Adding a button to a player-facing UI scene" \
  --tags ui,button,input
```

Writes `button.manifest.json` beside the scene. `id` defaults to the scene path
without `res://` and without the extension, lowercased. `scene_uid` comes from the
scene header. One row per signal declared by the scene's root script is scaffolded
with empty prose, using the same GDScript parser `catalog show` uses — so the rows
you have to fill in are already named and typed for you.

`--update` re-runs the derivation against an existing manifest: prose is preserved,
rows for signals that no longer exist are dropped, and newly declared signals gain
blank rows. Without `--update`, an existing manifest is never overwritten.

### When a scene moves

`scene` is a plain path string, and Godot does not rewrite it when a `.tscn` moves —
its dependency tracking follows `ext_resource` and `uid://` references, not arbitrary
string properties. So a move leaves the manifest pointing at nothing:

```
$ godot-cli catalog validate --project-root .
error  scene_not_found  scene file does not exist under project root
exit 1
```

The failure is loud rather than silent: the entry becomes invalid, so it drops out of
`catalog list` and out of the exported digest. An agent is never handed a component
whose scene has vanished.

`scene_uid` is the anchor that survives the move. The uid stays in the scene's
`[gd_scene]` header, and Godot's `.godot/uid_cache.bin` maps it to the current path:

```bash
godot-cli catalog relink --project-root .          # --dry-run to preview
```

For every manifest whose scene is missing, this resolves `scene_uid` through the uid
cache and rewrites `scene`. It works from the manifest outward, so it also repairs a
manifest that did not travel with its scene. `id` and prose are preserved — a move
never changes the catalog's public key.

Two limits worth knowing:

- **The uid cache must have caught up.** Godot refreshes it when the project is
  opened or imported; a `git mv` with the editor closed leaves it stale. Relink
  refuses to guess in that case, reporting `unresolved` and exiting 1 rather than
  inventing a path.
- **`.tres` manifests are not rewritten.** They are reported as `manual`, with the
  `resource set-property` invocation to run.

`catalog relink` exits 1 if any manifest is still unrepaired afterwards, so it can
gate CI without a separate `validate` pass.

Builtins and project entries are **peers** in search results. There is **no shadowing** — builtins are explicit alternatives, not silent fallbacks. Manifests may reference builtins via `related_ids` / `prefer_over_ids`.

---

## Id suggestion

When the plugin suggests `id` from the assigned scene path:

```
res://UI/Widgets/Animated_Button.tscn  →  ui/widgets/animated_button
```

**Algorithm:**

1. Strip `res://` prefix if present
2. Strip file extension (`.tscn`, case-insensitive)
3. Lowercase the entire path string
4. Preserve `/` path separators

`id` is the stable **logical** key for agents. `uid` on the manifest is the stability anchor if files move outside Godot.

---

## Consumption: godot-cli

### Reading manifests

No Godot runtime required:

1. Walk `res://` under `--project-root`
2. Select files ending `.manifest.json`
3. Parse and validate

Optional project index (e.g. `.godot/godot_cli_catalog_index.json`) may cache scan results; regenerated on `catalog scan`.

### `catalog show` merge order

1. Manifest resource properties
2. `scene inspect` + `node list` on `scene`
3. GDScript heuristic parse on root script (or `export_root_script` if set)
4. Merge: script-derived exports/signals as base; manifest `signal_docs` / `function_docs` add or override **documentation** fields

Output includes `exports_source: "gdscript_heuristic"` and validation messages.

### Planned commands

```bash
godot-cli catalog scan    --project-root . [--json]
godot-cli catalog list    --project-root . [--json]
godot-cli catalog show    <id> --project-root . [--json]
godot-cli catalog validate --project-root . [--json]
godot-cli catalog search  --tags ui,button [--query "animated menu"] [--json]
godot-cli catalog export  --project-root . [--output AGENTS.md]
```

Human authoring stays in Godot. Agents and CI consume `--json` or `catalog export` digests — not hand-written JSON.

### Search

- **Tags:** structured filter on `tags`
- **Full text:** grep-like index over `summary`, `when_to_use`, `when_not_to_use`, `notes`, signal/function docs

---

## Builtins (godot-cli internal JSON)

Shipped inside this repo under `catalog/builtins/`. Developers never edit these files.

**Document-only** — no `.tscn` files injected into user projects.

**Example entry shape:**

```json
{
  "id": "godot/ui/Button",
  "class_name": "Button",
  "inherits": "BaseButton",
  "tags": ["ui", "control", "input"],
  "summary": "Standard Godot push button.",
  "when_to_use": "Simple debug UI or when no project button manifest applies.",
  "when_not_to_use": "Player-facing menus — prefer project catalog entries.",
  "properties": [],
  "signals": [
    { "name": "pressed", "doc": "Emitted when the button is toggled on." }
  ],
  "related_ids": ["godot/ui/BaseButton"]
}
```

Agents use builtins to choose raw `scene node add` with the documented class name, not PackedScene instancing.

**Authoring rule:** Project catalog entries point at PackedScenes to **instance in `.tscn`** (`scene instance add --catalog-id …`). Builtins are document-only. Neither catalog type should lead agents to `load().instantiate()` in GDScript for static UI — see [ABOUT.md](ABOUT.md#north-star-editor-like-scene-authoring).

---

## GDScript export / signal parser (v1)

Implemented in Zig from day one as a **line-oriented heuristic** (not a full GDScript compiler). Upgrade path: Godot LSP or grammar-based parser later if needed.

**Annotation accumulation:** consecutive `@…` lines until a `var` / `const` declaration.

**Supported annotations (Godot 4.x):**

- `@export`, `@export_storage`, `@export_custom(…)`
- `@export_enum`, `@export_enum_2d`
- `@export_flags`, `@export_flags_2d`
- `@export_range`, `@export_exp_easing`
- `@export_file`, `@export_dir`, `@export_global_file`, `@export_global_dir`
- `@export_multiline`, `@export_color_no_alpha`
- `@export_node_path`, `@export_string` / `StringName` variants
- `@export_placeholder`
- `@export_group`, `@export_subgroup`, `@export_category`
- `signal name(…)` including multiline argument lists

**Per-export output:**

```json
{
  "name": "speed",
  "type_hint": "float",
  "export_annotations": ["@export_range(0, 100, 0.1)"],
  "group": "Movement",
  "default": "10.0"
}
```

**Scope:** public interface of the instancable root — exports on the root script define the knobs agents set even when the visual hierarchy is deeper.

---

## Validation rules (`catalog_format_version = 1`)

### Errors (exclude from list / search / export; fail `catalog validate`)

| Condition | Intent |
|-----------|--------|
| `catalog_format_version` ≠ 1 | Unsupported format |
| Missing or empty `id` | Catalog id required |
| Missing or empty `uid` | Stable uid required |
| Missing or empty `scene` | Scene path required |
| `scene` does not resolve under project root | Scene not found |
| Duplicate `id` in project scope | Duplicate catalog id |
| Two manifests reference the same `scene` | Duplicate scene binding |
| Invalid `res://` path syntax | Invalid scene path |

### Warnings (entry still listed)

| Condition | Intent |
|-----------|--------|
| Empty `summary` | No summary for agents |
| No `tags` | No tags for search |
| Empty `when_to_use` | No usage guidance |
| `scene_uid` ≠ uid in scene file header | Scene file may have been replaced |
| `export_root_script` set but file missing | Fallback to root node script |
| Unknown `related_ids` / `prefer_over_ids` | Unresolved catalog reference |
| Script signals without `signal_docs` | Consider documenting signals |
| Script parse failed | Script interface incomplete |

### Info (non-blocking)

| Condition | Intent |
|-----------|--------|
| `scene` path changed, `scene_uid` still matches | Scene relocated |
| Manifest docs for names not in script | Manifest-only documentation (ok) |

### Scan behaviour

A `*.manifest.json` that fails to parse yields an entry carrying an `invalid_json`
error rather than failing the scan, so one broken manifest does not hide the rest of
the catalog. `catalog validate` still fails on it.

---

## Relocation detection

| Field | Role |
|-------|------|
| `id` | Agent-facing logical key (semantic path string) |
| `uid` | Manifest stability anchor (never changes after publish) |
| `scene_uid` | Scene file stability anchor (from `.tscn` header) |

On scan:

- Path changed + `scene_uid` matches → **relocated** (info)
- `scene_uid` mismatch → **broken or replaced** (warning)

---

## Format policy

- **Authoring:** Godot `.tres` only (via Godot Power AI addon)
- **Agent export:** JSON / markdown via `catalog export` and `catalog show --json`
- **TOML / sidecar files:** deferred unless a concrete need appears

---

## Implementation order

1. `catalog scan`, `list`, `show`, `validate`, builtin JSON load — done
2. GDScript heuristic parser + merge in `show` — done
3. `catalog search` (tags + full text) — done
4. `catalog export` — done
5. `catalog add` / `relink` — done
6. `scene instance add --catalog-id` (Phase D) — done

### Deferred: editor authoring

An editor addon offering an Inspector for manifest prose is a reasonable future
addition, but it would **produce `*.manifest.json`** rather than reintroduce a
Resource-backed format — the coupling that motivated JSON in the first place. Until
then, `catalog add` scaffolds the fields and a text editor fills in the prose.

---

## Non-goals (v1)

- Auto-discovering which scenes are “components” (developer decides by creating a manifest)
- Injecting builtin `.tscn` files into projects
- Dual TOML authoring format
- Multiple manifests per scene
- Full GDScript typechecker / LSP integration (heuristic parser first)

---

## Development fixtures

The committed fixture project at `test_fixtures/project/` covers catalog authoring
and `catalog scan` development. Its catalog entry lives at
`test_fixtures/project/ui/button/`, with the manifest at
`test_fixtures/project/ui/button.manifest.json`, and a second manifest at
`test_fixtures/project/instanced_child.manifest.json`.

**Sample catalog entry (project):**

| Asset | Path |
|-------|------|
| Custom button scene | `res://ui/button/button.tscn` |
| Root script | `res://ui/button/button.gd` |
| Scene uid | `uid://byhqeak2spha2` |

**Root node:** `MarginContainer` with `button.gd` — composite UI (Panel + Label), not a raw Godot `Button`.

**Script interface (for export/signal parser tests):**

- Export: `label_text: String` (`@export` with setter)
- Signal: `button_pressed`

**Suggested catalog id** (if manifest created): `ui/button/button`

**Manifest:** not yet authored — create `ui/button/button.manifest.tres` via Godot Power AI when testing scan/show/validate.

