# godot-cli

Create, edit, and manipulate Godot scenes and resource files from the command line.

Built in [Zig](https://ziglang.org/) 0.16. Designed for interactive use, scripting, and tool integration via a consistent JSON interface.

## Status

Early development. The CLI framework (argument parsing, help, JSON input/output) is in place. Scene and resource commands are not yet implemented.

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

# JSON command descriptor (alternative to argv)
godot-cli --request '{"command":["ping"]}'
godot-cli --json --request '{"command":["ping"]}'
godot-cli --request-file request.json
godot-cli --request-stdin < request.json
```

## Documentation

- [Development principles](docs/development_principles.md) — CLI argument conventions, result shapes, and JSON contracts

## Project layout

```
src/
  main.zig           Entry point
  commands.zig       Command registry
  cli/               Argument parsing, help, JSON input
  output/            Result emission (text and JSON)
docs/
  development_principles.md
```

## License

TBD
