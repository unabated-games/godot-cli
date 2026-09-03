# Getting started

godot-cli reads and writes Godot 4 text scenes (`.tscn`), resources (`.tres`),
and `project.godot`. This page covers installing it, authoring a first scene,
and pointing an agent at it.

The documentation site at <https://unabated-games.github.io/godot-cli/> carries
this guide plus how-to guides for the component catalog, batch edits, UI, and
agent setup.

- Every command takes `--json` and returns [one envelope](development_principles.md#json-output---json).
- Every command is listed in the [command reference](commands.md), or `man godot-cli`.

## Install

### From a release (no toolchain)

```bash
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
```

Downloads the archive for your platform, checks it against the release
`SHA256SUMS`, and installs into `~/.godot-cli`:

| Path | Contents |
|------|----------|
| `~/.godot-cli/bin/godot-cli` | Binary |
| `~/.godot-cli/templates/` | Built-in scene templates (`scene template copy`) |
| `~/.godot-cli/docs/` | Agent guides, command reference, `mcp_tools.json` |
| `~/.godot-cli/examples/` | Intent, patch, and batch JSON examples |
| `~/.godot-cli/share/completions/` | bash, zsh, and fish completions |
| `~/.godot-cli/share/man/man1/` | `godot-cli(1)` |
| `~/.godot-cli/skills/` | Bundled agent skill |
| `~/.godot-cli/env.sh` | Environment, `PATH`, `MANPATH`, completions |

Then activate it — add this to `~/.zshrc` or `~/.bashrc` to make it stick:

```bash
source "$HOME/.godot-cli/env.sh"
godot-cli --version
man godot-cli
```

Options worth knowing:

```bash
./install.sh --version 0.7.1     # pin a release
./install.sh --prefix /opt/godot-cli
./install.sh --install-skill     # also install the agent skill
```

### From source

Requires [Zig](https://ziglang.org/) 0.16.0 or later.

```bash
git clone https://github.com/unabated-games/godot-cli
cd godot-cli
zig build                # binary at zig-out/bin/godot-cli
./install.sh             # build and install to ~/.godot-cli
```

### Manual download

Every release publishes archives and a `SHA256SUMS` file. Verify before use:

```bash
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify godot-cli-<version>-<target>.tar.gz --repo unabated-games/godot-cli
tar -xzf godot-cli-<version>-<target>.tar.gz
```

| Platform | Archive |
|----------|---------|
| Linux x86_64 / aarch64 | `godot-cli-<version>-{x86_64,aarch64}-linux-musl.tar.gz` |
| macOS Intel / Apple Silicon | `godot-cli-<version>-{x86_64,aarch64}-macos.tar.gz` |
| Windows x86_64 / aarch64 | `godot-cli-<version>-{x86_64,aarch64}-windows.zip` |

The Linux binaries are statically linked against musl, so they run on any
distribution. Windows has no `install.sh`; unpack the zip and put `bin\` on
`PATH`.

## Author a scene

Everything below runs inside a Godot project directory — the one holding
`project.godot`.

```bash
godot-cli scene new --output level.tscn --root-name Level --root-type Node2D
godot-cli scene node add level.tscn --parent /root/Level --name Player --type CharacterBody2D
```

Nodes take properties directly, and sub-resources can be created and referenced
in the same pass:

```bash
shape_id=$(godot-cli scene sub add level.tscn --type CapsuleShape2D \
  --property radius --value 16.0 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])')

godot-cli scene node add level.tscn --parent /root/Level/Player --name Collision \
  --type CollisionShape2D --property shape --value "SubResource(\"$shape_id\")"
```

Instancing another scene adds the `ext_resource` and the `instance=` reference
together — this is the operation LLMs most often get wrong by hand:

```bash
godot-cli scene instance add level.tscn --parent /root/Level \
  --scene res://ui/hud.tscn --name HUD --project-root .
```

Then read it back and check it:

```bash
godot-cli scene node list level.tscn --json
godot-cli scene validate level.tscn --project-root . --json   # exit 1 on errors
godot-cli scene inspect level.tscn --json                     # sections and parsed properties
```

The result is an ordinary scene file. Open it in Godot and the tree is there —
no runtime `instantiate()`, no hand-edited text.

### Declarative editing

For anything longer than a couple of edits, describe the change once and apply
it in a single write, with a diff and an undo patch:

```bash
godot-cli scene apply level.tscn --intent intent.json --project-root . \
  --write-undo-patch undo.json --json
godot-cli scene diff before.tscn level.tscn --properties --json
godot-cli scene apply level.tscn --patch undo.json --project-root .   # roll back
```

Intent and patch formats are documented in
[agent scene authoring](agent_scene_authoring.md); ready-made examples ship in
`~/.godot-cli/examples/`.

## When to pass `--project-root`

`--project-root` is what lets godot-cli resolve `res://` paths, read
`.godot/uid_cache.bin`, look up catalog ids, and seed Godot-compatible resource
ids on save.

| Commands | `--project-root` |
|----------|------------------|
| Writes (`scene new`, `node *`, `instance add`, `apply`, `set-property`), all `catalog *`, all `project *` | Pass it |
| `scene validate`, `scene inspect`, `scene refs` | Pass it to enable `res://` and UID checks |
| `scene node list`, `scene node get`, `scene diff` | Optional; accepted and ignored |

## Project settings

`project.godot` is editable through the same envelope — input actions,
autoloads, plugins, rendering, and physics:

```bash
godot-cli project show --project-root . --json
godot-cli project settings set --project-root . \
  --section application --key run/main_scene --value res://level.tscn
godot-cli project apply --project-root . --intent examples/intents/project_bootstrap.json
```

## Set up an agent

```bash
./install.sh --install-skill    # Cursor, Claude Code, OpenCode, ~/.agents
```

Point the agent at [`agent_quickstart.md`](agent_quickstart.md) — one page
covering the workflow, when to pass `--project-root`, and the anti-patterns to
avoid. For tools that wrap the CLI, [`mcp_tools.json`](mcp_tools.json) carries a
request shape per command, and `godot-cli reference --format json` emits the
whole command surface as data.

## Next

- [Command reference](commands.md) — every command and option
- [About godot-cli](ABOUT.md) — what it is and what it is deliberately not
- [Agent scene authoring](agent_scene_authoring.md) — recipes and patch format
- [Catalog design](catalog_design.md) — describing project components to agents
