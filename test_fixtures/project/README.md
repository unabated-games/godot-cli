# Test fixture project

Minimal Godot project used by godot-cli unit and smoke tests.

## Scene authoring principle

**Agents should author scenes like humans in the editor** — nodes and instances saved in `.tscn` via godot-cli (`scene node add`, `scene instance add`, etc.). See [ABOUT.md](../../docs/ABOUT.md#north-star-editor-like-scene-authoring).

Do **not** use runtime `load().instantiate()` in game scripts for static UI or level structure. That is the anti-pattern godot-cli exists to replace.

## Godot scripts in this folder

| Script | Purpose |
|--------|---------|
| `save_rich_fixtures.gd` | Headless **test harness** — saves Godot reference files for variant round-trip tests |

These scripts are **not** examples for agents or game code. They only exist because sometimes we need a byte-accurate Godot save to compare against. Production authoring uses godot-cli scene commands or the Godot editor.

## Key fixtures

- `ui/button/` — catalog manifest + instancable button scene
- `instanced_child*.tscn` — PackedScene instance reference format
- `*_godot_saved.*` — golden files from Godot editor or headless save scripts
