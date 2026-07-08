# About godot-cli

## What it is

**godot-cli** is a standalone Zig command-line tool for reading, validating, editing, and writing Godot **text scene and resource files** (`.tscn`, `.tres`). It is **not** a game engine, not a headless Godot replacement, and not a runtime.

It treats Godot project files as structured text: parse them into a document model, reason about IDs and property values, make targeted edits, and write output that Godot will accept — ideally byte-identical to what Godot itself would save.

The interface is built for humans, scripts, and LLM agents: every command works from argv or JSON (`--json`, `--request`), with a stable response envelope.

## Why it exists

Godot’s scene format is deceptively simple text, but the details are fiddly:

- Several **ID systems** (resource UIDs, ext/sub-resource IDs, node `unique_id`)
- **Variant text** for property values (`Object(Gradient, ...)`, typed arrays, packed arrays, etc.)
- **Save ordering and seeding** that affect whether a file round-trips cleanly

That makes automation painful. You either:

1. Run Godot headless for every change (slow, heavy, awkward in CI/agents), or
2. Edit `.tscn` by hand or with regex (fragile, easy to break IDs and references)

godot-cli is the **middle path**: a fast, deterministic, scriptable layer that understands Godot’s file conventions well enough to edit scenes safely — without booting the engine.

The original north star was **Godot-compatible ID generation and save round-trip**. Everything else grew from needing to do useful work on that foundation: inspect files, validate them, set properties, normalize output.

A secondary motivation is **agent ergonomics**: LLMs struggle to edit Godot scene text directly. A CLI that returns structured JSON (`inspect`, `node list`, parsed properties) gives agents a reliable API instead of raw file bytes.

## What it can do today

Roughly four layers:

### 1. Godot ID primitives (`uid` commands)

- Encode/decode `uid://…` text ↔ integer
- Generate UIDs from file paths (same algorithm as Godot)
- Generate scene-local ext/sub-resource IDs and node `unique_id`s
- Read `.godot/uid_cache.bin`
- Import ID sessions from a Godot-saved reference file (so CLI saves can match Godot’s ext_resource IDs)

This is the compatibility core — verified against Godot 4.7.

### 2. Read and understand files

- **`scene inspect` / `resource inspect`** — section structure, headers, and (with `--json`) parsed properties with `kind` and typed `value` where possible
- **`scene node list` / `scene node get`** — node tree as paths (`/root/Player`), types, parents, `unique_id`s
- **Variant parser** — bools, numbers, colors, vectors, `Object()`, arrays, dictionaries, typed collections, packed arrays, ext/sub-resource refs, etc.

### 3. Validate and diagnose

- **`scene validate` / `resource validate`** — duplicate IDs, malformed headers, stale UIDs (with `--project-root`)
- **`validate-batch`** — many files at once
- **`compare-godot`** — diff your file against a Godot-saved reference
- **`round-trip`** — parse → write → parse sanity check

### 4. Edit and save

- **`set-property`** — change a property value via Variant parse → format (scene or resource)
- **`normalize`** — repair IDs, sort ext_resources, prepare for save
- **`--normalize-properties`** — rewrite all property values through the Variant parser (canonical float/color formatting, etc.)
- **`--godot-save-format`** — aim for byte-identical output vs a Godot reference (with id session cache)
- **`retarget-ext`** — bulk retarget `res://` paths in ext_resources

## What it is good at vs what it is not

**Good at:**

- Batch/automated scene surgery (CI, migration scripts, agents)
- “What’s in this scene?” without opening the editor
- Safe property edits with Godot-correct formatting
- Proving compatibility with Godot via `test-godot` round-trip against real saves

**Not (yet) meant for:**

- Running gameplay, physics, or scripts
- Full scene authoring (add nodes, reparent, build scenes from scratch — see [scene_authoring_roadmap.md](scene_authoring_roadmap.md))
- Binary `.scn` / `.res` files
- Replacing the Godot editor for creative work

## One-line summary

**godot-cli is a Godot-aware scene file toolkit** — fast, headless, JSON-friendly — built so humans, scripts, and LLMs can manipulate `.tscn`/`.tres` files with the same care Godot uses when saving, without running the engine.

The bet is that **file-format fidelity + structured CLI output** is more valuable than a thin regex editor or duplicating Godot in another runtime. The hard part is IDs, variants, and round-trip; the commands are the payoff on top.

## Related docs

| Doc | Purpose |
|-----|---------|
| [development_principles.md](development_principles.md) | CLI/JSON contracts |
| [id_generation_plan.md](id_generation_plan.md) | Completed ID and I/O phases |
| [mini_roadmap.md](mini_roadmap.md) | Post-phase-6 feature backlog |
| [scene_authoring_roadmap.md](scene_authoring_roadmap.md) | LLM-first scene authoring plan |
| [mcp_tools.json](mcp_tools.json) | JSON request shapes for every command |
