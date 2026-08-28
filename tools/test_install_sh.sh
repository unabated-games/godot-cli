#!/usr/bin/env bash
# Exercise install.sh's release-resolution logic with curl stubbed out.
#
# The version resolver reads two sources that can both fail or lie — the
# releases API and the redirect target of the /latest page — and its answer ends
# up inside a download URL. A private repository redirects to a login page, and
# taking that URL as a version once produced a download path with a whole URL
# embedded in it.
#
#   tools/test_install_sh.sh [path/to/install.sh]

set -uo pipefail

installer="${1:-install.sh}"
failures=0

# Run latest_version in a subshell with `curl` replaced, and report what it
# printed (or <error> if it exited non-zero).
resolve() {
  local api="$1" redirect="$2"
  bash -c '
    set -uo pipefail
    REPO="owner/repo"
    die() { echo "$*" >&2; exit 1; }
    eval "$(awk "/^latest_version\(\) \{/,/^\}/" "$1")"
    curl() {
      case "$*" in
        *url_effective*) [ -n "$REDIRECT" ] && printf "%s" "$REDIRECT" || return 22 ;;
        *) [ -n "$API" ] && printf "%s" "$API" || return 22 ;;
      esac
    }
    latest_version
  ' _ "$installer" 2>/dev/null || echo "<error>"
}

expect() {
  local label="$1" api="$2" redirect="$3" want="$4"
  local got
  got="$(API="$api" REDIRECT="$redirect" resolve "$api" "$redirect")"
  if [[ "$got" == "$want" ]]; then
    echo "ok    $label"
  else
    echo "FAIL  $label: got '$got', want '$want'" >&2
    failures=$((failures + 1))
  fi
}

export -f resolve
expect "release API answers"          '{"tag_name": "v0.2.0"}' ''                                              '0.2.0'
expect "tag without a v prefix"       '{"tag_name": "1.4.0"}'  ''                                              '1.4.0'
expect "API down, redirect to a tag"  ''                       'https://github.com/owner/repo/releases/tag/v0.3.1' '0.3.1'
expect "private repo login redirect"  ''                       'https://github.com/login?return_to=%2Fowner'   '<error>'
expect "repo has no releases yet"     ''                       'https://github.com/owner/repo/releases'        '<error>'
expect "both sources unreachable"     ''                       ''                                              '<error>'

if [[ "$failures" -ne 0 ]]; then
  echo "$failures install.sh case(s) failed" >&2
  exit 1
fi
echo "install.sh: release resolution behaves"
