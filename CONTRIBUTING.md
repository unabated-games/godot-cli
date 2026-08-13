# Contributing to godot-cli

Thanks for your interest. This is a small project maintained by
[Unabated Games](https://github.com/unabated-games); issues and pull requests are
welcome.

## Before you start

For anything larger than a bug fix, please open an issue first so we can agree on
the approach. The project has a specific philosophy — see
[docs/ABOUT.md](docs/ABOUT.md) and
[docs/development_principles.md](docs/development_principles.md) — and a change
that cuts against it is a hard review even when the code is good.

The one rule worth stating up front: **scenes are authored the way a human would
author them in the editor**, persisted in `.tscn`. Features that encourage runtime
`load().instantiate()` for static structure are out of scope.

## Development setup

You need [Zig](https://ziglang.org/) 0.16.0 or later. Nothing else is required for
the unit tests.

```bash
zig build              # build to zig-out/bin/godot-cli
zig build test         # unit tests + CLI smoke tests
zig fmt src build.zig  # format
```

The Godot round-trip suite needs a Godot 4.7 install:

```bash
zig build test-godot                     # default macOS path
zig build test-godot -Dgodot=/path/to/Godot
```

## What CI checks

Every push and pull request runs:

- `zig fmt --check src build.zig`
- `zig build test` on Linux and macOS
- a cross-compile of every supported target (Linux gnu/musl, macOS, Windows, on
  both x86_64 and aarch64)

The cross-compile job exists because host-only APIs are easy to introduce by
accident and break every non-macOS user. If you reach for something in `std.c`,
expect that job to tell you about it.

`zig build test-godot` runs on pushes to `main`, not on pull requests, because it
downloads the editor.

## Coding conventions

- Run `zig fmt` before committing. CI will fail otherwise.
- The CLI process uses an arena allocator, so command handlers can allocate
  freely. Library code under `src/godot/` should not assume an arena: free what
  you allocate, and document any function that hands back an arena-owned tree.
- Prefer returning errors to `@panic` in anything reachable from the
  `godot_cli_tools` module — it is exported for embedding.
- New commands follow the conventions in
  [docs/development_principles.md](docs/development_principles.md): argv and JSON
  parity, a stable result envelope, and `--json` output for every command.
- Add tests. Parsers and format logic get unit tests; commands get a smoke test in
  `build.zig` alongside the existing ones.

## Changelog

User-facing changes go under `[Unreleased]` in
[CHANGELOG.md](CHANGELOG.md), in the appropriate section. That includes changes to
agent docs, skills, install behaviour, and error shapes — anything an LLM workflow
or a script could notice.

## Third-party code

Parts of this project are ported from the Godot Engine and from PCG, under their
own licenses. If you port more code from an upstream project, record it in
[THIRDPARTY.md](THIRDPARTY.md) with the source file and its license, and add the
attribution header to the Zig file.

## Licensing of contributions

By contributing, you agree that your contributions are licensed under the MIT
License, the same terms that cover the project (see [LICENSE](LICENSE)).
