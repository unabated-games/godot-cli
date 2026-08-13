# Security Policy

## Supported versions

godot-cli is in early development. Only the latest release on `main` receives
fixes; there are no maintained release branches yet.

## Reporting a vulnerability

Please report security issues privately rather than opening a public issue.

Use GitHub's private vulnerability reporting: go to the repository's **Security**
tab and choose **Report a vulnerability**. That opens a private thread visible
only to the maintainers.

Please include:

- what the issue is and how it can be triggered
- the godot-cli version (`godot-cli --version`) and your OS
- a scene, resource, or project file that reproduces it, if one is needed

We will acknowledge the report and let you know whether we consider it a
vulnerability and what the fix timeline looks like. Please give us a reasonable
window to ship a fix before disclosing publicly.

## Threat model

godot-cli is a local command-line tool. It reads and writes files you point it at,
under your own user account. It does not run as a service, does not open network
connections, and does not execute code from the files it parses.

The realistic concerns are therefore:

- **Malformed input causing a crash, hang, or unbounded allocation.** The parser
  handles untrusted `.tscn`, `.tres`, `.godot`, and JSON patch/intent files. A
  crafted file that panics the process, loops forever, or exhausts memory is a
  valid report.
- **Writing outside the intended path.** Commands that take `--project-root`,
  `--output`, or `res://` paths should not be coercible into writing somewhere the
  invoking user did not name.
- **Corrupting a file it was asked to edit.** Data loss on a valid input is a bug
  we care about, even where it isn't a security issue in the strict sense.

Out of scope: anything that requires you to already control the machine or the
files being edited, and the behaviour of Godot itself.

## Third-party code

Parts of this project are ported from the Godot Engine and from PCG — see
[THIRDPARTY.md](THIRDPARTY.md). Vulnerabilities in upstream Godot should be
reported to the Godot project; report them here only if this port is affected in a
way upstream is not.
