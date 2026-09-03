#!/usr/bin/env bash
# Install godot-cli — binary, scene templates, agent docs, examples, shell
# completions, and the man page — into a self-contained prefix (~/.godot-cli).
#
# Two sources, same layout:
#
#   From a release (no Zig needed, works piped from curl):
#     curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
#     ./install.sh --from-release --version 0.1.0
#
#   From a source checkout:
#     ./install.sh                      # zig build, then install
#     ./install.sh --no-build           # install existing zig-out/bin/godot-cli
#     ./install.sh --install-skill      # also install the agent skill
#     ./install.sh --skills-only        # refresh agent skills only

set -euo pipefail

REPO="unabated-games/godot-cli"
# Where release archives are fetched from. Overridable so the download path can
# be exercised against a local server or a mirror.
DOWNLOAD_BASE="${GODOT_CLI_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
PREFIX="${HOME}/.godot-cli"
DO_BUILD=1
FROM_RELEASE=0
RELEASE_VERSION=""
INSTALL_SKILL=0
SKILLS_ONLY=0
OPTIMIZE="ReleaseFast"
# Comma-separated subset of: cursor,claude,opencode,agents (empty = all)
SKILL_TARGETS=""

die() {
  echo "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Source options:
  --from-release        Download a released binary instead of building
  --version VERSION     Release to install (default: latest); implies --from-release
  --no-build            Skip zig build; require zig-out/bin/godot-cli
  --debug               Build with Debug optimize (default: ReleaseFast)

Install options:
  --prefix DIR          Install root (default: ~/.godot-cli)
  --install-skill       Install agent skill to all supported tool directories
  --skill-targets LIST  Comma-separated: cursor,claude,opencode,agents (default: all)
  --skills-only         Only (re)install agent skills; skip binary/docs
  -h, --help            Show this help

Outside a source checkout (for example when piped from curl), --from-release is
the default.

Skill install locations (--install-skill):
  cursor    ~/.cursor/skills/godot-scene-authoring/
  claude    ~/.claude/skills/godot-scene-authoring/     (Claude Code)
  opencode  ~/.config/opencode/skills/godot-scene-authoring/
  agents    ~/.agents/skills/godot-scene-authoring/     (OpenCode-compatible)

After install, add to your shell profile:
  source "$HOME/.godot-cli/env.sh"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --from-release)
      FROM_RELEASE=1
      shift
      ;;
    --version)
      RELEASE_VERSION="${2#v}"
      FROM_RELEASE=1
      shift 2
      ;;
    --no-build)
      DO_BUILD=0
      shift
      ;;
    --install-skill)
      INSTALL_SKILL=1
      shift
      ;;
    --skill-targets)
      SKILL_TARGETS="$2"
      INSTALL_SKILL=1
      shift 2
      ;;
    --skills-only)
      SKILLS_ONLY=1
      INSTALL_SKILL=1
      shift
      ;;
    --debug)
      OPTIMIZE="Debug"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# A checkout is recognised by its build files, not by $0: piped through bash the
# script has no directory of its own, and the working directory is not a source
# tree just because someone happens to be standing in one.
is_source_tree() {
  [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/build.zig" && -d "$SCRIPT_DIR/src" ]]
}

if [[ "$FROM_RELEASE" -eq 0 ]] && ! is_source_tree; then
  FROM_RELEASE=1
fi

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required but was not found on PATH."
}

# ---------------------------------------------------------------------------
# Release download
# ---------------------------------------------------------------------------

release_target() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin) os="macos" ;;
    Linux) os="linux-musl" ;;
    *) die "No published binary for $os. Build from source: https://github.com/$REPO#building" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="aarch64" ;;
    *) die "No published binary for $arch. Build from source: https://github.com/$REPO#building" ;;
  esac

  echo "${arch}-${os}"
}

latest_version() {
  local tag="" redirect=""

  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
    sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" || true

  # The API is rate limited per IP; the /latest page redirects to the tag and is
  # not, so it is a usable second source for the same answer. Only trust the
  # redirect when it actually landed on a tag page: a private repository
  # redirects to a login page, and taking that URL as the version puts the whole
  # URL into the download path.
  if [[ -z "$tag" ]]; then
    redirect="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/$REPO/releases/latest" 2>/dev/null)" || true
    case "$redirect" in
      */releases/tag/*) tag="${redirect##*/tag/}" ;;
    esac
  fi

  # Whatever the source, the answer has to look like a version.
  case "$tag" in
    v[0-9]*|[0-9]*) ;;
    *)
      die "Could not resolve the latest release of $REPO.

Pass --version X.Y.Z to install a specific release. If the repository is
private, GitHub does not serve release assets to anonymous requests — use
'gh release download' with an authenticated gh, or build from source."
      ;;
  esac

  echo "${tag#v}"
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Downloads and verifies the release archive, then echoes the directory it was
# unpacked into.
fetch_release() {
  need curl
  need tar

  local version="$1"
  local target archive url tmp expected actual
  target="$(release_target)"
  archive="godot-cli-${version}-${target}.tar.gz"
  url="$DOWNLOAD_BASE/v${version}/${archive}"

  tmp="$(mktemp -d)"
  echo "Downloading $archive" >&2
  curl -fsSL --retry 3 -o "$tmp/$archive" "$url" ||
    die "Download failed: $url"

  # Checksums are published as one SHA256SUMS file covering every archive in
  # the release; a missing or mismatched entry means the download is not the
  # artifact that was built, so stop rather than install it.
  if curl -fsSL --retry 3 -o "$tmp/SHA256SUMS" \
    "$DOWNLOAD_BASE/v${version}/SHA256SUMS" 2>/dev/null; then
    expected="$(awk -v name="$archive" '$2 == name || $2 == "*"name {print $1}' "$tmp/SHA256SUMS" | head -1)"
    [[ -n "$expected" ]] || die "SHA256SUMS has no entry for $archive."

    if actual="$(sha256_of "$tmp/$archive")"; then
      [[ "$actual" == "$expected" ]] ||
        die "Checksum mismatch for $archive: expected $expected, got $actual."
      echo "Checksum verified" >&2
    else
      echo "Note: no shasum or sha256sum found; skipping checksum verification." >&2
    fi
  else
    die "Could not download SHA256SUMS for v${version}; refusing to install unverified binaries."
  fi

  tar -xzf "$tmp/$archive" -C "$tmp" || die "Could not unpack $archive."

  local extracted="$tmp/godot-cli-${version}-${target}"
  [[ -d "$extracted" ]] || die "Unexpected archive layout in $archive."
  echo "$extracted"
}

# ---------------------------------------------------------------------------
# Agent skills
# ---------------------------------------------------------------------------

skill_src_dir() {
  if [[ -n "${SOURCE_ROOT:-}" && -d "$SOURCE_ROOT/skills/godot-scene-authoring" ]]; then
    echo "$SOURCE_ROOT/skills/godot-scene-authoring"
  elif [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/skills/godot-scene-authoring" ]]; then
    echo "$SCRIPT_DIR/skills/godot-scene-authoring"
  elif [[ -d "$PREFIX/skills/godot-scene-authoring" ]]; then
    echo "$PREFIX/skills/godot-scene-authoring"
  elif [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/.cursor/skills/godot-scene-authoring" ]]; then
    echo "$SCRIPT_DIR/.cursor/skills/godot-scene-authoring"
  else
    return 1
  fi
}

install_skill_to() {
  local label="$1"
  local dest_parent="$2"
  local src="$3"
  local dest="$dest_parent/godot-scene-authoring"

  mkdir -p "$dest_parent"
  rm -rf "$dest"
  cp -R "$src/." "$dest"
  echo "  $label: $dest"
}

install_agent_skills() {
  local src
  src="$(skill_src_dir)" || {
    echo "Skill source not found (expected skills/godot-scene-authoring in the source tree, release archive, or install prefix)" >&2
    exit 1
  }

  local want_cursor=0 want_claude=0 want_opencode=0 want_agents=0
  if [[ -z "$SKILL_TARGETS" ]]; then
    want_cursor=1
    want_claude=1
    want_opencode=1
    want_agents=1
  else
    IFS=',' read -r -a _targets <<<"$SKILL_TARGETS"
    for t in "${_targets[@]}"; do
      case "$t" in
        cursor) want_cursor=1 ;;
        claude) want_claude=1 ;;
        opencode) want_opencode=1 ;;
        agents) want_agents=1 ;;
        *)
          echo "Unknown skill target: $t (use cursor,claude,opencode,agents)" >&2
          exit 1
          ;;
      esac
    done
  fi

  echo "Installing godot-scene-authoring skill from: $src"
  [[ "$want_cursor" -eq 1 ]] && install_skill_to "Cursor" "${HOME}/.cursor/skills" "$src"
  [[ "$want_claude" -eq 1 ]] && install_skill_to "Claude Code" "${HOME}/.claude/skills" "$src"
  [[ "$want_opencode" -eq 1 ]] && install_skill_to "OpenCode" "${HOME}/.config/opencode/skills" "$src"
  [[ "$want_agents" -eq 1 ]] && install_skill_to "Agents (~/.agents)" "${HOME}/.agents/skills" "$src"
  return 0
}

if [[ "$SKILLS_ONLY" -eq 1 ]]; then
  install_agent_skills
  echo ""
  echo "Skills updated."
  exit 0
fi

# ---------------------------------------------------------------------------
# Stage the payload
# ---------------------------------------------------------------------------

# SOURCE_ROOT holds the same layout in both modes: a source checkout and an
# unpacked release archive differ only in what else is next to these paths.
if [[ "$FROM_RELEASE" -eq 1 ]]; then
  if [[ -z "$RELEASE_VERSION" ]]; then
    need curl
    RELEASE_VERSION="$(latest_version)"
  fi
  echo "Installing godot-cli $RELEASE_VERSION from a release"
  SOURCE_ROOT="$(fetch_release "$RELEASE_VERSION")"
  SRC_BIN="$SOURCE_ROOT/bin/godot-cli"
else
  SOURCE_ROOT="$SCRIPT_DIR"

  if [[ "$(uname -s)" != "Darwin" && "$(uname -s)" != "Linux" ]]; then
    echo "Note: install.sh is tested on macOS and Linux; proceeding on $(uname -s)." >&2
  fi

  if [[ "$DO_BUILD" -eq 1 ]]; then
    command -v zig >/dev/null 2>&1 ||
      die "zig not found on PATH. Install Zig 0.16+, pass --no-build with a built binary, or use --from-release."
    echo "Building godot-cli ($OPTIMIZE)..."
    (cd "$SOURCE_ROOT" && zig build -Doptimize="$OPTIMIZE")
  fi

  SRC_BIN="$SOURCE_ROOT/zig-out/bin/godot-cli"
fi

[[ -x "$SRC_BIN" ]] || die "Binary not found: $SRC_BIN"

BIN_DIR="$PREFIX/bin"
TEMPLATES_DIR="$PREFIX/templates"
DOCS_DIR="$PREFIX/docs"
EXAMPLES_DIR="$PREFIX/examples"
COMPLETIONS_DIR="$PREFIX/share/completions"
MAN_DIR="$PREFIX/share/man/man1"
SKILLS_DIR="$PREFIX/skills/godot-scene-authoring"

echo "Installing to $PREFIX"
mkdir -p "$BIN_DIR" "$TEMPLATES_DIR" "$DOCS_DIR" "$EXAMPLES_DIR" \
  "$COMPLETIONS_DIR" "$MAN_DIR" "$(dirname "$SKILLS_DIR")"

install -m 755 "$SRC_BIN" "$BIN_DIR/godot-cli"
cp -R "$SOURCE_ROOT/templates/." "$TEMPLATES_DIR/"
for doc in agent_quickstart.md agent_godot_basics.md agent_scene_authoring.md agent_batch_commands.md commands.md mcp_tools.json; do
  [[ -f "$SOURCE_ROOT/docs/$doc" ]] && cp "$SOURCE_ROOT/docs/$doc" "$DOCS_DIR/"
done
cp -R "$SOURCE_ROOT/share/examples/." "$EXAMPLES_DIR/"
cp -R "$SOURCE_ROOT/share/completions/." "$COMPLETIONS_DIR/"
cp -R "$SOURCE_ROOT/share/man/man1/." "$MAN_DIR/"

# The MIT and Apache-2.0 notices have to travel with the binary.
cp "$SOURCE_ROOT/LICENSE" "$SOURCE_ROOT/THIRDPARTY.md" "$PREFIX/"
cp -R "$SOURCE_ROOT/third_party" "$PREFIX/third_party"

# Bundled skill copy inside install prefix (used for --skills-only refresh)
SKILL_SRC="$(skill_src_dir)" || SKILL_SRC=""
if [[ -n "$SKILL_SRC" ]]; then
  rm -rf "$SKILLS_DIR"
  cp -R "$SKILL_SRC/." "$SKILLS_DIR/"
fi

cat >"$PREFIX/env.sh" <<EOF
# godot-cli agent environment — source this file in your shell or agent session.
export GODOT_CLI_HOME="$PREFIX"
export GODOT_CLI="\$GODOT_CLI_HOME/bin/godot-cli"
export GODOT_CLI_TEMPLATES_ROOT="\$GODOT_CLI_HOME/templates"
export PATH="\$GODOT_CLI_HOME/bin:\$PATH"
export MANPATH="\$GODOT_CLI_HOME/share/man:\${MANPATH:-}"

# Shell completions, if the running shell supports them.
if [ -n "\${BASH_VERSION:-}" ]; then
  [ -r "\$GODOT_CLI_HOME/share/completions/godot-cli.bash" ] &&
    . "\$GODOT_CLI_HOME/share/completions/godot-cli.bash"
elif [ -n "\${ZSH_VERSION:-}" ]; then
  fpath=("\$GODOT_CLI_HOME/share/completions" \$fpath)
fi
EOF

cat >"$PREFIX/VERSION" <<EOF
installed_from=$([[ "$FROM_RELEASE" -eq 1 ]] && echo "release v$RELEASE_VERSION" || echo "$SOURCE_ROOT")
installed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
binary_version=$("$BIN_DIR/godot-cli" --version 2>/dev/null || echo unknown)
EOF

if [[ "$INSTALL_SKILL" -eq 1 ]]; then
  echo ""
  install_agent_skills
fi

echo ""
echo "Installed godot-cli to $PREFIX"
echo ""
echo "  Binary:       $BIN_DIR/godot-cli"
echo "  Templates:    $TEMPLATES_DIR"
echo "  Docs:         $DOCS_DIR"
echo "  Examples:     $EXAMPLES_DIR"
echo "  Completions:  $COMPLETIONS_DIR"
echo "  Man page:     $MAN_DIR/godot-cli.1"
[[ -n "$SKILL_SRC" ]] && echo "  Skill copy:   $SKILLS_DIR"
echo ""
echo "Activate (add to ~/.zshrc or ~/.bashrc for persistence):"
echo "  source \"$PREFIX/env.sh\""
echo ""
echo "Smoke test:"
echo "  source \"$PREFIX/env.sh\" && godot-cli ping --json"
echo ""
if [[ "$INSTALL_SKILL" -eq 0 ]]; then
  echo "Install agent skills (Cursor, Claude Code, OpenCode, ~/.agents):"
  echo "  install.sh --prefix \"$PREFIX\" --no-build --install-skill"
fi
