#!/usr/bin/env bash
# gen-changelog.sh — print the Keep a Changelog section for one version,
# built from commit subjects since the last "release: v*" marker.
# Prints ONLY the generated section to stdout; never touches CHANGELOG.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
VERSION=""

usage() {
  echo "usage: gen-changelog.sh [--repo-dir <path>] [--version X.Y.Z]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    --version)  VERSION="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ ! -d "$REPO_DIR" ]]; then
  echo "error: no such repo dir: $REPO_DIR" >&2; exit 2
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(jq -r '.version // empty' "$REPO_DIR/.claude-plugin/plugin.json" 2>/dev/null)"
fi
if [[ -z "$VERSION" ]]; then
  echo "error: could not determine version (pass --version or provide $REPO_DIR/.claude-plugin/plugin.json)" >&2
  exit 2
fi

# Boundary: most recent commit whose subject matches ^release: v (this repo
# has no git tags; that commit message is the only release marker).
BOUNDARY="$(git -C "$REPO_DIR" log --extended-regexp --grep='^release: v' --format='%H' -1 2>/dev/null || true)"

RANGE="HEAD"
[[ -n "$BOUNDARY" ]] && RANGE="$BOUNDARY..HEAD"

mapfile -t SUBJECTS < <(git -C "$REPO_DIR" log --no-merges --format='%s' --reverse "$RANGE" 2>/dev/null || true)

ADDED=()
FIXED=()
CHANGED=()

for subj in "${SUBJECTS[@]}"; do
  [[ "$subj" =~ ^release:\ v ]] && continue
  type="chore"
  breaking=""
  text="$subj"
  if [[ "$subj" =~ ^([a-z]+)(\(([^\)]+)\))?(\!)?:\ (.+)$ ]]; then
    type="${BASH_REMATCH[1]}"
    breaking="${BASH_REMATCH[4]}"
    text="${BASH_REMATCH[5]}"
  fi
  [[ -n "$breaking" ]] && text="**BREAKING:** $text"
  case "$type" in
    feat) ADDED+=("- $text") ;;
    fix)  FIXED+=("- $text") ;;
    *)    CHANGED+=("- $text") ;;
  esac
done

DATE="$(date +%F)"

BLOCKS=()
[[ ${#ADDED[@]} -gt 0 ]]   && BLOCKS+=("### Added
$(printf '%s\n' "${ADDED[@]}")")
[[ ${#CHANGED[@]} -gt 0 ]] && BLOCKS+=("### Changed
$(printf '%s\n' "${CHANGED[@]}")")
[[ ${#FIXED[@]} -gt 0 ]]   && BLOCKS+=("### Fixed
$(printf '%s\n' "${FIXED[@]}")")

echo "## [$VERSION] - $DATE"
echo

if [[ ${#BLOCKS[@]} -eq 0 ]]; then
  echo "_No notable changes._"
else
  BODY="$(printf '%s\n\n' "${BLOCKS[@]}")"
  printf '%s' "${BODY%$'\n\n'}"
  echo
fi
