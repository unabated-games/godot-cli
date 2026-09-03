---
title: Set up a coding agent to author Godot scenes
description: Install the skill or the MCP server, write project rules that keep an agent editing scene files, and recover when it drifts back to building nodes in code.
---

# Set up an agent

Coding agents are good at GDScript and bad at `.tscn`. Left alone, a request for a pause menu comes back as a script that builds the menu at runtime, because that is the shape of most Godot examples online and because scene text is hard to write blind.

Three things change that. The tool turns scene edits into commands. The rules tell the agent which shape you want. The catalog tells it what you have already built, so it has something to reuse.

## 1. Install the CLI and the skill

```bash
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
source "$HOME/.godot-cli/env.sh"
install.sh --install-skill
```

The skill lands in `~/.cursor/skills/`, `~/.claude/skills/`, `~/.config/opencode/skills/`, and `~/.agents/skills/`, all as `godot-scene-authoring`. It carries the workflow checklist, the command cheat sheet, and the anti-patterns. Refresh it after an upgrade with `install.sh --skills-only`.

Point agents at `$GODOT_CLI_HOME`, never at a source checkout. The guides they need are installed at `$GODOT_CLI_HOME/docs/`: `agent_quickstart.md` (one page), `agent_godot_basics.md`, `agent_scene_authoring.md`, and `agent_batch_commands.md`, with copy-paste intents in `$GODOT_CLI_HOME/examples/`.

## 2. Write the project rules

Put these in whatever file your harness reads: `AGENTS.md` for Codex and OpenCode, `CLAUDE.md` for Claude Code, a file under `.cursor/rules/` for Cursor. The wording that works is specific about the tool, the order, and the exception:

```markdown
## Scene authoring

Use godot-cli for every change to .tscn, .tres, and project.godot. Do not
hand-edit scene text.

Work from the project root and pass --json. Pass --project-root . for writes,
catalog lookups, validation, and apply.

Before adding UI or level structure, check what already exists:
  godot-cli catalog list --project-root . --json
  godot-cli catalog show <id> --project-root . --json

Reuse a project component by instancing it:
  godot-cli scene instance add <scene> --parent <path> --name <Name> \
    --catalog-id <id> --project-root .

Static structure lives in the scene file. add_child(load(...).instantiate())
in _ready() is only for objects the game spawns during play, such as
projectiles, enemy waves, or pooled effects. Menus, HUDs, and level layout are
scene content.

Presentation lives on nodes as theme_override_* and layout properties, not in
_ready() styling calls.

Connect signals in the scene, not in _ready():
  godot-cli scene connection add <scene> --from <emitter path> --signal <name> \
    --to <receiver path> --method <method> --project-root .

Finish every change with:
  godot-cli scene validate <scene> --project-root . --json
  godot-cli scene node list <scene> --json
```

Add the [Godot basics]({{ base_url }}/how-to/godot-basics/) to the same file if the agent is new to Godot; the layout mistakes in the trials came from not knowing them, not from ignoring the rules.

## 3. Give it your components

Rules tell an agent how to build. The catalog tells it what not to rebuild. That workflow has its own guide: [teach an agent your sub-scenes]({{ base_url }}/how-to/your-own-components/).

The short version is one command per component and one export into the rules file:

```bash
godot-cli catalog add res://ui/health_bar/health_bar.tscn --project-root . \
  --id ui/health_bar --summary "Health bar with a label, used in the HUD" --tags ui,hud
godot-cli catalog export --project-root . --output AGENTS.md
```

## 4. Check the work, not the transcript

An agent that says it added a HUD may have added a script that adds a HUD. The file answers it:

```bash
godot-cli scene node list scenes/main.tscn --json
```

If the HUD nodes are in that list, the scene contains the HUD. If the list is short and a script grew, the structure is being built at runtime. [Review and validate changes]({{ base_url }}/how-to/review-changes/) covers the rest of the review.

## When it drifts back to building nodes in code

This usually has one of four causes, and each has a fix.

The component was not in the catalog, so the agent had nothing to instance and fell back to what it knows. Add a manifest and re-export the digest.

The rules never said which shape you wanted. "Use godot-cli" alone is not enough, because instancing at runtime through `load()` is still using Godot. The rule has to name the anti-pattern and its one legitimate use, as in the block above.

The thing it needed had no scene-level form. Until 0.4.0 that was true of signal connections, and the trial that found it produced exactly this: a correct scene plus a `_ready()` that connected the button. If an agent keeps writing runtime code for one specific thing, check whether the tool can express it at all before blaming the rules.

The agent hit an error and worked around it. This is worth reading the transcript for: a failed `scene instance add` followed by a GDScript workaround usually means a missing `--project-root`, or a `res://` path that does not exist. `scene refs --project-root .` lists every external path in a scene and whether it resolves.

## Serve it over MCP instead of a shell

Some harnesses would rather call a tool than run a command. `godot-cli mcp` serves the whole command tree over the Model Context Protocol on stdin and stdout: one tool per command, named the way `mcp_tools.json` names them, with an input schema built from the command's options and arguments. A call returns the same JSON envelope the shell prints, once as text and once as structured content, so a failure still carries the field and value to fix.

Start it with the project pinned:

```bash
godot-cli mcp --project-root .
```

In that mode the server adds `--project-root .` to every call that accepts it, drops the option from the schemas so the agent cannot get it wrong, and refuses any path argument that resolves outside the project before the command runs.

Claude Code takes the command line directly, or the same shape in `.mcp.json` at the project root:

```bash
claude mcp add godot-cli -- godot-cli mcp --project-root .
```

Cursor reads `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "godot-cli": {
      "type": "stdio",
      "command": "godot-cli",
      "args": ["mcp", "--project-root", "."]
    }
  }
}
```

OpenCode reads `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "godot-cli": {
      "type": "local",
      "command": ["godot-cli", "mcp", "--project-root", "."],
      "enabled": true
    }
  }
}
```

The agent docs travel with the server as resources, so an agent that has never seen `$GODOT_CLI_HOME` can still read `godot-cli://docs/quickstart` and `godot-cli://docs/godot-basics`, and `godot-cli://catalog` is the live catalog of the pinned project. The `godot-scene-session` prompt opens a session with the same seven rules the skill carries; in Claude Code it appears as a slash command under the server's name. Install the skill as well where the client supports it. The two say the same thing, and a rule the agent reads twice is a rule it keeps.

The server speaks both protocol eras: the `initialize` handshake current clients send, and the stateless 2026-07-28 revision for clients that move to it.

For anything that wraps the CLI its own way, every command also works as a JSON request:

```bash
godot-cli --json --request '{"argv": ["scene", "node", "list", "scenes/main.tscn"]}'
```

`godot-cli reference --format json` prints the whole command surface, every command, option, argument, and value kind, for generating bindings.
