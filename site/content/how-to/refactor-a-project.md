---
title: Refactor an existing project
description: Pull a subtree into its own scene, move files without leaving stale res:// paths, rename and reparent nodes, and check the scripts that reach into what you moved.
---

# Refactor an existing project

Authoring a scene from nothing is the easy half. The harder half is the project
that already exists: a `main.tscn` that grew a HUD inside it, a script folder
that wants reorganising, a node whose name is wrong everywhere. Every one of
those edits has a way to go silently wrong, because a `.tscn` refers to things
by path and by id, and moving a file with `mv` leaves both dangling.

The rule for this whole page: **validate after every step**, and run the game at
the end. A refactor that validates clean at each step and runs clean at the end
is a refactor you can commit.

## Learn the scene first

```bash
godot-cli scene node list scenes/main.tscn --json
godot-cli scene inspect scenes/main.tscn --json
godot-cli scene connection list scenes/main.tscn --json
godot-cli scene refs scenes/main.tscn --project-root . --json
```

`node list` gives the tree with viewport paths, `inspect` the sections and their
ids, `connection list` the signal wiring, and `refs` every external path with
whether it resolves. Together they are the picture you need before touching
anything.

## Pull a subtree into its own scene

This is the editor's *Save Branch as Scene*, and it is the most common
refactor in a project that grew:

```bash
godot-cli scene extract scenes/main.tscn /root/Main/HUD \
  --output ui/hud.tscn --catalog-id ui/hud --project-root . --json
```

The subtree moves to the new file with its properties, its unique ids, the
resources it uses, and the connections that live entirely inside it, all
rewritten relative to the new root. The source scene gets an instance in its
place, so the tree looks the same when you open it. `--catalog-id` registers the
new scene in the component catalog at the same time, which is what makes an
agent instance it next time instead of rebuilding it.

Two things come back in `messages` and both deserve reading:

- **Dropped connections.** A connection from inside the subtree to a node
  outside it cannot survive the split as it was. `--retarget-dropped-connections`
  re-points it at the new scene's root instead of dropping it, and names the
  method that root now needs:

  ```text
  a connection was re-pointed at the new scene's root, which now needs
  `func _on_close_pressed()` in a script on res://ui/hud.tscn
  ```

  That gives a self-contained component. If you would rather the parent stay in
  charge, `--editable` leaves the instance open so you can connect straight to a
  node inside it afterwards.
- **Script references.** Lines in your GDScript that reach into the moved
  subtree by path, like `$Main/HUD/Score`, are listed with their file and line.
  They still parse; they just resolve to nothing now.

The catalog entry can be written in the same call, so a component pulled out of
an existing scene arrives as complete as one written deliberately:

```bash
godot-cli scene extract scenes/main.tscn /root/Main/HUD --output ui/hud.tscn \
  --catalog-id ui/hud --summary "Player HUD with health and score" \
  --tags ui,hud --when-to-use "Any in-game screen" \
  --when-not-to-use "Menus; use ui/menu" --project-root .
```

## Move a file without breaking it

Never `mv` a file a scene references. `project move` moves the file and
rewrites every `res://` reference to it across the project:

```bash
godot-cli project move --project-root . \
  --from scripts/player.gd --to scripts/hero.gd --json
```

It takes the `.uid` sidecar with the file and reports each scene it edited.
Godot's UID cache still maps the old path afterwards, so validation reports
`uid_path_mismatch` until an import refreshes it — `--import` does that as part
of the move, which is what makes "validate after every edit" hold for this step:

```bash
godot-cli project move --project-root . \
  --from scripts/player.gd --to scripts/hero.gd --import --rename-ids --json
```

`--rename-ids` re-seeds the `ext_resource` id from the new file name, so a
`Script_player` id stops naming a file called `hero.gd`. Godot's own `1_ab12c`
ids name no file and are left alone.

If a component folder moved and its catalog entry no longer points at the
scene, `catalog relink` finds it again and repairs the manifest.

## Rename and reparent

```bash
godot-cli scene node rename scenes/main.tscn /root/Main/Box --name Panel --project-root .
godot-cli scene node reparent scenes/main.tscn /root/Main/Panel --parent /root/Main/HUD --project-root .
```

Both rewrite the `parent=` attributes of every descendant, and `reparent` keeps
the node's unique id. What neither can do is fix a script that says
`$Main/Box`, so grep for the old name afterwards — the same class of breakage
`scene extract` reports for you.

## Take a snapshot you can roll back to

Any `scene apply` can record the inverse of what it did:

```bash
godot-cli scene apply scenes/main.tscn --patch refactor.json --project-root . \
  --write-undo-patch undo.json --auto-snapshot --json
```

`--write-undo-patch` gives you a patch that reverses the change, and
`--auto-snapshot` copies the file before writing. If an op fails, nothing is
written at all — the whole document is applied in one pass or not at all.

## Check the result

```bash
godot-cli scene validate scenes/main.tscn --project-root . --json
godot-cli scene validate ui/hud.tscn --project-root . --json
godot-cli scene diff before.tscn scenes/main.tscn --properties --json
godot-cli project run --project-root . --json
```

`validate` catches dangling references, duplicate ids, a property whose value
is the wrong type for its class, and a connection to a signal the emitting
class does not have. `diff` shows what actually changed, property by property.
The run is what proves the refactor did not change behaviour: same frame, same
log, no errors.

[Verify a change by running the game]({{ base_url }}/how-to/verify-a-change/)
covers that last step in full, including clicking a button to prove its wiring
still works after the move.
