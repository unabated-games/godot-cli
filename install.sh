#!/usr/bin/env bash
# Install godot-cli for agent use on macOS (and other Unix shells).
# Packages: binary, scene templates, agent docs, example intents/batch files, env.sh.
#
# Usage:
#   ./install.sh                      # build + install to ~/.godot-cli
#   ./install.sh --install-skill        # also install skill for Cursor, Claude Code, OpenCode
#   ./install.sh --skills-only        # refresh agent skills only (no rebuild)
#   ./install.sh --no-build           # install existing zig-out/bin/godot-cli

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HOME}/.godot-cli"
DO_BUILD=1
INSTALL_SKILL=0
SKILLS_ONLY=0
OPTIMIZE="ReleaseFast"
# Comma-separated subset of: cursor,claude,opencode,agents (empty = all)
SKILL_TARGETS=""

usage() {
  cat <<'EOF'
Usage: install.sh [options]

Options:
  --prefix DIR          Install root (default: ~/.godot-cli)
  --no-build            Skip zig build; require zig-out/bin/godot-cli
  --install-skill       Install agent skill to all supported tool directories
  --skill-targets LIST  Comma-separated: cursor,claude,opencode,agents (default: all)
  --skills-only         Only (re)install agent skills; skip binary/docs
  --debug               Build with Debug optimize (default: ReleaseFast)
  -h, --help            Show this help

Skill install locations (--install-skill):
  cursor    ~/.cursor/skills/godot-scene-authoring/
  claude    ~/.claude/skills/godot-scene-authoring/     (Claude Code)
  opencode  ~/.config/opencode/skills/godot-scene-authoring/
  agents    ~/.agents/skills/godot-scene-authoring/     (OpenCode-compatible)

After install, add to your shell profile:
  source "$HOME/.godot-cli/env.sh"

Or run one-off:
  source "$HOME/.godot-cli/env.sh" && godot-cli ping --json
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)
      PREFIX="$2"
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

skill_src_dir() {
  if [[ -d "$SCRIPT_DIR/skills/godot-scene-authoring" ]]; then
    echo "$SCRIPT_DIR/skills/godot-scene-authoring"
  elif [[ -d "$PREFIX/skills/godot-scene-authoring" ]]; then
    echo "$PREFIX/skills/godot-scene-authoring"
  elif [[ -d "$SCRIPT_DIR/.cursor/skills/godot-scene-authoring" ]]; then
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
    echo "Skill source not found (expected skills/godot-scene-authoring in repo or install prefix)" >&2
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
}

if [[ "$SKILLS_ONLY" -eq 1 ]]; then
  install_agent_skills
  echo ""
  echo "Skills updated."
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Note: install.sh is tested on macOS; proceeding on $(uname -s)." >&2
fi

if ! command -v zig >/dev/null 2>&1 && [[ "$DO_BUILD" -eq 1 ]]; then
  echo "zig not found on PATH. Install Zig 0.16+ or pass --no-build with a built binary." >&2
  exit 1
fi

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo "Building godot-cli ($OPTIMIZE)..."
  (cd "$SCRIPT_DIR" && zig build -Doptimize="$OPTIMIZE")
fi

SRC_BIN="$SCRIPT_DIR/zig-out/bin/godot-cli"
if [[ ! -x "$SRC_BIN" ]]; then
  echo "Binary not found: $SRC_BIN" >&2
  exit 1
fi

BIN_DIR="$PREFIX/bin"
TEMPLATES_DIR="$PREFIX/templates"
DOCS_DIR="$PREFIX/docs"
EXAMPLES_DIR="$PREFIX/examples"
SKILLS_DIR="$PREFIX/skills/godot-scene-authoring"

echo "Installing to $PREFIX"
mkdir -p "$BIN_DIR" "$TEMPLATES_DIR" "$DOCS_DIR" "$EXAMPLES_DIR" "$(dirname "$SKILLS_DIR")"

install -m 755 "$SRC_BIN" "$BIN_DIR/godot-cli"
cp -R "$SCRIPT_DIR/templates/." "$TEMPLATES_DIR/"
cp "$SCRIPT_DIR/docs/agent_scene_authoring.md" "$DOCS_DIR/"
cp "$SCRIPT_DIR/docs/agent_batch_commands.md" "$DOCS_DIR/"
cp "$SCRIPT_DIR/docs/agent_quickstart.md" "$DOCS_DIR/"
cp "$SCRIPT_DIR/docs/mcp_tools.json" "$DOCS_DIR/"
cp -R "$SCRIPT_DIR/share/examples/." "$EXAMPLES_DIR/"

# The MIT and Apache-2.0 notices have to travel with the binary.
cp "$SCRIPT_DIR/LICENSE" "$SCRIPT_DIR/THIRDPARTY.md" "$PREFIX/"
cp -R "$SCRIPT_DIR/third_party" "$PREFIX/third_party"

# Bundled skill copy inside install prefix (used for --skills-only refresh)
SKILL_SRC="$(skill_src_dir)" || SKILL_SRC="$SCRIPT_DIR/skills/godot-scene-authoring"
rm -rf "$SKILLS_DIR"
cp -R "$SKILL_SRC/." "$SKILLS_DIR/"

cat >"$PREFIX/env.sh" <<EOF
# godot-cli agent environment — source this file in your shell or agent session.
export GODOT_CLI_HOME="$PREFIX"
export GODOT_CLI="\$GODOT_CLI_HOME/bin/godot-cli"
export GODOT_CLI_TEMPLATES_ROOT="\$GODOT_CLI_HOME/templates"
export PATH="\$GODOT_CLI_HOME/bin:\$PATH"
EOF

cat >"$PREFIX/VERSION" <<EOF
installed_from=$SCRIPT_DIR
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
echo "  Binary:     $BIN_DIR/godot-cli"
echo "  Templates:  $TEMPLATES_DIR"
echo "  Docs:       $DOCS_DIR"
echo "  Examples:   $EXAMPLES_DIR"
echo "  Skill copy: $SKILLS_DIR"
echo ""
echo "Activate (add to ~/.zshrc for persistence):"
echo "  source \"$PREFIX/env.sh\""
echo ""
echo "Smoke test:"
echo "  source \"$PREFIX/env.sh\" && godot-cli ping --json"
echo ""
if [[ "$INSTALL_SKILL" -eq 0 ]]; then
  echo "Install agent skills (Cursor, Claude Code, OpenCode, ~/.agents):"
  echo "  $SCRIPT_DIR/install.sh --prefix \"$PREFIX\" --no-build --install-skill"
  echo ""
  echo "Or refresh skills only:"
  echo "  $SCRIPT_DIR/install.sh --skills-only"
fi
