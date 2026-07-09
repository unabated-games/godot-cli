# Batch commands for LLM agents

Run many `godot-cli` steps in **one process** with structured per-step results. This cuts tool-call overhead for agents that would otherwise chain `scene apply`, `scene validate`, `catalog search`, etc.

## Command

```bash
godot-cli batch --file workflow.json --json
godot-cli batch --json-body '{"mode":"stop","steps":[...]}' --json
```

Use `--file` when possible. The top-level `--request` flag is reserved for single-command JSON invocations and must not be used for batch payloads.

## Batch JSON schema

```json
{
  "mode": "stop",
  "rollback": ["scenes/main.tscn"],
  "steps": [
    {
      "argv": ["scene", "apply", "scenes/main.tscn", "--intent", "intents/hud.json", "--project-root", ".", "--json"]
    },
    {
      "argv": ["scene", "validate", "scenes/main.tscn", "--project-root", ".", "--json"]
    }
  ]
}
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `mode` | No (default `stop`) | Failure handling: `stop`, `continue`, or `atomic` |
| `rollback` | No | Scene paths to snapshot before the batch when `mode` is `atomic` |
| `steps` | Yes | Array of `{ "argv": ["subcommand", ...] }` — each argv is a full command path **without** `godot-cli` |

Each step's `argv` is parsed like a normal CLI invocation (options, positionals, `--json`).

## Failure modes

### `stop` (default)

Run steps in order. On the **first failed step**, stop and return results for all steps attempted so far. Exit code `1` if any step failed.

Use when later steps depend on earlier ones (apply → validate → diff).

### `continue`

Run **all** steps regardless of failures. Aggregate `succeeded_count` and `failed_count`. Exit code `1` if any step failed.

Use for lint/audit bundles where you want every check to run.

### `atomic`

Before any step, copy each path in `rollback` to `<path>.godot-cli-batch-backup`. If **any** step fails, restore all rollback paths from those backups and set `rolled_back: true`. Stop after the failure.

Use when a multi-step edit must not leave a scene half-modified. Typical `rollback` entry: the scene you are editing in step 1.

On full success, backup files are deleted.

## Response shape

```json
{
  "ok": true,
  "data": {
    "mode": "stop",
    "step_count": 2,
    "succeeded_count": 2,
    "failed_count": 0,
    "rolled_back": false,
    "steps": [
      {
        "index": 0,
        "argv": "scene apply main.tscn --patch p.json --json",
        "ok": true,
        "data": { "applied_count": 3, "summary": "..." }
      }
    ],
    "summary": "batch stop: 2/2 step(s) succeeded"
  }
}
```

Failed steps include `"ok": false` and `"error": "command_failed"` (or a parse/usage error name).

## Example workflows

### Apply + validate (stop)

```json
{
  "mode": "stop",
  "steps": [
    { "argv": ["scene", "apply", "main.tscn", "--intent", "player.json", "--project-root", ".", "--json"] },
    { "argv": ["scene", "validate", "main.tscn", "--project-root", ".", "--json"] }
  ]
}
```

### Multi-scene audit (continue)

```json
{
  "mode": "continue",
  "steps": [
    { "argv": ["scene", "validate", "ui/hud.tscn", "--project-root", ".", "--json"] },
    { "argv": ["scene", "validate", "levels/1.tscn", "--project-root", ".", "--json"] }
  ]
}
```

### Atomic HUD edit

```json
{
  "mode": "atomic",
  "rollback": ["scenes/main.tscn"],
  "steps": [
    { "argv": ["scene", "apply", "scenes/main.tscn", "--patch", "patches/hud.json", "--project-root", ".", "--json"] },
    { "argv": ["scene", "node", "list", "scenes/main.tscn", "--json"] }
  ]
}
```

If the second step fails, `main.tscn` is restored from the pre-batch backup.

## Tool-call savings

A typical agent flow without batch:

1. `scene apply` …
2. `scene validate` …
3. `scene diff` …

With batch: **one** `godot-cli batch --file … --json` call returns nested `data` for each step.

## See also

- [agent_scene_authoring.md](agent_scene_authoring.md) — patch ops, intents, undo
- [scene_authoring_roadmap.md](scene_authoring_roadmap.md) — Phase I features
