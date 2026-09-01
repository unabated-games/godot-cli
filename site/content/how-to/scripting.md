---
title: Script godot-cli from shells and other programs
description: The JSON envelope, exit codes, JSON requests, the batch runner, and shell completions.
---

# Script godot-cli

godot-cli is built to be called by something else. Output is one JSON document per invocation, exit codes are stable, and anything expressible on the command line is expressible as a JSON request.

## The envelope

```bash
godot-cli scene validate scenes/main.tscn --project-root . --json
```

```json
{
  "ok": true,
  "version": "0.2.0",
  "command": ["scene", "validate"],
  "data": { "path": "scenes/main.tscn", "kind": "scene", "issues": [], "error_count": 0 },
  "messages": [],
  "failure": null
}
```

Every command returns those six fields. Command-specific output lives in `data`, human-readable lines in `messages`, and errors in `failure` with a `kind`, a `message`, and optional structured `details`:

```json
{
  "ok": false,
  "failure": { "kind": "unknown_command", "message": "unknown command", "details": null }
}
```

With `--json`, stdout carries nothing but that document. Without it, results print as text and errors go to stderr as `error[kind]: message`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | The command ran and failed, including validation finding errors |
| 2 | The invocation was wrong: unknown command, missing value, bad option |

That split lets a script tell "your scene has problems" from "you called this wrong":

```bash
if ! godot-cli scene validate scenes/main.tscn --project-root . --json > result.json; then
  case $? in
    1) jq -r '.data.issues[] | "\(.line): \(.kind) \(.message)"' result.json ;;
    2) echo "bad invocation" >&2 ;;
  esac
fi
```

## JSON in, JSON out

The same command can arrive as a document instead of argv, which suits callers that already hold structured data:

```bash
godot-cli --json --request '{"argv": ["scene", "node", "list", "scenes/main.tscn"]}'
godot-cli --json --request-file request.json
godot-cli --json --request-stdin < request.json
```

The structured form separates the parts:

```json
{
  "command": ["scene", "validate"],
  "positional": ["scenes/main.tscn"],
  "options": { "project-root": ".", "json": true }
}
```

`$GODOT_CLI_HOME/docs/mcp_tools.json` carries a worked request for every command. For generating bindings, `godot-cli reference --format json` prints the command tree itself:

```json
{
  "path": "scene node add",
  "summary": "Add a child node under a parent path",
  "runnable": true,
  "options": [ { "long": "parent", "kind": "string", "description": "Parent viewport path" } ]
}
```

## Many commands, one process

For a sequence, `batch` avoids paying process startup per step and returns a result per step:

```bash
godot-cli batch --file workflow.json --json
```

See [batch edits]({{ base_url }}/how-to/batch-edits/) for the schema and the three failure modes.

## Shell completions and the man page

The installer puts both in place and `env.sh` wires them up, so `godot-cli scene node <tab>` completes and `man godot-cli` works. To install them somewhere else, or for a shell you configure by hand:

```bash
godot-cli completions bash > /usr/local/etc/bash_completion.d/godot-cli
godot-cli completions zsh  > "${fpath[1]}/_godot-cli"
godot-cli completions fish > ~/.config/fish/completions/godot-cli.fish
godot-cli man > /usr/local/share/man/man1/godot-cli.1
```

All four are generated from the same command tree the parser uses, so they describe the binary that printed them rather than the version someone documented last.

## Use it as a library

The Zig module is exported as `godot_cli_tools` for embedding, which skips the process boundary if you are already writing Zig. The CLI is a thin layer over it.
