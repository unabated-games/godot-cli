#!/usr/bin/env bash
# Print the CHANGELOG.md section for one version, without its heading.
#
# Used by the release workflow to build release notes from the changelog that
# was reviewed in the pull request, rather than from a list of commit subjects.
#
#   tools/changelog_section.sh 0.2.0

set -euo pipefail

version="${1:?usage: changelog_section.sh <version>}"
version="${version#v}"
changelog="${2:-CHANGELOG.md}"

section="$(awk -v want="## [$version]" '
  index($0, want) == 1 { capture = 1; next }
  capture && /^## / { exit }
  capture { print }
' "$changelog")"

# Trim leading and trailing blank lines.
section="$(printf '%s\n' "$section" | sed -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}')"

if [[ -z "$section" ]]; then
  echo "No CHANGELOG section found for version $version" >&2
  exit 1
fi

printf '%s\n' "$section"
