---
title: godot-cli how-to guides
description: Task-focused guides for authoring scenes, cataloguing components, batching edits, and keeping coding agents on track.
---

# How-to guides

Each guide is a task with the commands to finish it. If you are new here, read [getting started]({{ base_url }}/getting-started/) first.

## Authoring

[Build a scene]({{ base_url }}/how-to/first-scene/) covers creating a scene, adding nodes and properties, working with sub-resources, and moving nodes around without breaking the tree.

[Instance and override]({{ base_url }}/how-to/instance-and-override/) covers putting one scene inside another, overriding exported values on the instance, and editable children.

[Build UI]({{ base_url }}/how-to/build-ui/) covers Control nodes, anchors and containers, theme overrides, and unique names, in the shape the editor writes them.

[Edit project settings]({{ base_url }}/how-to/project-settings/) covers `project.godot`: the input map, autoloads, editor plugins, rendering and physics backends, and the main scene.

## Working with agents

[Teach an agent your sub-scenes]({{ base_url }}/how-to/your-own-components/) is the step by step for the component catalog: describing a scene you have already built so an agent instances it instead of rebuilding it out of raw nodes.

[Set up an agent]({{ base_url }}/how-to/agent-setup/) covers installing the skill, writing project rules that keep an agent authoring scene files, and what to do when it drifts back to building nodes in code.

## Editing at scale

[Batch edits with intents and patches]({{ base_url }}/how-to/batch-edits/) covers describing a whole change as JSON, previewing it, applying it in one write, and undoing it.

[Review and validate changes]({{ base_url }}/how-to/review-changes/) covers validation errors, node-level and property-level diffs, snapshots, and what to check before committing a generated scene.

## Compatibility and scripting

[Stay byte-compatible with Godot]({{ base_url }}/how-to/godot-compatibility/) covers save preparation, id sessions, the UID cache, normalization, and comparing output against a file the editor saved.

[Script godot-cli]({{ base_url }}/how-to/scripting/) covers the JSON envelope, exit codes, JSON requests, the `batch` runner, and shell completions.
