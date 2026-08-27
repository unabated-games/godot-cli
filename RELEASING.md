# Releasing

A release is one tag push. Everything after that — building six targets,
packaging, checksums, notes, provenance, publishing — happens in
[`.github/workflows/release.yml`](.github/workflows/release.yml).

## Cut a release

1. **Pick the version.** [Semantic versioning](https://semver.org): new commands
   or options are a minor bump, fixes are a patch.

2. **Bump the version and its date** in [`build.zig`](build.zig):

   ```zig
   const version_string = ... orelse "0.2.0";
   const version_date = ... orelse "2026-08-28";
   ```

   The date is the release date; it appears in the man page header. It is a
   constant rather than a clock read so that generated files stay byte-stable
   and `zig build docs-check` means something.

3. **Update the changelog.** Rename `## [Unreleased]` to `## [X.Y.Z] — YYYY-MM-DD`
   and open a fresh empty `## [Unreleased]` above it. This section becomes the
   release notes verbatim, so write it for people reading the release page.

4. **Update the tool catalog version** in [`docs/mcp_tools.json`](docs/mcp_tools.json)
   to match. `tools/check_mcp_tools.sh` fails if it drifts.

5. **Regenerate and verify:**

   ```bash
   zig build docs          # reference, man page, completions carry the new version
   zig build test
   zig build test-godot    # needs Godot 4.7
   tools/check_mcp_tools.sh
   ```

6. **Commit** the version bump, changelog, and regenerated files together.

7. **Tag and push:**

   ```bash
   git tag v0.2.0
   git push origin main
   git push origin v0.2.0
   ```

## What the workflow does

| Step | Result |
|------|--------|
| Build | `ReleaseFast` for x86_64 and aarch64 across Linux (musl), macOS, and Windows |
| Package | Binary, templates, agent docs, command reference, examples, completions, man page, skill, licences, and `install.sh`, laid out like the repository |
| Checksums | One `SHA256SUMS` covering every archive |
| Notes | The CHANGELOG section for the tag, plus install and verification instructions |
| Attest | Build provenance for each archive (`gh attestation verify`) |
| Publish | A published release — not a draft |

## After publishing

```bash
gh release view v0.2.0
curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
godot-cli --version
```

The installer resolves the latest tag, downloads the archive for the running
platform, and verifies it against `SHA256SUMS` — so this also confirms the
checksums published correctly.

## Notes

- **Provenance needs a public repository.** The attestation step is
  `continue-on-error` so a private repository still publishes; the release just
  has nothing to verify against.
- **A tag can be rebuilt** with the `workflow_dispatch` trigger and an explicit
  version, which builds and uploads artifacts without publishing a release.
- **Nothing is published from a branch.** The release job is gated on
  `refs/tags/v*`.
