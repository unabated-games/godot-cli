# godot-cli

Create, edit, and manipulate Godot scenes and resource files from the command line.

Built in [Zig](https://ziglang.org/) 0.16. Designed for interactive use, scripting, and tool integration via a consistent JSON interface.

See **[CHANGELOG.md](CHANGELOG.md)** for recent changes.

## Status

Early development. Godot-compatible **ID generation**, **UID cache**, **scene/resource inspect**, **validate**, **normalize**, **set-property**, and **Godot save round-trip** are available. Scene authoring Phases A–D (node CRUD, ext/sub resources, PackedScene instancing) and **catalog** commands are implemented — see [scene authoring roadmap](docs/scene_authoring_roadmap.md) and [catalog design](docs/catalog_design.md).

**North star:** agents author **editor-like scenes** in `.tscn` — not runtime `instantiate()` workarounds. See [ABOUT.md](docs/ABOUT.md#north-star-editor-like-scene-authoring).

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

## Install for agents (macOS)

Package the binary, templates, docs, and examples into a self-contained install — no source-tree references needed:

```bash
./install.sh                         # build + install to ~/.godot-cli
./install.sh --install-skill         # also install skill for Cursor, Claude Code, OpenCode, ~/.agents
./install.sh --skills-only           # refresh skills after editing skills/godot-scene-authoring/
```

Activate in your shell (add to `~/.zshrc` for persistence):

```bash
source "$HOME/.godot-cli/env.sh"
godot-cli ping --json
```

Install layout:

| Path | Contents |
|------|----------|
| `~/.godot-cli/bin/godot-cli` | Binary |
| `~/.godot-cli/templates/` | Scene templates (`scene template copy`) |
| `~/.godot-cli/docs/` | Agent guides + `mcp_tools.json` |
| `~/.godot-cli/examples/` | Intent and batch JSON examples |
| `~/.godot-cli/skills/` | Bundled skill copy |
| `~/.godot-cli/env.sh` | Sets `GODOT_CLI`, `GODOT_CLI_HOME`, `GODOT_CLI_TEMPLATES_ROOT` |

**Agent skill** (`skills/godot-scene-authoring/` in repo) installs globally with `--install-skill`:

| Tool | Path |
|------|------|
| Cursor | `~/.cursor/skills/godot-scene-authoring/` |
| Claude Code | `~/.claude/skills/godot-scene-authoring/` |
| OpenCode | `~/.config/opencode/skills/godot-scene-authoring/` |
| Other agents | `~/.agents/skills/godot-scene-authoring/` |

Agent quickstart: `$GODOT_CLI_HOME/docs/agent_quickstart.md`

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
- [Agent quickstart](docs/agent_quickstart.md) — one-page guide for LLM agents (installed to `~/.godot-cli/docs/`)
- [Agent scene authoring](docs/agent_scene_authoring.md) — full recipes and patch/intent format
- [Agent batch commands](docs/agent_batch_commands.md) — multi-step workflows
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
