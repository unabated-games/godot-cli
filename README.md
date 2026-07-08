# godot-cli

Create, edit, and manipulate Godot scenes and resource files from the command line.

Built in [Zig](https://ziglang.org/) 0.16. Designed for interactive use, scripting, and tool integration via a consistent JSON interface.

## Status

Early development. Godot-compatible **ID generation**, **UID cache**, **scene/resource inspect**, **validate**, **normalize**, **set-property**, and **Godot save round-trip** are available. Save preparation matches Godot's ID seeding, ext_resource ordering, and optional byte-identical output via `--godot-save-format` + id session cache — see [ID generation plan](docs/id_generation_plan.md).

**Next work:** [Scene authoring](docs/scene_authoring_roadmap.md) Phase E (templates). Phases A–C done: scene new, node CRUD, ext/sub resources, `scene refs`.

## Requirements

- Zig 0.16.0 or later

## Building

```bash
zig build
```

The binary is installed to `zig-out/bin/godot-cli`.

```bash
zig build test
zig build test-godot   # requires Godot 4.x at default macOS path (or -Dgodot=...)
zig build run -- --help
```

CI workflow is available but **manual only** (GitHub Actions → CI → Run workflow). For day-to-day iteration use `zig build test` locally; `zig build test-godot` when you have Godot installed.

Optional build flag:

```bash
zig build -Dversion-string=0.2.0
```

## Usage

```bash
# Help
godot-cli --help
godot-cli help <command>

# Version
godot-cli --version
godot-cli --version --json

# Run a command (human-readable output)
godot-cli ping

# Machine-readable output
godot-cli ping --json

# Resource UIDs (Godot-compatible)
godot-cli uid encode 1350303725746704497
godot-cli uid decode uid://tidkmw585t0t
godot-cli uid create-for-path --project-name TestProject --resource-path res://test.tscn \
  test_fixtures/project/test.tscn
godot-cli uid scene-id generate --seed 1290995245 --count 5
godot-cli uid cache list --project-root test_fixtures/project
# Inspect scenes/resources
godot-cli scene inspect path/to/main.tscn --json
# Validate (exit 1 on errors; use global --json for envelope)
godot-cli scene validate test_fixtures/invalid_duplicate_id.tscn
godot-cli scene validate path/to/main.tscn --project-root .   # enables stale uid checks
godot-cli scene normalize --resource-path res://main.tscn --output out.tscn in.tscn
godot-cli scene validate-batch *.tscn --project-root .
godot-cli scene retarget-ext --from res://old.gd --to res://new.gd scenes/*.tscn
godot-cli scene round-trip path/to/main.tscn --dry-run
godot-cli scene compare-godot sample.tscn sample_godot_saved.tscn --json
godot-cli scene normalize in.tscn --output out.tscn --project-root . --godot-save-format
godot-cli uid session import --referrer res://main.tscn --from godot_saved.tscn --project-root .
godot-cli scene set-property --node-name Player --property visible --value true path/to/main.tscn

# Resource files (.tres)
godot-cli resource inspect path/to/material.tres --json
godot-cli resource set-property --section resource --property albedo_color --value "Color(1, 0, 0, 1)" path/to/material.tres

# JSON command descriptor (alternative to argv)
godot-cli --request '{"command":["ping"]}'
godot-cli --json --request '{"command":["ping"]}'
godot-cli --request-file request.json
godot-cli --request-stdin < request.json
```

## Documentation

- [About godot-cli](docs/ABOUT.md) — what it is, what it can do, why it exists
- [Scene authoring roadmap](docs/scene_authoring_roadmap.md) — LLM-first plan for full scene authoring
- [Development principles](docs/development_principles.md) — CLI argument conventions, result shapes, and JSON contracts
- [MCP tool catalog](docs/mcp_tools.json) — JSON request shapes for every command
- [ID generation plan](docs/id_generation_plan.md) — Godot ID systems and roadmap for scene/resource I/O

Regenerate Godot import metadata for test fixtures:

```bash
tools/import_fixtures.sh
# or: GODOT=/path/to/Godot tools/import_fixtures.sh
# optional: REGENERATE_RICH=1 tools/import_fixtures.sh  # material + scene shells via save_rich_fixtures.gd
```

Rich variant fixtures live in `test_fixtures/project/rich_variants.tscn` and `sample_material.tres` (see `src/godot/fixtures.zig` tests).

## Project layout

```
src/
  main.zig           Entry point
  commands.zig       Command registry
  commands/          Command implementations
  godot/             Godot-compatible primitives (UID, scene IDs, …)
  cli/               Argument parsing, help, JSON input
  output/            Result emission (text and JSON)
docs/
  development_principles.md
  id_generation_plan.md
  mcp_tools.json
tools/
  import_fixtures.sh   # Godot --import for test_fixtures/project
  sync_id_session.sh   # Import ext_resource ids from Godot save into session cache
test_fixtures/
  project/           # Minimal Godot project (IDs, rich variant fixtures)
.github/
  workflows/ci.yml   # manual workflow_dispatch only (zig build test + test-godot)
```

## License

TBD
