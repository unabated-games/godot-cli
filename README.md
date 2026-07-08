# godot-cli

Create, edit, and manipulate Godot scenes and resource files from the command line.

Built in [Zig](https://ziglang.org/) 0.16. Designed for interactive use, scripting, and tool integration via a consistent JSON interface.

## Status

Early development. The CLI framework (argument parsing, help, JSON input/output) is in place. **Godot-compatible ID generation** (`uid` commands) is implemented and tested against Godot 4.7. Scene and resource load/save are not yet implemented — see [ID generation plan](docs/id_generation_plan.md).

## Requirements

- Zig 0.16.0 or later

## Building

```bash
zig build
```

The binary is installed to `zig-out/bin/godot-cli`.

```bash
zig build test
zig build run -- --help
```

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

# JSON command descriptor (alternative to argv)
godot-cli --request '{"command":["ping"]}'
godot-cli --json --request '{"command":["ping"]}'
godot-cli --request-file request.json
godot-cli --request-stdin < request.json
```

## Documentation

- [Development principles](docs/development_principles.md) — CLI argument conventions, result shapes, and JSON contracts
- [ID generation plan](docs/id_generation_plan.md) — Godot ID systems and roadmap for scene/resource I/O

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
test_fixtures/
  project/           Minimal Godot project for cross-checking IDs
```

## License

TBD
