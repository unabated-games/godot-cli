---
title: Set up export presets from the command line
description: Create and edit the presets in export_presets.cfg the way the editor writes them, keep secrets out of the committed file, and run the export.
---

# Set up export presets

Godot keeps export presets in `export_presets.cfg`, at the project root, and their secrets (keystore passwords, the script encryption key) in `.godot/export_credentials.cfg`, which is not committed. Neither file is pleasant to edit by hand. The editor writes every option a platform has, often two hundred of them, and three mistakes lose a preset without any warning:

- A `platform` Godot does not match exactly. Windows is `Windows Desktop`, not `Windows`. Godot skips the preset when it loads the file, and drops it the next time it saves.
- A gap in the numbering. Godot reads `preset.0`, `preset.1`, and so on, and stops at the first one missing.
- A secret written into `export_presets.cfg`. It then gets committed with everything else.

`godot-cli project export` writes both files exactly as the editor does. It checks every value against the options the platform actually has.

## See what there is

```bash
godot-cli project export list --project-root . --json
```

Each preset comes back with its name, platform, whether it is the runnable one for its platform, its `export_path` and filters, and the options that differ from the default. Secret values are never shown, only whether they are set. `project export show --preset Windows --all-options` lists every option.

## Find an option's name

Option names are per platform. They are defined in the engine's C++ and are not in Godot's class reference.

```bash
godot-cli project export options --project-root . --platform Android --filter keystore --json
```

Each option comes with its default and type. An option with a fixed set of values lists its `choices`, and a secret option is marked `secret`.

## Create or change presets

```bash
godot-cli project export apply --project-root . --json --intent-json '{
  "presets": [
    {"name": "Windows", "platform": "Windows Desktop", "runnable": true,
     "export_path": "build/windows/game.exe",
     "options": {"binary_format/embed_pck": true, "application/product_name": "My Game"}},
    {"name": "Web", "platform": "Web", "export_path": "build/web/index.html",
     "exclude_filter": ["*.md", "docs/*"]}
  ]
}'
```

A preset is matched by `name`. If none matches, a new one is created, which needs a `platform`: one of `Android`, `iOS`, `Linux`, `macOS`, `visionOS`, `Web` and `Windows Desktop`. `Windows`, `HTML5` and other common names are accepted too, and written as the name Godot matches. The command says when it did that.

What a preset entry takes:

| Field | What it is |
|-------|------------|
| `export_path` | Where `project export build` and `godot --export-release` write, relative to the project |
| `runnable` | The preset one-click deploy uses; one per platform |
| `export_filter` | `all_resources`, `scenes`, `resources`, `exclude`, or `customized`, with `export_files` for the middle three |
| `include_filter`, `exclude_filter` | Non-resource files to add, and files to leave out; a string or a list |
| `custom_features` | Feature tags for `OS.has_feature()`; a string or a list |
| `script_export_mode` | `text`, `binary_tokens`, or `compressed_binary_tokens` |
| `options` | Platform options by name, from `project export options` |
| `rename` | A new name for the preset |

The patch and encryption keys, `dedicated_server` and `script_encryption_key` are accepted too. `"remove": ["Old preset"]` deletes a preset, and the presets after it are renumbered.

Values are typed by the option. A boolean option takes `true`, a number option takes a number, and a list takes a JSON array. An option with fixed choices takes the label the editor shows, so `"gradle_build/export_format": "AAB"` is written as `1`. A wrong type, a value outside the choices, or a misspelled option is refused before anything is written. A misspelling comes back with the nearest real name. An option that comes from an addon rather than the engine needs `"allow_unknown_options": true` on its preset.

An `export_path` inside the project, such as `build/windows/game.exe`, gets an empty `.gdignore` in its top folder (`build/`). Without one, Godot imports whatever it finds there as project files, and an `all_resources` export packs the previous build into the next one.

Whatever you set, the whole preset is written: every option the platform has, in the editor's order, with its default where you set nothing. Opening the project in the editor then changes nothing. Secret options go to `.godot/export_credentials.cfg`, and the result lists them by name, never by value. Because that file is not committed, set the secrets again on each machine, or in CI. When there is no `.gitignore` that ignores `.godot/`, the command says so: a `git add .` would commit the secrets.

## Check the file

```bash
godot-cli project export validate --project-root . --json
```

These are errors:

- a platform Godot does not know
- a gap in the numbering
- two presets with the same name
- an option value of the wrong type, or outside its choices
- an Android setting that only works with `gradle_build/use_gradle_build` on, such as an AAB, which Godot refuses to export

These are warnings:

- a missing `include_filter` or `exclude_filter`, which makes Godot log an error every time it loads the presets
- no `export_path`
- an `export_path` in a project folder with no `.gdignore`
- a keystore or custom template that does not exist on this machine (it may exist where releases are signed)
- an option the platform does not have
- a secret in the committed file
- a `res://` path that does not exist
- a runnable entry that names no preset

`matches_editor_save` says whether the editor would leave the file alone. A hand-written preset with only a few options still exports, but the editor fills in the rest the next time it saves. `project export apply --intent-json '{}'` writes that now.

## Export

```bash
godot-cli project export build --project-root . --preset Windows --json
```

This runs `godot --headless --export-release` with the preset. It creates the output folder, and its `.gdignore`, first, and lists each file written and its size. When Godot refuses, `errors` holds its reasons. Those come on the lines after the `ERROR:` header, such as a missing keystore or an Android SDK path not set in the editor's settings. `--debug` uses the debug template, `--pack` writes only the `.pck` or `.zip`, and `--output` overrides `export_path`.

Exporting needs Godot's export templates for the exact engine version. Without them the command fails as `export_templates_missing`, with `missing_template` naming the file Godot looked for. Install them from the editor (Editor > Manage Export Templates), or unpack the `.tpz` from the same Godot release into the folder that path names.

## Which Godot version

Each Godot version has a slightly different set of export options. godot-cli carries the list from each supported editor, and reads the version from `config/features` in `project.godot`. A project the editor has never opened names no version. Those projects get the newest list, and an older editor keeps the options it does not know.
