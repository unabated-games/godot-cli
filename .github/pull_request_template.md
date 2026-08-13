## What this changes

<!-- A sentence or two. Link the issue if there is one. -->

## Why

<!-- What problem this solves. For anything beyond a bug fix, link the issue where
the approach was agreed. -->

## How it was verified

<!-- Which of these you ran, and anything you checked by hand. -->

- [ ] `zig build test`
- [ ] `zig fmt --check src build.zig`
- [ ] `zig build test-godot` (if the change touches save format, IDs, or round-trip)
- [ ] Checked the output against a file Godot itself saved, where relevant

## Checklist

- [ ] Added or updated tests
- [ ] Updated `CHANGELOG.md` under `[Unreleased]` if this is user-facing
- [ ] Updated the agent docs / skill if command shapes or JSON output changed
- [ ] Recorded any newly ported third-party code in `THIRDPARTY.md`
