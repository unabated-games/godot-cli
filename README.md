# godot-cli

Create, edit, and manipulate Godot scenes and resource files from the command line.

Built in [Zig](https://ziglang.org/) 0.16. Designed for interactive use, scripting, and tool integration via a consistent JSON interface.

See **[CHANGELOG.md](CHANGELOG.md)** for recent changes.

## Status

Early development. Godot-compatible **ID generation**, **UID cache**, **scene/resource inspect**, **validate**, **normalize**, **set-property**, and **Godot save round-trip** are available. Scene authoring Phases A–D (node CRUD, ext/sub resources, PackedScene instancing) and **catalog** commands are implemented — see [scene authoring roadmap](docs/scene_authoring_roadmap.md) and [catalog design](docs/catalog_design.md).

**North star:** agents author **editor-like scenes** in `.tscn` — not runtime `instantiate()` workarounds. See [ABOUT.md](docs/ABOUT.md#north-star-editor-like-scene-authoring).

Compatibility is verified against **Godot 4.7**, both in unit tests and in a round-trip suite that compares godot-cli's output byte-for-byte against files the editor itself saved.

## Requirements

- Zig 0.16.0 or later
- Godot 4.7, only for `zig build test-godot`

Supported targets: Linux (glibc and musl), macOS, and Windows, on x86_64 and aarch64. Every release builds all of them, and CI cross-compiles each on every change.

## Building

```bash
zig build
```

The binary is installed to `zig-out/bin/godot-cli`.

```bash
zig build test         # unit tests + CLI smoke tests
zig build test-godot   # requires Godot 4.7 at the default macOS path (or -Dgodot=...)
zig build run -- --help
```

CI runs `zig fmt --check` and `zig build test` on Linux and macOS for every push and pull request, plus a cross-compile of every supported target. The Godot round-trip suite runs on pushes to `main`.

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

# Author a scene the way the editor would — nodes persisted in the .tscn
godot-cli scene new --output main.tscn --root-name Main --root-type Node2D
godot-cli scene node add main.tscn --parent /root/Main --name Player --type CharacterBody2D
godot-cli scene node list main.tscn --json
godot-cli scene node rename main.tscn /root/Main/Player --name Hero
godot-cli scene node reparent main.tscn /root/Main/Hero --parent /root/Main/Playfield
godot-cli scene ext add main.tscn --type Texture2D --path res://icon.svg
godot-cli scene sub add main.tscn --type RectangleShape2D --property size --value "Vector2(16, 32)"
godot-cli scene instance add main.tscn --parent /root/Main --name MyButton \
  --scene res://ui/button/button.tscn --project-root .
godot-cli scene template list --json
godot-cli scene template copy ui/control_root --output hud.tscn

# Declarative editing: intent -> patch -> apply, with a diff and an undo patch
godot-cli scene plan main.tscn --intent intent.json --project-root . --json
godot-cli scene apply main.tscn --patch patch.json --project-root . --write-undo-patch undo.json
godot-cli scene diff before.tscn after.tscn --json
godot-cli scene restore main.tscn --snapshot main.tscn.godot-cli-snapshot

# Component catalog (project manifests + Godot builtins)
godot-cli catalog add res://ui/button/button.tscn --project-root . \
  --summary "Project standard animated UI button" --tags ui,button
godot-cli catalog add res://ui/button/button.tscn --project-root . --update
godot-cli catalog list --project-root . --json
godot-cli catalog show ui/button --project-root . --json
godot-cli catalog validate --project-root . --json
godot-cli catalog relink --project-root . --dry-run   # repoint manifests whose scene moved
godot-cli catalog search button --project-root . --json
godot-cli catalog export --project-root . --output AGENTS.md

# project.godot settings
godot-cli project show --project-root . --json
godot-cli project settings set --project-root . --section application --key run/main_scene --value res://main.tscn
godot-cli project input apply --project-root . --intent share/examples/intents/wasd_movement.json
godot-cli project autoload list --project-root . --json
godot-cli project plugins enable --project-root . --plugin my_plugin
godot-cli project apply --project-root . --intent share/examples/intents/project_bootstrap.json

# Several commands in one invocation
godot-cli batch --file share/examples/batch/apply_validate.json --json

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
  catalog/           Bundled Godot builtin catalog data
docs/                Agent guides, design docs, mcp_tools.json
templates/           Built-in scene templates (scene template copy)
share/examples/      Example intent, patch, and batch JSON
skills/              Agent skill package (godot-scene-authoring)
tools/
  import_fixtures.sh   # Godot --import for test_fixtures/project
  sync_id_session.sh   # Import ext_resource ids from Godot save into session cache
test_fixtures/
  project/           # Minimal Godot project (IDs, rich variant fixtures)
third_party/
  licenses/          # Full license texts for ported third-party code
.github/
  workflows/ci.yml       # fmt, tests, cross-compile, Godot round-trip
  workflows/release.yml  # tagged release binaries
```

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md)
for the development setup, what CI checks, and the conventions new commands follow.
Participation is covered by our [Code of Conduct](CODE_OF_CONDUCT.md). To report a
security issue, see [SECURITY.md](SECURITY.md).

## License

godot-cli is released under the [MIT License](LICENSE), copyright © 2026
[Unabated Games](https://github.com/unabated-games).

It contains code ported from the Godot Engine (MIT) and from PCG
(Apache-2.0). Those notices, and what was changed, are recorded in
[THIRDPARTY.md](THIRDPARTY.md); the Apache-2.0 text is included at
[`third_party/licenses/`](third_party/licenses/).

"Godot" and the Godot Engine logo are trademarks of the Godot Foundation. This
project is not affiliated with, endorsed by, or sponsored by the Godot Foundation
or the Godot Engine project.
