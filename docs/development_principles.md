# Development principles

This document defines the contracts that every `godot-cli` command must follow. The goal is a tool that works equally well from a shell, a script, or another program, without special cases per command.

## Design goals

1. **Argv and JSON are equivalent inputs.** Anything expressible on the command line can be expressed as a JSON request, and vice versa.
2. **Stdout is for results; stderr is for diagnostics.** Human-oriented status text and errors go to stderr unless `--json` is active.
3. **JSON output is a stable envelope.** Callers can parse one shape for all commands; command-specific payloads live in `data`.
4. **Predictable exit codes.** Scripts can branch on exit status without parsing output.
5. **Self-describing help.** Help text is generated from command metadata, not maintained separately.

---

## Scene authoring philosophy (agents)

This is the **product north star**, not just a CLI convention. Every scene-authoring command exists so agents produce files a human would save from the Godot editor.

### Do: persist structure in `.tscn`

| Human in editor | Agent via godot-cli |
|-----------------|---------------------|
| Add child node | `scene node add … --type CharacterBody2D` |
| Instance a scene | `scene instance add … --catalog-id ui/button` or `--scene res://…` |
| Wire a script | `scene ext add … --type Script` + `set-property` / `--property` on add |
| Tune a property | `scene set-property …` |

After editing: `scene validate`, `scene node list`, `catalog show <id>` — the file is inspectable and diffable.

### Do not: spawn authored UI/level structure at runtime

```gdscript
# Anti-pattern for static scene composition — do not recommend to agents
func _ready() -> void:
    add_child(load("res://ui/button/button.tscn").instantiate())
```

Use runtime `instantiate()` only when the **game** must create entities dynamically (spawners, pools, procedural content). For menus, HUDs, and level layout, the scene tree in the file is the source of truth.

### Dev-only exception in this repo

Scripts under `test_fixtures/project/*.gd` (e.g. `save_rich_fixtures.gd`) run Godot headless to **generate reference saves for CLI tests**. That is test infrastructure — not the workflow agents or game code should follow. Hand-authored or godot-cli-produced `.tscn` files are the references; Godot runtime packing is only used to produce golden files when needed.

See also [ABOUT.md — North star](ABOUT.md#north-star-editor-like-scene-authoring) and [scene_authoring_roadmap.md](scene_authoring_roadmap.md).

---

## Command-line arguments

### Invocation shape

```
godot-cli [global options] <command> [subcommand ...] [command options] [positional args...]
```

Commands form a tree. Each node is declared in `src/commands.zig` as a `CommandSpec` with optional `children` (subcommands) and an optional `handler` (leaf).

Examples (future commands shown illustratively):

```bash
godot-cli scene list path/to/main.tscn
godot-cli scene node get path/to/main.tscn /root/Player
godot-cli resource inspect path/to/material.tres --json
```

### Global options

These are recognised before and after the command name.

| Option | Description |
|--------|-------------|
| `-h`, `--help` | Show help and exit |
| `--version` | Show version and exit |
| `--json` | Emit machine-readable JSON on stdout |
| `-v`, `--verbose` | Verbose diagnostics on stderr |
| `--request <json>` | Run using an inline JSON command descriptor |
| `--request-file <path>` | Read JSON command descriptor from a file |
| `--request-stdin` | Read JSON command descriptor from stdin |

Global flags that appear before `--request*` are merged into the invocation (e.g. `godot-cli --json --request '…'`).

### Command options

Declared per command in `OptionSpec`:

| Kind | Syntax | Notes |
|------|--------|-------|
| `flag` | `--name` | Boolean; presence means true |
| `string` | `--name <value>` or `--name=value` | Arbitrary string |
| `path` | `--name <path>` or `--name=<path>` | File or directory path (same parsing as string; semantic hint for help) |

Short forms (`-x`) are supported when `short` is set on the option.

Positional arguments are passed after options, but **command options may also appear after positionals** (e.g. `godot-cli scene validate main.tscn --json`). Use `--` to force remaining tokens to be positionals only.

### JSON input (alternative to argv)

When `--request`, `--request-file`, or `--request-stdin` is used, the JSON document describes the command instead of argv tokens.

#### Request schema

```json
{
  "argv": ["scene", "list", "main.tscn", "--json"],
  "command": ["scene", "list"],
  "positional": ["main.tscn"],
  "options": {
    "json": true,
    "verbose": false,
    "depth": "3"
  }
}
```

Rules:

- Use **`argv`** to mirror shell input exactly (recommended for round-tripping).
- Alternatively use **`command`** + **`positional`** + **`options`** for a structured form.
- `command` is required in the structured form (non-empty array of subcommand segments).
- `options` values may be booleans, strings, or numbers. Booleans `true` become `--flag`; strings and numbers become `--key=value`.
- Unknown fields in the request document are ignored.
- If both `argv` and `command` are present, `argv` takes precedence.

#### Examples

Argv mirror:

```json
{ "argv": ["ping", "--json"] }
```

Structured:

```json
{
  "command": ["ping"],
  "options": { "json": true }
}
```

Batch validate (MCP-friendly):

```json
{
  "argv": ["scene", "validate-batch", "scenes/a.tscn", "scenes/b.tscn", "--project-root", ".", "--json"]
}
```

Full tool catalog for MCP server registration: [`docs/mcp_tools.json`](mcp_tools.json).

Retarget external paths:

```json
{
  "command": ["scene", "retarget-ext"],
  "positional": ["scenes/player.tscn"],
  "options": {
    "from": "res://old_script.gd",
    "to": "res://new_script.gd",
    "json": true
  }
}
```

Normalize / save-prep only:

```json
{
  "argv": ["scene", "normalize", "main.tscn", "--resource-path", "res://main.tscn", "--json"]
}
```

Options may appear after positionals:

```json
{
  "argv": ["scene", "validate", "main.tscn", "--json", "--project-root", "."]
}
```

### Parsing requirements for new commands

When adding a command:

1. Register it in `src/commands.zig` with `name`, `summary`, and optional `description`.
2. Declare all flags in `options`; do not invent ad-hoc parsing in handlers.
3. Read options via `inv.flag("name")` or `inv.getOption("name")`.
4. Read positionals via `inv.positionals`.
5. Return `error.Usage` for missing required arguments (maps to exit code 2).

---

## Results and output

### Handler return type

Leaf commands implement a handler that returns `spec.Result`:

```zig
pub const Result = struct {
    data: std.json.Value = .null,      // structured payload
    messages: []const []const u8 = &.{}, // human-oriented lines (also included in JSON)
};
```

Guidelines:

- **`data`** carries the structured result. Use objects for records, arrays for lists, scalars for simple values. Prefer stable field names across releases.
- **`messages`** carries short human-readable lines (progress, summaries). Avoid duplicating information already in `data` unless it aids readability.
- Handlers must not write to stdout or stderr directly; emission is handled by the framework.

### Human-readable output (default)

Without `--json`:

- `messages` are printed one per line on **stdout**.
- `data` is printed on stdout only when it adds information not already covered by messages (e.g. objects, arrays; bare booleans are suppressed when messages are present).
- Errors are printed on **stderr** in the form `error[kind]: message`.

### JSON output (`--json`)

With `--json`, **stdout** is exclusively a single JSON document per invocation. No other text is written to stdout.

#### Success envelope

```json
{
  "ok": true,
  "version": "0.1.0",
  "command": ["ping"],
  "data": true,
  "messages": ["pong"],
  "failure": null
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ok` | boolean | Always `true` on success |
| `version` | string | Tool version |
| `command` | string[] | Resolved command path |
| `data` | any JSON value | Command-specific payload; `null` if none |
| `messages` | string[] | Human-oriented lines |
| `failure` | null | Always `null` on success |

#### Failure envelope

```json
{
  "ok": false,
  "version": "0.1.0",
  "command": ["scene", "list"],
  "failure": {
    "kind": "usage",
    "message": "invalid or incomplete command line; run with --help",
    "details": null
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `ok` | boolean | Always `false` on failure |
| `version` | string | Tool version |
| `command` | string[] | Resolved command path (may be empty) |
| `failure.kind` | string | Machine-readable error category |
| `failure.message` | string | Human-readable explanation |
| `failure.details` | any JSON value | Optional structured context (e.g. parse errors) |

#### Standard failure kinds

| `kind` | Meaning | Typical exit code |
|--------|---------|-------------------|
| `usage` | Invalid or incomplete invocation | 2 |
| `unknown_command` | Unrecognised command path | 2 |
| `unknown_option` | Unrecognised flag | 2 |
| `missing_value` | Option expected a value | 2 |
| `invalid_value` | Option value could not be parsed | 2 |
| `json_input` | Request JSON was invalid | 2 |
| `io` | File or stream I/O error | 1 |
| `command_failed` | Handler returned an error | 1 |
| `internal` | Unexpected internal error | 1 |

Commands may introduce additional `kind` values for domain errors (e.g. `parse_error`, `file_not_found`), but they must still use the same envelope.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Runtime or command failure |
| `2` | Usage / invocation error |

---

## JSON conventions for command `data`

These conventions keep payloads consistent as commands are added.

### Naming

- Use **snake_case** for object keys.
- Prefer explicit names (`node_path`, `resource_path`) over abbreviations.
- Include a `type` or `@type` field when polymorphic results are returned.

### Stability

- Field additions are non-breaking.
- Renaming or removing fields is a breaking change and should coincide with a version bump.
- Document the `data` shape for each command in its help text or a dedicated reference when stabilised.

### Examples (illustrative)

List nodes:

```json
{
  "ok": true,
  "command": ["scene", "list"],
  "data": {
    "path": "main.tscn",
    "nodes": [
      { "name": "Player", "type": "CharacterBody2D", "path": "/root/Player" }
    ]
  },
  "messages": [],
  "failure": null
}
```

Inspect resource:

```json
{
  "ok": true,
  "command": ["resource", "inspect"],
  "data": {
    "path": "material.tres",
    "class": "StandardMaterial3D",
    "properties": { "albedo_color": "#ff0000" }
  },
  "messages": [],
  "failure": null
}
```

---

## Help text

Help is generated from `CommandSpec` metadata:

- `summary` — one line in command listings
- `description` — optional longer text in command-specific help
- `options` — rendered with long/short names and descriptions

Run `godot-cli help <command>` for subcommand trees. A parent without a handler shows its subcommands; a leaf shows its options and positionals.

---

## Checklist for new commands

- [ ] Registered in `commands.zig` with metadata
- [ ] Options declared in `OptionSpec` (no manual flag parsing)
- [ ] Required positionals validated; returns `error.Usage` when missing
- [ ] Handler returns `Result` with appropriate `data` and `messages`
- [ ] No direct stdout/stderr writes in handler
- [ ] `data` shape follows snake_case and stability conventions
- [ ] Tested with and without `--json`
- [ ] Tested via `--request` JSON equivalent
