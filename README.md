# godot-cli

[![CI](https://github.com/unabated-games/godot-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/unabated-games/godot-cli/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/unabated-games/godot-cli?sort=semver)](https://github.com/unabated-games/godot-cli/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Godot 4.7](https://img.shields.io/badge/godot-4.7-478cbf.svg)](https://godotengine.org/)
[![Zig 0.16](https://img.shields.io/badge/zig-0.16-f7a41d.svg)](https://ziglang.org/)

Read, edit, and author Godot scene and resource files from the command line,
without launching the editor.

Documentation: **[unabated-games.github.io/godot-cli](https://unabated-games.github.io/godot-cli/)**

godot-cli parses `.tscn`, `.tres`, and `project.godot` into a document model,
understands Godot's identifier systems and Variant text, and writes files back
the way the editor writes them. Output is verified byte-for-byte against saves
the Godot editor itself produced.

Every command works from argv or from a JSON request, and returns the same JSON
envelope — so it reads the same to a person at a terminal, a CI script, or an
LLM agent.

```bash
$ godot-cli scene new --output level.tscn --root-name Level --root-type Node2D
$ godot-cli scene node add level.tscn --parent /root/Level --name Player --type CharacterBody2D
$ godot-cli scene instance add level.tscn --parent /root/Level --scene res://ui/hud.tscn --name HUD
$ godot-cli scene validate level.tscn --project-root . --json
{"ok":true,"version":"0.4.0","command":["scene","validate"],"data":{"path":"level.tscn","issues":[]},...}
```

That scene is a normal Godot scene: the hierarchy lives in the file, the way a
human would have built it in the editor. No `_ready()` spawning, no hand-edited
scene text.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
source "$HOME/.godot-cli/env.sh"
godot-cli --version
```

Installs the binary, scene templates, agent docs and examples, shell
completions, and the man page into `~/.godot-cli`. No toolchain needed — it
downloads the release archive for your platform and verifies it against the
release checksums.

From a checkout instead:

```bash
zig build                 # binary at zig-out/bin/godot-cli
./install.sh              # build, then install to ~/.godot-cli
```

Releases ship Linux (musl), macOS, and Windows binaries for x86_64 and aarch64.
See [Getting started](docs/getting_started.md) for the full install matrix,
agent setup, and a first-scene walkthrough.

## What it does

| Layer | Commands |
|-------|----------|
| **Godot ID primitives** | `uid encode`/`decode`, `uid create-for-path`, scene-local ids, `.godot/uid_cache.bin` reads, id sessions |
| **Read** | `scene inspect`, `resource inspect`, `scene node list`/`get`, parsed Variant values with types |
| **Validate** | `scene validate`, `validate-batch`, `compare-godot`, `round-trip` |
| **Edit and author** | `scene new`, `node add`/`remove`/`rename`/`reparent`, `ext add`, `sub add`, `instance add`, `set-property`, `normalize`, `retarget-ext` |
| **Declarative editing** | `scene plan`, `scene apply --intent`/`--patch`, `scene diff`, `scene restore`, `batch` |
| **Project settings** | `project show`/`apply`, `input`, `settings`, `autoload`, `plugins`, `rendering`, `physics` |
| **Component catalog** | `catalog add`, `scan`, `list`, `show`, `validate`, `search`, `export`, `relink` |

Full detail, option by option: **[Command reference](docs/commands.md)** — or
`man godot-cli` after install.

## For LLM agents

The scene-authoring surface exists because agents are bad at editing `.tscn`
text and reach for runtime `load().instantiate()` instead. godot-cli gives them
tree operations, structured errors, and a component catalog describing which
scene to instance and when.

```bash
./install.sh --install-skill   # skill for Cursor, Claude Code, OpenCode, ~/.agents
```

- [Agent quickstart](docs/agent_quickstart.md) — one page, the whole workflow
- [Agent scene authoring](docs/agent_scene_authoring.md) — recipes, patch and intent format, anti-patterns
- [Agent batch commands](docs/agent_batch_commands.md) — multi-step workflows in one invocation
- [`docs/mcp_tools.json`](docs/mcp_tools.json) — JSON request shape for every command
- `godot-cli reference --format json` — the whole command surface as data

## Documentation

The full documentation site is at
[unabated-games.github.io/godot-cli](https://unabated-games.github.io/godot-cli/),
including how-to guides for scene authoring, the component catalog, batch edits,
and agent setup.

| Doc | What it covers |
|-----|----------------|
| [Getting started](docs/getting_started.md) | Install, first scene, agent setup |
| [Command reference](docs/commands.md) | Every command, option, and exit code (generated) |
| [About godot-cli](docs/ABOUT.md) | What it is, why it exists, what it is not |
| [Development principles](docs/development_principles.md) | CLI and JSON contracts every command follows |
| [Documentation index](docs/README.md) | Everything else, including design docs and roadmaps |

## Status

Early development, released under [semantic versioning](CHANGELOG.md). The file
format work — ID generation, UID cache, Variant parsing, save round-trip — is
verified against **Godot 4.7** in unit tests and in a suite that compares
godot-cli's output byte-for-byte against files the editor saved.

Scene authoring, the component catalog, `project.godot` editing, and batch
workflows are all implemented; see the
[scene authoring roadmap](docs/scene_authoring_roadmap.md) for how they fit
together.

## Building

Requires [Zig](https://ziglang.org/) 0.16.0 or later. Godot 4.7 is needed only
for the round-trip suite.

```bash
zig build                # binary at zig-out/bin/godot-cli
zig build test           # unit tests + CLI smoke tests
zig build test-godot     # round-trip against a real Godot save (-Dgodot=/path)
zig build docs           # regenerate command reference, man page, completions
```

[CONTRIBUTING.md](CONTRIBUTING.md) covers the development setup, what CI checks,
and the conventions new commands follow. Participation is covered by our
[Code of Conduct](CODE_OF_CONDUCT.md); to report a security issue, see
[SECURITY.md](SECURITY.md). Releases follow [RELEASING.md](RELEASING.md).

## License

MIT, copyright © 2026 [Unabated Games](https://github.com/unabated-games) — see
[LICENSE](LICENSE).

Contains code ported from the Godot Engine (MIT) and from PCG (Apache-2.0).
Those notices, and what was changed, are recorded in
[THIRDPARTY.md](THIRDPARTY.md); the Apache-2.0 text is at
[`third_party/licenses/`](third_party/licenses/).

"Godot" and the Godot Engine logo are trademarks of the Godot Foundation. This
project is not affiliated with, endorsed by, or sponsored by the Godot
Foundation or the Godot Engine project.
