# Documentation

## Using godot-cli

| Doc | What it covers |
|-----|----------------|
| [Getting started](getting_started.md) | Install, first scene, `--project-root`, agent setup |
| [Command reference](commands.md) | Every command, option, and exit code — generated from the command tree |
| [About godot-cli](ABOUT.md) | What it is, why it exists, what it is deliberately not |

## Working with agents

| Doc | What it covers |
|-----|----------------|
| [Agent quickstart](agent_quickstart.md) | One page: rules, workflow, cheat sheet |
| [Open asks](BACKLOG.md) | What the agent trials and maintainers have asked for that is not yet built |
| [Godot basics for agents](agent_godot_basics.md) | Projects, scenes, Control layout, running the game |
| [Agent scene authoring](agent_scene_authoring.md) | Recipes, patch and intent formats, UI authoring |
| [Agent batch commands](agent_batch_commands.md) | Multi-step workflows in one invocation |
| [`mcp_tools.json`](mcp_tools.json) | JSON request shape for every command |

`godot-cli reference --format json` emits the same command surface as data, for
tools that generate their own bindings.

## Design and contracts

| Doc | What it covers |
|-----|----------------|
| [Development principles](development_principles.md) | Argv/JSON parity, result envelope, exit codes, naming |
| [Catalog design](catalog_design.md) | Manifest format and how agents choose components |
| [ID generation plan](id_generation_plan.md) | Godot's ID systems and the phases that implemented them |
| [Scene authoring roadmap](scene_authoring_roadmap.md) | The LLM-first authoring plan, phase by phase |
| [Mini roadmap](mini_roadmap.md) | Post-phase-6 backlog and what shipped |

## Repository

| Doc | What it covers |
|-----|----------------|
| [Contributing](../CONTRIBUTING.md) | Setup, CI, conventions for new commands |
| [Releasing](../RELEASING.md) | How a release is cut and what it publishes |
| [Changelog](../CHANGELOG.md) | What changed in each version |
| [Security](../SECURITY.md) | Reporting a vulnerability |
