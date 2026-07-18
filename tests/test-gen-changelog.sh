#!/usr/bin/env bash
# Unit tests for gen-changelog.sh. Run: bash tests/test-gen-changelog.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/gen-changelog.sh"

PASS=0
FAIL=0
check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1 (expected [$2], got [$3])"; FAIL=$((FAIL+1))
  fi
}
has() {  # has <description> <needle> <haystack-string>
  check "$1" "1" "$(echo "$3" | grep -c -- "$2")"
}

# Build a scratch git repo with a fake history: a release marker, then
# feat/fix/docs/chore commits, a merge commit, and a breaking-change commit.
REPO=$(mktemp -d)
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" commit -q --allow-empty -m "release: v1.0.0"
git -C "$REPO" commit -q --allow-empty -m "feat: add widget cache"
git -C "$REPO" commit -q --allow-empty -m "fix: correct cache eviction"
git -C "$REPO" commit -q --allow-empty -m "docs: document the cache"
git -C "$REPO" commit -q --allow-empty -m "chore: bump lint config"
git -C "$REPO" commit -q --allow-empty -m "feat!: drop legacy cache API"
git -C "$REPO" commit -q --allow-empty -m "just a plain subject with no prefix"
# a merge commit must be excluded
git -C "$REPO" checkout -qb side HEAD~2
git -C "$REPO" commit -q --allow-empty -m "feat: side branch work"
git -C "$REPO" checkout -q -
git -C "$REPO" merge -q --no-ff side -m "Merge branch 'side'"

out=$(bash "$SCRIPT" --repo-dir "$REPO" --version 1.2.0)

has "has version heading" "^## \[1\.2\.0\]" "$out"
has "has today's date in heading" "$(date +%F)" "$out"
has "has Added section" "^### Added$" "$out"
has "added includes feat commit" "add widget cache" "$out"
has "added includes breaking commit with marker" "\*\*BREAKING:\*\* drop legacy cache API" "$out"
has "has Fixed section" "^### Fixed$" "$out"
has "fixed includes fix commit" "correct cache eviction" "$out"
has "has Changed section" "^### Changed$" "$out"
has "changed includes docs commit" "document the cache" "$out"
has "changed includes chore commit" "bump lint config" "$out"
has "changed includes no-prefix commit as chore text" "just a plain subject with no prefix" "$out"
check "excludes the release: v1.0.0 boundary commit" "0" "$(echo "$out" | grep -c 'release: v1.0.0')"
check "excludes merge commit subject" "0" "$(echo "$out" | grep -c "Merge branch")"
check "merged side-branch feat commit IS included (reachable from HEAD)" "1" "$(echo "$out" | grep -c 'side branch work')"

# --- empty-bucket fallback ---
EMPTY_REPO=$(mktemp -d)
git -C "$EMPTY_REPO" init -q
git -C "$EMPTY_REPO" config user.email test@example.com
git -C "$EMPTY_REPO" config user.name "Test"
git -C "$EMPTY_REPO" commit -q --allow-empty -m "release: v2.0.0"
out=$(bash "$SCRIPT" --repo-dir "$EMPTY_REPO" --version 2.0.0)
has "empty history -> no notable changes fallback" "_No notable changes\._" "$out"
check "empty history -> no section headings" "0" "$(echo "$out" | grep -c '^### ')"

# --- version resolution from plugin.json when --version omitted ---
PJ_REPO=$(mktemp -d)
git -C "$PJ_REPO" init -q
git -C "$PJ_REPO" config user.email test@example.com
git -C "$PJ_REPO" config user.name "Test"
mkdir -p "$PJ_REPO/.claude-plugin"
echo '{"version": "9.9.9"}' > "$PJ_REPO/.claude-plugin/plugin.json"
git -C "$PJ_REPO" commit -q --allow-empty -m "feat: seed"
out=$(bash "$SCRIPT" --repo-dir "$PJ_REPO")
has "reads version from plugin.json when --version omitted" "^## \[9\.9\.9\]" "$out"

rm -rf "$REPO" "$EMPTY_REPO" "$PJ_REPO"
echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
