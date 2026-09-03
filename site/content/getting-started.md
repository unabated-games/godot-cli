---
title: Getting started with godot-cli
description: Install godot-cli, author a scene from the command line, and learn when to pass --project-root.
---

# Getting started

godot-cli works on Godot 4 text scenes (`.tscn`), resources (`.tres`), and `project.godot`. It does not need the editor running, and it does not need a Godot install unless you want to run the round-trip suite.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
source "$HOME/.godot-cli/env.sh"
godot-cli --version
```

The installer downloads the release archive for your platform, checks it against the release `SHA256SUMS`, and refuses to install if the two disagree. Everything lands in `~/.godot-cli`:

| Path | Contents |
|------|----------|
| `bin/godot-cli` | The binary |
| `templates/` | Built-in scene templates for `scene template copy` |
| `docs/` | Agent guides, command reference, `mcp_tools.json` |
| `examples/` | Intent, patch, and batch JSON you can copy |
| `share/completions/` | bash, zsh, and fish completions |
| `share/man/man1/` | `godot-cli(1)`, so `man godot-cli` works |
| `env.sh` | Sets `PATH`, `MANPATH`, and loads completions |

Add the `source` line to `~/.zshrc` or `~/.bashrc` to keep it.

To pin a version, pass `--version 0.9.0`. To install somewhere else, pass `--prefix /opt/godot-cli`. From a checkout, `./install.sh` builds with Zig 0.16 instead of downloading.

Windows has no installer script. Unpack the `.zip` from the [releases page](https://github.com/unabated-games/godot-cli/releases) and put `bin\` on `PATH`.

## Author a scene

Run these from a Godot project directory, the one holding `project.godot`. From an empty folder, `project new` writes that file the way the project manager would, with the name, the main scene, and the window size:

```bash
godot-cli project new --name MyGame --main-scene res://level.tscn --width 640 --height 360
godot-cli scene new --output level.tscn --root-name Level --root-type Node2D
godot-cli scene node add level.tscn --parent /root/Level --name Player --type CharacterBody2D
```

Nodes are addressed by viewport path (`/root/Level/Player`), not by line number or section index. Renaming or reparenting a node rewrites the `parent` attribute on every descendant, which is the part that goes wrong when a scene is edited by hand.

Sub-resources work the same way. Create one, then reference its id:

```bash
shape=$(godot-cli scene sub add level.tscn --type CapsuleShape2D --property radius --value 16.0 --json \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')

godot-cli scene node add level.tscn --parent /root/Level/Player --name Collision \
  --type CollisionShape2D --property shape --value "SubResource(\"$shape\")"
```

Instancing another scene writes the `ext_resource` entry and the `instance=` node together:

```bash
godot-cli scene instance add level.tscn --parent /root/Level \
  --scene res://ui/hud.tscn --name HUD --project-root .
```

Read it back with `scene node list` for the tree, `scene inspect` for sections and parsed property values, and `scene validate` to check ids, ordering, and `res://` references:

```bash
godot-cli scene node list level.tscn --json
godot-cli scene validate level.tscn --project-root . --json   # exits 1 when there are errors
```

The file that comes out is an ordinary scene. Open the project in Godot and the tree is there, with nothing to import or convert.

## When to pass --project-root

`--project-root` is how godot-cli resolves `res://` paths, reads `.godot/uid_cache.bin`, looks up catalog ids, and seeds resource ids to match what Godot would write.

| Commands | Pass it? |
|----------|----------|
| Writes: `scene new`, `node *`, `instance add`, `apply`, `set-property` | Yes |
| All `catalog *` and all `project *` | Yes |
| `scene validate`, `scene inspect`, `scene refs` | Yes, to enable `res://` and UID checks |
| `scene node list`, `scene node get`, `scene diff` | Optional, accepted and ignored |

## Every command speaks JSON

Add `--json` and stdout carries one document: `ok`, `version`, `command`, `data`, `messages`, and `failure`. Exit codes are 0 for success, 1 for a runtime failure, and 2 for a usage error.

The same commands can be driven as JSON instead of argv:

```bash
godot-cli --json --request '{"argv": ["scene", "node", "list", "level.tscn"]}'
```

Or served over MCP, one tool per command, with `godot-cli mcp --project-root .`. [Set up an agent]({{ base_url }}/how-to/agent-setup/) has the config for Claude Code, Cursor, and OpenCode.

## Next

[Build a scene]({{ base_url }}/how-to/first-scene/) covers the authoring commands in depth. [Teach an agent your sub-scenes]({{ base_url }}/how-to/your-own-components/) is the guide worth reading before pointing any coding agent at a project.
