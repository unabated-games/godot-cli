---
title: godot-cli how-to guides
description: Task-focused guides for authoring scenes, cataloguing components, batching edits, and keeping coding agents on track.
---

# How-to guides

Each guide is a task with the commands to finish it. If you are new here, read [getting started]({{ base_url }}/getting-started/) first.

## Authoring

[Build a scene]({{ base_url }}/how-to/first-scene/): create a scene, add nodes and properties, work with sub-resources, and move nodes around without breaking the tree.

[Instance and override]({{ base_url }}/how-to/instance-and-override/): put one scene inside another, override exported values on the instance, and reach editable children when you must.

[Build UI]({{ base_url }}/how-to/build-ui/): Control trees with anchors, containers, theme overrides, and unique names, in the shape the editor writes them.

[Edit project settings]({{ base_url }}/how-to/project-settings/): the input map, autoloads, editor plugins, rendering and physics backends, and the main scene, all in `project.godot`.

## Working with agents

[Teach an agent your sub-scenes]({{ base_url }}/how-to/your-own-components/) is the one to read first. It walks the component catalog end to end, from describing a scene you have already built to an agent instancing it by id instead of rebuilding it from raw nodes.

[Set up an agent]({{ base_url }}/how-to/agent-setup/): install the skill, write project rules that keep an agent authoring scene files, and recognise the three ways it drifts back to building nodes in code.

## Editing at scale

[Batch edits with intents and patches]({{ base_url }}/how-to/batch-edits/): describe a whole change as JSON, preview it, apply it in one write, undo it.

[Review and validate changes]({{ base_url }}/how-to/review-changes/): what each validation error means, node and property diffs, snapshots, and what a human should still look at before committing a generated scene.

## Compatibility and scripting

[Stay byte-compatible with Godot]({{ base_url }}/how-to/godot-compatibility/): save preparation, id sessions, the UID cache, normalization, and comparing your output against a file the editor saved.

[Script godot-cli]({{ base_url }}/how-to/scripting/): the JSON envelope, exit codes, JSON requests, the `batch` runner, and shell completions.
