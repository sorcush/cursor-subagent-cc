# Changelog Tracking + Per-Agent Model Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-generate `CHANGELOG.md` at every `make release`, and replace six-plus hardcoded mentions of the coder/reviewer model names with a single `.claude-plugin/models.json` source of truth that scripts read at runtime and docs get regenerated from.

**Architecture:** Two independent scripts land first (`scripts/gen-changelog.sh` + `scripts/update-changelog.sh` for the changelog; `scripts/sync-models.sh` for doc regeneration), each covered by its own bash test suite following this repo's existing `check()`-helper pattern (see `tests/test-cc-delegate.sh`). The two existing delegate scripts gain a small runtime config-read. The Makefile's `release` target is extended to call both new pieces. A final "Rollout" task applies the bootstrap markers to the real repo files and runs the tools for real, fixing the actual `GPT-5.5`/`gpt-5.5` drift already present in this repo.

**Tech Stack:** bash (`set -uo pipefail`), `jq`, `awk`, `perl` (for marker replacement — ships with macOS/Linux, used only for line-scoped, non-greedy find/replace that plain `sed` handles awkwardly), GNU Make.

## Global Constraints

These apply to every task below; copied verbatim from the spec.

- `id` (in `models.json`) is constrained to `[A-Za-z0-9._+-]+`.
- `label` (in `models.json`) is constrained to plain ASCII with no `:`, `"`, backtick, or newline.
- `sync-models.sh` validates the **entire** `models.json` (both fail-fast checks above) **before writing any file** — a bad config touches zero files.
- `sync-models.sh` (no flag) writes each target file to a temp path and renames it into place only on success for that file — a failure partway through leaves earlier files updated, later ones untouched, and the script reports exactly which.
- The only two marker tags used anywhere are `<!-- model:coder:label -->…<!-- /model:coder:label -->` and `<!-- model:reviewer:label -->…<!-- /model:reviewer:label -->`. Model **ids** are never marker-wrapped — every place an id has functional effect reads `models.json` live instead (see Task 2/3/9).
- Marker tags inside `.sh` files must stay on the existing `#`-comment line — never span onto a following code line.
- `scripts/gen-changelog.sh` never touches `CHANGELOG.md` — it only prints the new section to stdout. `scripts/update-changelog.sh` owns all file writes.
- The changelog section boundary for replace-in-place is: the line matching `^## \[X.Y.Z\]` through the line immediately before the next line matching `^## \[`, or through EOF if there is none.
- The changelog insert point is immediately before the first existing `^## \[` line (i.e. below the header, above the most recent existing version) — never a literal byte-0 prepend.
- Section ordering within a changelog entry is `### Added`, then `### Changed`, then `### Fixed` (Keep a Changelog's canonical order), each omitted if empty; if all three are empty, the body is the single line `_No notable changes._`.
- The commit-subject grammar: `type` = leading lowercase word before `(`/`!`/`:`; optional `(scope)` is parsed but discarded; optional `!` immediately before `:` marks `breaking`; `text` is everything after `: `. No match at all → `type=chore`, `text=<full subject>`.
- `feat` → Added, `fix` → Fixed, everything else → Changed. `breaking` prefixes the bullet with `**BREAKING:**` but never changes which `bump-*` target to run (that stays manual).
- The boundary commit for changelog generation is the most recent commit whose subject matches `^release: v` (no git tags exist in this repo); if none exists, the boundary is the root of history. Merge commits and the boundary commit itself are excluded from collection.
- Date used in the changelog heading is the local system date (`date +%F`), not UTC.

---

## Task 1: `.claude-plugin/models.json`

**Files:**
- Create: `.claude-plugin/models.json`

**Interfaces:**
- Produces: a JSON file at this exact path with shape `{"coder": {"id": string, "label": string}, "reviewer": {"id": string, "label": string}}`. Every later task reads `.coder.id`, `.coder.label`, `.reviewer.id`, `.reviewer.label` from it via `jq`.

This is a data file, not logic — no failing test to write first. Verify it with `jq` instead of a test framework.

- [ ] **Step 1: Create the file**

```json
{
  "coder": {
    "id": "composer-2.5",
    "label": "Composer 2.5"
  },
  "reviewer": {
    "id": "cursor-grok-4.5-high-fast",
    "label": "Grok 4.5 (high effort, fast)"
  }
}
```

- [ ] **Step 2: Verify it's valid JSON with the expected shape**

Run: `jq -e '.coder.id, .coder.label, .reviewer.id, .reviewer.label' .claude-plugin/models.json`
Expected output (four lines):
```
"composer-2.5"
"Composer 2.5"
"cursor-grok-4.5-high-fast"
"Grok 4.5 (high effort, fast)"
```

- [ ] **Step 3: Commit**

```bash
git add .claude-plugin/models.json
git commit -m "feat: add models.json as the single source of truth for coder/reviewer models"
```

---

## Task 2: `cc-delegate.sh` reads model id from `models.json`

**Files:**
- Modify: `scripts/cc-delegate.sh` (currently line 6-7: `CURSOR_BIN=...` / `MODEL="composer-2.5"`)
- Modify: `tests/test-cc-delegate.sh` (currently line 46 asserts the literal `composer-2.5`)

**Interfaces:**
- Consumes: `.claude-plugin/models.json` (Task 1), read via `jq -r '.coder.id // empty'`.
- Produces: `cc-delegate.sh` still sets a shell variable `MODEL` used exactly as before at line 74 (`--model "$MODEL"`) — no interface change for callers of the script. New override env var `CC_MODELS_JSON` (mirrors existing `CC_CURSOR_BIN`).

- [ ] **Step 1: Add a failing test for the models.json read and the override var**

Add to `tests/test-cc-delegate.sh`, right after the existing `export CC_CURSOR_BIN="$MOCK"` line (so it's near the top, before the current test cases):

```bash
# --- model resolution from models.json ---
FIXTURE_MODELS=$(mktemp)
cat > "$FIXTURE_MODELS" <<'EOF'
{"coder": {"id": "fixture-coder-model", "label": "Fixture Coder"}, "reviewer": {"id": "fixture-reviewer-model", "label": "Fixture Reviewer"}}
EOF

tf=$(mktemp); echo "do the thing" > "$tf"
log=$(mktemp)
CC_MODELS_JSON="$FIXTURE_MODELS" MOCK_LOG="$log" bash "$SCRIPT" --task-file "$tf" --verify-cmd "" >/dev/null 2>&1
check "reads model id from CC_MODELS_JSON override" "1" "$(grep -c -- "fixture-coder-model" "$log")"
rm -f "$log"

# missing/invalid models.json -> fail fast, never invoke cursor-agent with empty --model
out=$(CC_MODELS_JSON=/no/such/file.json bash "$SCRIPT" --task-file "$tf" --verify-cmd "" 2>/dev/null); rc=$?
check "missing models.json exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

BAD_MODELS=$(mktemp); echo '{"coder": {}}' > "$BAD_MODELS"
out=$(CC_MODELS_JSON="$BAD_MODELS" bash "$SCRIPT" --task-file "$tf" --verify-cmd "" 2>/dev/null); rc=$?
check "models.json missing .coder.id exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

rm -f "$tf" "$FIXTURE_MODELS" "$BAD_MODELS"
```

- [ ] **Step 2: Run the test file to verify the new checks fail**

Run: `bash tests/test-cc-delegate.sh 2>&1 | grep -A1 "model"`
Expected: `FAIL - reads model id from CC_MODELS_JSON override` (and the file still uses `composer-2.5` hardcoded, so this fails). The two exit-code checks will currently pass by accident (script doesn't touch `models.json` at all yet, so those particular commands don't error) — that's fine, they'll be pinned down once real logic exists; re-verify all three after Step 3.

- [ ] **Step 3: Implement — read `MODEL` from `models.json`**

In `scripts/cc-delegate.sh`, replace:

```bash
CURSOR_BIN="${CC_CURSOR_BIN:-cursor-agent}"
MODEL="composer-2.5"
```

with:

```bash
CURSOR_BIN="${CC_CURSOR_BIN:-cursor-agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_JSON="${CC_MODELS_JSON:-$SCRIPT_DIR/../.claude-plugin/models.json}"
MODEL="$(jq -r '.coder.id // empty' "$MODELS_JSON" 2>/dev/null)"
if [[ -z "$MODEL" ]]; then
  echo "error: could not read .coder.id from $MODELS_JSON" >&2
  exit 2
fi
```

Also update the header comment on line 2 to prepare for the marker rollout in Task 9 — leave it as plain text for now (`# cc-delegate.sh — delegate one task to Cursor Composer 2.5 and verify.`); Task 9 adds the marker.

- [ ] **Step 4: Run the test file to verify it passes**

Run: `bash tests/test-cc-delegate.sh`
Expected: `PASS=<N> FAIL=0` where N is the previous count plus 3. All existing checks (including the line-46 `composer-2.5` one, since the default `models.json` from Task 1 still resolves to that id when `CC_MODELS_JSON` isn't set) still pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/cc-delegate.sh tests/test-cc-delegate.sh
git commit -m "feat: read coder model id from models.json in cc-delegate.sh"
```

---

## Task 3: `cr-delegate.sh` reads model id from `models.json`

**Files:**
- Modify: `scripts/cr-delegate.sh` (currently line 7-8: `CURSOR_BIN=...` / `MODEL="cursor-grok-4.5-high-fast"`)
- Modify: `tests/test-cr-delegate.sh` (currently line 75 asserts the literal `cursor-grok-4.5-high-fast`)

**Interfaces:**
- Consumes: `.claude-plugin/models.json` (Task 1), read via `jq -r '.reviewer.id // empty'`.
- Produces: same `MODEL` variable contract as before; new override env var `CR_MODELS_JSON`.

- [ ] **Step 1: Add a failing test**

Add to `tests/test-cr-delegate.sh`, right after `export CR_CURSOR_BIN="$MOCK"`:

```bash
# --- model resolution from models.json ---
FIXTURE_MODELS=$(mktemp)
cat > "$FIXTURE_MODELS" <<'EOF'
{"coder": {"id": "fixture-coder-model", "label": "Fixture Coder"}, "reviewer": {"id": "fixture-reviewer-model", "label": "Fixture Reviewer"}}
EOF

log=$(mktemp)
CR_MODELS_JSON="$FIXTURE_MODELS" MOCK_LOG="$log" bash "$SCRIPT" \
  --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" >/dev/null 2>&1
has "reads model id from CR_MODELS_JSON override" "fixture-reviewer-model" "$log"
rm -f "$log"

out=$(CR_MODELS_JSON=/no/such/file.json bash "$SCRIPT" --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null); rc=$?
check "missing models.json exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

BAD_MODELS=$(mktemp); echo '{"reviewer": {}}' > "$BAD_MODELS"
out=$(CR_MODELS_JSON="$BAD_MODELS" bash "$SCRIPT" --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null); rc=$?
check "models.json missing .reviewer.id exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

rm -f "$FIXTURE_MODELS" "$BAD_MODELS"
```

Note: this block must go after `$doc` and `$RUBRICS` are defined (they're set up a few lines below `export CR_CURSOR_BIN=...` in the current file) — place it right after the `doc=$(mktemp); echo "# Some Spec" > "$doc"` line instead if inserting earlier would reference `$doc` before it exists. Check the current file layout before inserting.

- [ ] **Step 2: Run the test file to verify the new checks fail**

Run: `bash tests/test-cr-delegate.sh 2>&1 | grep -A1 "model"`
Expected: `FAIL - reads model id from CR_MODELS_JSON override`.

- [ ] **Step 3: Implement**

In `scripts/cr-delegate.sh`, replace:

```bash
CURSOR_BIN="${CR_CURSOR_BIN:-cursor-agent}"
MODEL="cursor-grok-4.5-high-fast"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

with:

```bash
CURSOR_BIN="${CR_CURSOR_BIN:-cursor-agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_JSON="${CR_MODELS_JSON:-$SCRIPT_DIR/../.claude-plugin/models.json}"
MODEL="$(jq -r '.reviewer.id // empty' "$MODELS_JSON" 2>/dev/null)"
if [[ -z "$MODEL" ]]; then
  echo "error: could not read .reviewer.id from $MODELS_JSON" >&2
  exit 2
fi
```

(`SCRIPT_DIR` already exists at this position in the file — reuse it, don't duplicate the line.)

- [ ] **Step 4: Run the test file to verify it passes**

Run: `bash tests/test-cr-delegate.sh`
Expected: `PASS=<N> FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/cr-delegate.sh tests/test-cr-delegate.sh
git commit -m "feat: read reviewer model id from models.json in cr-delegate.sh"
```

---

## Task 4: `scripts/gen-changelog.sh`

**Files:**
- Create: `scripts/gen-changelog.sh`
- Test: `tests/test-gen-changelog.sh`

**Interfaces:**
- Consumes: a git repo (via `--repo-dir`, default the real plugin repo) and a version string (via `--version`, default read from `<repo-dir>/.claude-plugin/plugin.json`).
- Produces: prints the Markdown changelog section (starting `## [X.Y.Z] - YYYY-MM-DD`) to stdout; nothing else on stdout. Never writes any file. Exit 0 on success, exit 2 on usage error (e.g. no version determinable).
- Consumed by: Task 5's `update-changelog.sh` (via a pipe) and Task 6's Makefile wiring.

- [ ] **Step 1: Write the failing test**

Create `tests/test-gen-changelog.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-gen-changelog.sh`
Expected: fails immediately — `scripts/gen-changelog.sh: No such file or directory` (script doesn't exist yet).

- [ ] **Step 3: Implement `scripts/gen-changelog.sh`**

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-gen-changelog.sh`
Expected: `PASS=<N> FAIL=0` with N matching the number of `check`/`has` calls above (16).

If `feat!: drop legacy cache API` doesn't parse as `type=feat, breaking=!`, double-check the regex group indices — bash's `BASH_REMATCH` index 4 is the `(\!)?` group (indices: 1=type, 2=`(scope)` with parens, 3=scope-inner, 4=`!`, 5=text). Debug with `echo "${BASH_REMATCH[@]}"` if a check fails.

- [ ] **Step 5: Make it executable and commit**

```bash
chmod +x scripts/gen-changelog.sh
git add scripts/gen-changelog.sh tests/test-gen-changelog.sh
git commit -m "feat: add gen-changelog.sh to generate a Keep a Changelog section from commits"
```

---

## Task 5: `scripts/update-changelog.sh`

**Files:**
- Create: `scripts/update-changelog.sh`
- Test: `tests/test-update-changelog.sh`

**Interfaces:**
- Consumes: a section of Markdown text on stdin (the exact stdout of Task 4's `gen-changelog.sh`), `--version X.Y.Z` (required, used to find/replace an existing section for that version), `--file <path>` (default `CHANGELOG.md` next to the script's repo root).
- Produces: writes/updates the file at `--file`. Idempotent: calling it twice in a row with the same version and same stdin content leaves the file unchanged after the second call (replace-in-place, not duplicate).

- [ ] **Step 1: Write the failing test**

Create `tests/test-update-changelog.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for update-changelog.sh. Run: bash tests/test-update-changelog.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/update-changelog.sh"

PASS=0
FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1 (expected [$2], got [$3])"; FAIL=$((FAIL+1))
  fi
}

HEADER_TITLE="# Changelog"

# --- creates a fresh file with header when none exists ---
f=$(mktemp -u)
printf '## [1.0.0] - 2026-01-01\n\n### Added\n- first release\n' | \
  bash "$SCRIPT" --version 1.0.0 --file "$f"
check "creates file" "1" "$([ -f "$f" ] && echo 1 || echo 0)"
check "has standard header" "1" "$(grep -c -- "$HEADER_TITLE" "$f")"
check "has the new section" "1" "$(grep -c -- '## \[1.0.0\]' "$f")"
check "header appears before section" "1" "$([ "$(grep -n "$HEADER_TITLE" "$f" | head -1 | cut -d: -f1)" -lt "$(grep -n '## \[1.0.0\]' "$f" | head -1 | cut -d: -f1)" ] && echo 1 || echo 0)"
rm -f "$f"

# --- inserts a new version above older ones, below the header ---
f=$(mktemp)
cat > "$f" <<'EOF'
# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-01-01

### Added
- first release
EOF
printf '## [1.1.0] - 2026-02-01\n\n### Fixed\n- a bug\n' | bash "$SCRIPT" --version 1.1.0 --file "$f"
lines=$(grep -n '^## \[' "$f" | cut -d: -f1)
first=$(echo "$lines" | sed -n '1p')
second=$(echo "$lines" | sed -n '2p')
check "two version headings present" "2" "$(echo "$lines" | wc -l | tr -d ' ')"
check "new version (1.1.0) comes first" "1" "$(sed -n "${first}p" "$f" | grep -c '1\.1\.0')"
check "old version (1.0.0) comes second, untouched" "1" "$(sed -n "${second}p" "$f" | grep -c '1\.0\.0')"
check "old section body survived" "1" "$(grep -c 'first release' "$f")"
rm -f "$f"

# --- replace-in-place: re-running for the SAME version replaces, not duplicates ---
f=$(mktemp)
cat > "$f" <<'EOF'
# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] - 2026-03-01

### Added
- stale draft, written before a retry
EOF
printf '## [2.0.0] - 2026-03-01\n\n### Added\n- final correct content\n### Fixed\n- also this\n' | \
  bash "$SCRIPT" --version 2.0.0 --file "$f"
check "still exactly one 2.0.0 heading" "1" "$(grep -c '^## \[2\.0\.0\]' "$f")"
check "stale content is gone" "0" "$(grep -c 'stale draft' "$f")"
check "fresh content present" "1" "$(grep -c 'final correct content' "$f")"
check "fresh Fixed section present" "1" "$(grep -c 'also this' "$f")"
rm -f "$f"

# --- replacing a version that ISN'T the most recent doesn't disturb neighbors ---
f=$(mktemp)
cat > "$f" <<'EOF'
# Changelog

## [3.0.0] - 2026-05-01

### Added
- newest

## [2.0.0] - 2026-04-01

### Added
- middle, stale

## [1.0.0] - 2026-03-01

### Added
- oldest
EOF
printf '## [2.0.0] - 2026-04-01\n\n### Added\n- middle, fixed\n' | bash "$SCRIPT" --version 2.0.0 --file "$f"
check "three headings still present" "3" "$(grep -c '^## \[' "$f")"
check "newest untouched" "1" "$(grep -c 'newest' "$f")"
check "middle replaced" "1" "$(grep -c 'middle, fixed' "$f")"
check "middle stale text gone" "0" "$(grep -c 'middle, stale' "$f")"
check "oldest untouched" "1" "$(grep -c 'oldest' "$f")"
rm -f "$f"

# --- idempotent: running twice in a row with identical input converges ---
f=$(mktemp -u)
section=$'## [4.0.0] - 2026-06-01\n\n### Added\n- idempotency check\n'
printf '%s' "$section" | bash "$SCRIPT" --version 4.0.0 --file "$f"
printf '%s' "$section" | bash "$SCRIPT" --version 4.0.0 --file "$f"
check "one heading after two identical runs" "1" "$(grep -c '^## \[4\.0\.0\]' "$f")"
rm -f "$f"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-update-changelog.sh`
Expected: fails immediately (script doesn't exist).

- [ ] **Step 3: Implement `scripts/update-changelog.sh`**

```bash
#!/usr/bin/env bash
# update-changelog.sh — insert or replace-in-place one Keep a Changelog
# section, read from stdin. Idempotent per version: never duplicates.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="$SCRIPT_DIR/../CHANGELOG.md"
VERSION=""

usage() {
  echo "usage: update-changelog.sh --version X.Y.Z [--file <path>] < section.md" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --file)    FILE="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "error: --version is required" >&2; usage; exit 2
fi

SECTION="$(cat)"
if [[ -z "$SECTION" ]]; then
  echo "error: no section text on stdin" >&2; exit 2
fi

HEADER='# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).'

if [[ ! -f "$FILE" ]]; then
  {
    printf '%s\n\n' "$HEADER"
    printf '%s\n' "$SECTION"
  } > "$FILE"
  exit 0
fi

ESC_VERSION="${VERSION//./\\.}"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

SECTION="$SECTION" ESC_VERSION="$ESC_VERSION" awk -v version="$ESC_VERSION" -v section="$SECTION" '
BEGIN {
  target = "^## \\[" version "\\]"
  inserted = 0
  skipping = 0
}
{
  if (!skipping && $0 ~ target) {
    skipping = 1
    next
  }
  if (skipping) {
    if ($0 ~ /^## \[/) {
      skipping = 0
    } else {
      next
    }
  }
  if (!inserted && $0 ~ /^## \[/) {
    print section
    print ""
    inserted = 1
  }
  print $0
}
END {
  if (!inserted) {
    print section
  }
}
' "$FILE" > "$TMP"

mv "$TMP" "$FILE"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-update-changelog.sh`
Expected: `PASS=<N> FAIL=0` (19 checks total).

If the "inserts new version above older ones" case fails because the blank-line spacing looks off, that's fine as long as heading order and content-presence checks pass — the tests intentionally don't pin exact blank-line counts, only content and ordering.

- [ ] **Step 5: Make it executable and commit**

```bash
chmod +x scripts/update-changelog.sh
git add scripts/update-changelog.sh tests/test-update-changelog.sh
git commit -m "feat: add update-changelog.sh for idempotent replace-in-place changelog writes"
```

---

## Task 6: Wire changelog generation into `make release` + `make models`

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: `scripts/gen-changelog.sh` (Task 4), `scripts/update-changelog.sh` (Task 5), `scripts/sync-models.sh --check` (Task 8 — not built yet; this task references it but Task 8 must land before `make release` is actually run for real; the Makefile change itself doesn't require the script to exist to be *written*, but running `make release` before Task 8 exists will fail at that step, which is expected and fine since nothing runs `make release` until Task 9's rollout).
- Produces: `make models` (prints the mapping); `make release` now also updates `CHANGELOG.md` and checks doc drift before committing.

This task has no bash unit test of its own (Makefile recipes aren't easily unit-testable in isolation); it's verified by a manual scratch-clone run in Step 3, matching the spec's own Testing section.

- [ ] **Step 1: Add `MODELS_JSON` variable and `models` target**

In `Makefile`, near the top where `PLUGIN_JSON` is defined:

```makefile
PLUGIN_JSON := .claude-plugin/plugin.json
```

change to:

```makefile
PLUGIN_JSON := .claude-plugin/plugin.json
MODELS_JSON := .claude-plugin/models.json
```

And add a new target (near `version:`):

```makefile
# Pretty-print the current coder/reviewer model mapping.
models:
	@jq . $(MODELS_JSON)
```

Add `models` to the `.PHONY` line: change

```makefile
.PHONY: bump-patch bump-minor bump-major release version
```

to

```makefile
.PHONY: bump-patch bump-minor bump-major release version models
```

- [ ] **Step 2: Extend the `release` target**

Replace the existing `release:` recipe:

```makefile
release:
	@ver=$$(jq -r '.version' $(PLUGIN_JSON)); \
	if git diff --quiet && git diff --cached --quiet; then \
	  echo "nothing to release: working tree clean (did you run a bump target?)" >&2; exit 1; \
	fi; \
	git add -A; \
	git commit -m "release: v$$ver"; \
	git push; \
	echo "released v$$ver"
```

with:

```makefile
release:
	@ver=$$(jq -r '.version' $(PLUGIN_JSON)); \
	if git diff --quiet && git diff --cached --quiet; then \
	  echo "nothing to release: working tree clean (did you run a bump target?)" >&2; exit 1; \
	fi; \
	scripts/sync-models.sh --check || { \
	  echo "docs are stale relative to $(MODELS_JSON) — run scripts/sync-models.sh, review the diff, and commit first" >&2; \
	  exit 1; \
	}; \
	scripts/gen-changelog.sh --version "$$ver" | scripts/update-changelog.sh --version "$$ver"; \
	git add -A; \
	git commit -m "release: v$$ver"; \
	git push; \
	echo "released v$$ver"
```

- [ ] **Step 3: Manually verify against a scratch clone**

```bash
tmp=$(mktemp -d)
git clone -q "$(pwd)" "$tmp"
cd "$tmp"
echo "# scratch test" >> README.md
git add README.md && git commit -q -m "docs: scratch test change"
jq '.version = "99.0.0"' .claude-plugin/plugin.json > /tmp/pj.json && mv /tmp/pj.json .claude-plugin/plugin.json
git add .claude-plugin/plugin.json && git commit -q -m "chore: bump for scratch test"
make release 2>&1 | tail -20
```

Expected at this point in the plan (Task 8 not built yet): the recipe fails at the `scripts/sync-models.sh --check` line with `No such file or directory` — that's the correct, expected failure for now. Confirm the failure happens at that step (not earlier, not with a Makefile syntax error) by checking the output mentions `sync-models.sh`. Clean up:

```bash
cd - && rm -rf "$tmp"
```

Re-run this same manual check at the end of Task 9 (after `sync-models.sh` exists for real) to confirm the full chain works — that's this task's actual pass criterion; a Makefile-only change can't be fully verified until its dependencies exist, so Step 3 here only confirms the wiring reaches the right place and Task 9 confirms it completes end-to-end.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat: wire changelog generation and models drift-check into make release"
```

---

## Task 7: `scripts/sync-models.sh` — part A: config validation + templated fields

**Files:**
- Create: `scripts/sync-models.sh`
- Test: `tests/test-sync-models.sh`

**Interfaces:**
- Consumes: `--models-json <path>` (default `.claude-plugin/models.json` relative to script), `--repo-dir <path>` (default script's `..`), `--check` (dry-run flag).
- Produces (this part): validates `models.json`; regenerates `description` in `<repo-dir>/.claude-plugin/plugin.json` and `<repo-dir>/.claude-plugin/marketplace.json`; regenerates the `description:` frontmatter line in the four agent/command files. Never touches `keywords`. Exit 0 on success (or on `--check` finding no drift), non-zero otherwise, printing which check/file failed.
- This part does NOT yet handle marker spans or full write-atomicity across many files — that's Task 8, which extends the same script.

- [ ] **Step 1: Write the failing test**

Create `tests/test-sync-models.sh`. This test builds a scratch repo dir with just the files `sync-models.sh` needs to touch, so it never risks the real repo's files:

```bash
#!/usr/bin/env bash
# Unit tests for sync-models.sh. Run: bash tests/test-sync-models.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/sync-models.sh"

PASS=0
FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1 (expected [$2], got [$3])"; FAIL=$((FAIL+1))
  fi
}

make_fixture_repo() {  # make_fixture_repo <dir>
  local d="$1"
  mkdir -p "$d/.claude-plugin" "$d/agents" "$d/commands"
  cat > "$d/.claude-plugin/models.json" <<'EOF'
{"coder": {"id": "fixture-coder", "label": "Fixture Coder Label"}, "reviewer": {"id": "fixture-reviewer", "label": "Fixture Reviewer Label"}}
EOF
  cat > "$d/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "fixture-plugin",
  "description": "placeholder",
  "version": "1.0.0",
  "keywords": ["cursor", "gpt-5.5", "delegation"]
}
EOF
  cat > "$d/.claude-plugin/marketplace.json" <<'EOF'
{"plugins": [{"name": "fixture-plugin", "description": "placeholder"}]}
EOF
  cat > "$d/agents/cursor-coder-delegator.md" <<'EOF'
---
name: cursor-coder-delegator
description: placeholder
model: haiku
tools: Bash, Read
---
body text unrelated to sync
EOF
  cat > "$d/agents/cursor-reviewer-delegator.md" <<'EOF'
---
name: cursor-reviewer-delegator
description: placeholder
model: haiku
tools: Bash, Read
---
body text unrelated to sync
EOF
  cat > "$d/commands/cursor-implement-plans.md" <<'EOF'
---
description: placeholder
argument-hint: <path>
---
body text unrelated to sync
EOF
  cat > "$d/commands/cursor-review.md" <<'EOF'
---
description: placeholder
argument-hint: <path>
---
body text unrelated to sync
EOF
}

# --- happy path: regenerates all five templated fields correctly ---
REPO=$(mktemp -d)
make_fixture_repo "$REPO"
bash "$SCRIPT" --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json"

check "plugin.json description mentions coder label" "1" \
  "$(jq -r '.description' "$REPO/.claude-plugin/plugin.json" | grep -c 'Fixture Coder Label')"
check "plugin.json description mentions reviewer label" "1" \
  "$(jq -r '.description' "$REPO/.claude-plugin/plugin.json" | grep -c 'Fixture Reviewer Label')"
check "plugin.json keywords untouched (still has stale gpt-5.5)" "1" \
  "$(jq -r '.keywords | @csv' "$REPO/.claude-plugin/plugin.json" | grep -c 'gpt-5.5')"
check "marketplace.json description mentions coder label" "1" \
  "$(jq -r '.plugins[0].description' "$REPO/.claude-plugin/marketplace.json" | grep -c 'Fixture Coder Label')"
check "marketplace.json description mentions reviewer label" "1" \
  "$(jq -r '.plugins[0].description' "$REPO/.claude-plugin/marketplace.json" | grep -c 'Fixture Reviewer Label')"
check "coder agent frontmatter description updated" "1" \
  "$(grep '^description:' "$REPO/agents/cursor-coder-delegator.md" | grep -c 'Fixture Coder Label')"
check "coder agent body untouched" "1" \
  "$(grep -c 'body text unrelated to sync' "$REPO/agents/cursor-coder-delegator.md")"
check "reviewer agent frontmatter description updated" "1" \
  "$(grep '^description:' "$REPO/agents/cursor-reviewer-delegator.md" | grep -c 'Fixture Reviewer Label')"
check "coder command frontmatter description updated" "1" \
  "$(grep '^description:' "$REPO/commands/cursor-implement-plans.md" | grep -c 'Fixture Coder Label')"
check "reviewer command frontmatter description updated" "1" \
  "$(grep '^description:' "$REPO/commands/cursor-review.md" | grep -c 'Fixture Reviewer Label')"
check "other frontmatter keys untouched (name:)" "1" \
  "$(grep -c '^name: cursor-coder-delegator$' "$REPO/agents/cursor-coder-delegator.md")"
rm -rf "$REPO"

# --- validation: invalid label charset -> refuse, zero files touched ---
REPO=$(mktemp -d)
make_fixture_repo "$REPO"
cat > "$REPO/.claude-plugin/models.json" <<'EOF'
{"coder": {"id": "fixture-coder", "label": "Bad: Label"}, "reviewer": {"id": "fixture-reviewer", "label": "Fine Label"}}
EOF
BEFORE=$(jq -r '.description' "$REPO/.claude-plugin/plugin.json")
bash "$SCRIPT" --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json" 2>/dev/null; rc=$?
AFTER=$(jq -r '.description' "$REPO/.claude-plugin/plugin.json")
check "invalid label exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "invalid label -> plugin.json untouched" "$BEFORE" "$AFTER"
rm -rf "$REPO"

# --- validation: invalid id charset -> refuse ---
REPO=$(mktemp -d)
make_fixture_repo "$REPO"
cat > "$REPO/.claude-plugin/models.json" <<'EOF'
{"coder": {"id": "bad id with spaces", "label": "Fine Label"}, "reviewer": {"id": "fixture-reviewer", "label": "Fine Label"}}
EOF
bash "$SCRIPT" --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json" 2>/dev/null; rc=$?
check "invalid id exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rm -rf "$REPO"

# --- validation: missing key -> refuse ---
REPO=$(mktemp -d)
make_fixture_repo "$REPO"
echo '{"coder": {"id": "x", "label": "y"}}' > "$REPO/.claude-plugin/models.json"
bash "$SCRIPT" --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json" 2>/dev/null; rc=$?
check "missing .reviewer key exits non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rm -rf "$REPO"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-sync-models.sh`
Expected: fails immediately (script doesn't exist).

- [ ] **Step 3: Implement `scripts/sync-models.sh` (part A — validation + templated fields; `--check` and markers come in Task 8)**

```bash
#!/usr/bin/env bash
# sync-models.sh — regenerate every doc that names the coder/reviewer model
# from .claude-plugin/models.json. See docs/superpowers/specs/2026-07-18-*
# for the full design (templated fields vs marker-wrapped spans).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR/.."
MODELS_JSON="$REPO_DIR/.claude-plugin/models.json"
CHECK=0

usage() {
  echo "usage: sync-models.sh [--check] [--repo-dir <path>] [--models-json <path>]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)      CHECK=1; shift ;;
    --repo-dir)   REPO_DIR="${2:-}"; shift 2 ;;
    --models-json) MODELS_JSON="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# --- validate models.json fully before touching any file ---
if [[ ! -r "$MODELS_JSON" ]]; then
  echo "error: models.json missing or unreadable: $MODELS_JSON" >&2; exit 2
fi
if ! jq -e . "$MODELS_JSON" >/dev/null 2>&1; then
  echo "error: models.json is not valid JSON: $MODELS_JSON" >&2; exit 2
fi

CODER_ID="$(jq -r '.coder.id // empty' "$MODELS_JSON")"
CODER_LABEL="$(jq -r '.coder.label // empty' "$MODELS_JSON")"
REVIEWER_ID="$(jq -r '.reviewer.id // empty' "$MODELS_JSON")"
REVIEWER_LABEL="$(jq -r '.reviewer.label // empty' "$MODELS_JSON")"

for name_val in "coder.id:$CODER_ID" "coder.label:$CODER_LABEL" "reviewer.id:$REVIEWER_ID" "reviewer.label:$REVIEWER_LABEL"; do
  name="${name_val%%:*}"
  val="${name_val#*:}"
  if [[ -z "$val" ]]; then
    echo "error: models.json missing or empty .$name" >&2; exit 2
  fi
done

ID_RE='^[A-Za-z0-9._+-]+$'
if [[ ! "$CODER_ID" =~ $ID_RE ]]; then
  echo "error: .coder.id '$CODER_ID' violates the allowed charset $ID_RE" >&2; exit 2
fi
if [[ ! "$REVIEWER_ID" =~ $ID_RE ]]; then
  echo "error: .reviewer.id '$REVIEWER_ID' violates the allowed charset $ID_RE" >&2; exit 2
fi

check_label_charset() {  # check_label_charset <field-name> <value>
  case "$2" in
    *:*|*'"'*|*'`'*)
      echo "error: .$1 '$2' contains a forbidden character (: \" \`)" >&2; exit 2 ;;
  esac
  if printf '%s' "$2" | grep -q $'\n'; then
    echo "error: .$1 contains a newline" >&2; exit 2
  fi
}
check_label_charset "coder.label" "$CODER_LABEL"
check_label_charset "reviewer.label" "$REVIEWER_LABEL"

STALE_FILES=()
TOUCHED_FILES=()

# regen_json_field_arg <file> <jq-path-expr-using-$d> <value>
regen_json_field_arg() {
  local file="$1" expr="$2" value="$3"
  [[ ! -f "$file" ]] && { echo "error: expected file missing: $file" >&2; exit 2; }
  local tmp; tmp="$(mktemp)"
  if ! jq --arg d "$value" "$expr" "$file" > "$tmp"; then
    rm -f "$tmp"; echo "error: jq failed regenerating $file" >&2; exit 2
  fi
  if [[ "$CHECK" -eq 1 ]]; then
    if ! diff -q "$file" "$tmp" >/dev/null 2>&1; then STALE_FILES+=("$file"); fi
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
    TOUCHED_FILES+=("$file")
  fi
}

# regen_frontmatter_description <file> <new-description-text>
regen_frontmatter_description() {
  local file="$1" new="$2"
  [[ ! -f "$file" ]] && { echo "error: expected file missing: $file" >&2; exit 2; }
  local tmp; tmp="$(mktemp)"
  NEW_LINE="description: $new" awk '
    BEGIN { done = 0 }
    {
      if (!done && $0 ~ /^description: /) {
        print ENVIRON["NEW_LINE"]
        done = 1
      } else {
        print
      }
    }
  ' "$file" > "$tmp"
  if [[ "$CHECK" -eq 1 ]]; then
    if ! diff -q "$file" "$tmp" >/dev/null 2>&1; then STALE_FILES+=("$file"); fi
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
    TOUCHED_FILES+=("$file")
  fi
}

# --- plugin.json / marketplace.json descriptions (keywords is never touched) ---
PLUGIN_DESC="Delegate implementation to Cursor's ${CODER_LABEL} and independent design-spec/plan review to ${REVIEWER_LABEL} via cursor-agent, while Claude/Opus plans, decides, and reviews."
MARKETPLACE_DESC="Two Cursor-backed delegation subagents: ${CODER_LABEL} for implementation and ${REVIEWER_LABEL} for independent design/plan review."

regen_json_field_arg "$REPO_DIR/.claude-plugin/plugin.json" '.description = $d' "$PLUGIN_DESC"
regen_json_field_arg "$REPO_DIR/.claude-plugin/marketplace.json" '.plugins[0].description = $d' "$MARKETPLACE_DESC"

# --- frontmatter description: lines ---
CODER_AGENT_DESC="Delegates a single implementation task to Cursor's ${CODER_LABEL} model via cursor-agent, verifies it, and reports back. Use as the implementer in subagent-driven development when delegating coding to Composer. Does not design, review, or write code itself — it delegates and verifies."
REVIEWER_AGENT_DESC="Delegates an independent design-spec or implementation-plan review to ${REVIEWER_LABEL} via cursor-agent in read-only mode, and relays the report. Use as the reviewer when an independent, unbiased review of a spec or plan is needed. Does not author, judge, or edit — it delegates and relays."
CODER_CMD_DESC="Implement a written plan by delegating each task to Cursor's ${CODER_LABEL} (via the cursor-coder-delegator subagent), while Opus reviews. Usage: /cursor-implement-plans <plan-path>"
REVIEWER_CMD_DESC="Get an independent ${REVIEWER_LABEL} review of a design spec or implementation plan, removing the bias of self-review. Usage: /cursor-review <spec|plan> <doc-path> [spec-path]"

regen_frontmatter_description "$REPO_DIR/agents/cursor-coder-delegator.md" "$CODER_AGENT_DESC"
regen_frontmatter_description "$REPO_DIR/agents/cursor-reviewer-delegator.md" "$REVIEWER_AGENT_DESC"
regen_frontmatter_description "$REPO_DIR/commands/cursor-implement-plans.md" "$CODER_CMD_DESC"
regen_frontmatter_description "$REPO_DIR/commands/cursor-review.md" "$REVIEWER_CMD_DESC"

if [[ "$CHECK" -eq 1 && ${#STALE_FILES[@]} -gt 0 ]]; then
  echo "stale (would change on sync):" >&2
  printf '  %s\n' "${STALE_FILES[@]}" >&2
  exit 1
fi

exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-sync-models.sh`
Expected: `PASS=<N> FAIL=0` (16 checks).

- [ ] **Step 5: Make it executable and commit**

```bash
chmod +x scripts/sync-models.sh
git add scripts/sync-models.sh tests/test-sync-models.sh
git commit -m "feat: add sync-models.sh (config validation + templated-field regeneration)"
```

---

## Task 8: `scripts/sync-models.sh` — part B: marker spans, `--check` semantics, atomicity

**Files:**
- Modify: `scripts/sync-models.sh` (extends Task 7's script)
- Modify: `tests/test-sync-models.sh` (extends Task 7's test file)

**Interfaces:**
- Consumes: same as Task 7, plus the fixture files now also contain marker pairs.
- Produces: regenerates the content between `<!-- model:coder:label -->…<!-- /model:coder:label -->` and `<!-- model:reviewer:label -->…<!-- /model:reviewer:label -->` marker pairs in `README.md`, both `agents/*.md` bodies, both `commands/*.md` bodies, both `scripts/*.sh` header comments, and `tests/e2e-smoke.md`. `--check` now also fails if an expected marker pair is entirely missing from a file. Non-`--check` mode writes each target file atomically (temp-then-rename) and, on a failure partway through the full file list, reports exactly which files were reached vs not.

- [ ] **Step 1: Extend the fixture and add failing tests**

In `tests/test-sync-models.sh`, extend `make_fixture_repo()` to also create `README.md`, `scripts/cc-delegate.sh`, `scripts/cr-delegate.sh`, and `tests/e2e-smoke.md`, and add marker pairs to the existing agent/command bodies. Replace the whole `make_fixture_repo` function with:

```bash
make_fixture_repo() {  # make_fixture_repo <dir>
  local d="$1"
  mkdir -p "$d/.claude-plugin" "$d/agents" "$d/commands" "$d/scripts" "$d/tests"
  cat > "$d/.claude-plugin/models.json" <<'EOF'
{"coder": {"id": "fixture-coder", "label": "Fixture Coder Label"}, "reviewer": {"id": "fixture-reviewer", "label": "Fixture Reviewer Label"}}
EOF
  cat > "$d/.claude-plugin/plugin.json" <<'EOF'
{
  "name": "fixture-plugin",
  "description": "placeholder",
  "version": "1.0.0",
  "keywords": ["cursor", "gpt-5.5", "delegation"]
}
EOF
  cat > "$d/.claude-plugin/marketplace.json" <<'EOF'
{"plugins": [{"name": "fixture-plugin", "description": "placeholder"}]}
EOF
  cat > "$d/agents/cursor-coder-delegator.md" <<'EOF'
---
name: cursor-coder-delegator
description: placeholder
model: haiku
tools: Bash, Read
---
You hand a single task to Cursor's <!-- model:coder:label -->old label<!-- /model:coder:label --> model.
EOF
  cat > "$d/agents/cursor-reviewer-delegator.md" <<'EOF'
---
name: cursor-reviewer-delegator
description: placeholder
model: haiku
tools: Bash, Read
---
You hand one review job to <!-- model:reviewer:label -->old label<!-- /model:reviewer:label --> via a script.
EOF
  cat > "$d/commands/cursor-implement-plans.md" <<'EOF'
---
description: placeholder
argument-hint: <path>
---
delegating each task's implementation to <!-- model:coder:label -->old label<!-- /model:coder:label --> (through the subagent).
EOF
  cat > "$d/commands/cursor-review.md" <<'EOF'
---
description: placeholder
argument-hint: <path>
---
named in `$ARGUMENTS` by delegating to <!-- model:reviewer:label -->old label<!-- /model:reviewer:label --> through the subagent.
EOF
  cat > "$d/README.md" <<'EOF'
# fixture readme

- **Implementation** is delegated to Cursor's **<!-- model:coder:label -->old label<!-- /model:coder:label -->**.
- **Independent review** is delegated to **<!-- model:reviewer:label -->old label<!-- /model:reviewer:label -->**.

| agent | Delegates to |
|---|---|
| coder | <!-- model:coder:label -->old label<!-- /model:coder:label --> |
| reviewer | <!-- model:reviewer:label -->old label<!-- /model:reviewer:label --> (read-only) |

Usage: (delegates to <!-- model:reviewer:label -->old label<!-- /model:reviewer:label -->)
EOF
  cat > "$d/scripts/cc-delegate.sh" <<'EOF'
#!/usr/bin/env bash
# cc-delegate.sh — delegate one task to Cursor <!-- model:coder:label -->old label<!-- /model:coder:label --> and verify.
echo unrelated body
EOF
  cat > "$d/scripts/cr-delegate.sh" <<'EOF'
#!/usr/bin/env bash
# cr-delegate.sh — delegate ONE review to <!-- model:reviewer:label -->old label<!-- /model:reviewer:label -->.
echo unrelated body
EOF
  cat > "$d/tests/e2e-smoke.md" <<'EOF'
# Reviewer delegation (cr-delegate.sh — <!-- model:reviewer:label -->old label<!-- /model:reviewer:label -->)
unrelated body
EOF
}
```

Then add these new checks at the end of the "happy path" block (right before `rm -rf "$REPO"` in the first test block):

```bash
check "README coder intro marker updated" "1" \
  "$(grep -c 'Fixture Coder Label' "$REPO/README.md")"
check "README reviewer table cell updated, read-only suffix survives" "1" \
  "$(grep -c 'Fixture Reviewer Label.*(read-only)' "$REPO/README.md")"
check "README no old-label text remains" "0" "$(grep -c 'old label' "$REPO/README.md")"
check "agent body marker updated" "1" \
  "$(grep -c 'Fixture Coder Label' "$REPO/agents/cursor-coder-delegator.md")"
check "command body marker updated" "1" \
  "$(grep -c 'Fixture Reviewer Label' "$REPO/commands/cursor-review.md")"
check "script header marker updated, stays on comment line" "1" \
  "$(grep -c '^# cc-delegate.sh.*Fixture Coder Label' "$REPO/scripts/cc-delegate.sh")"
check "script body untouched" "1" "$(grep -c 'unrelated body' "$REPO/scripts/cc-delegate.sh")"
check "e2e heading marker updated" "1" \
  "$(grep -c 'Fixture Reviewer Label' "$REPO/tests/e2e-smoke.md")"
```

Add a new, separate test block for missing-marker detection:

```bash
# --- --check fails loudly if a required marker pair is missing entirely ---
REPO=$(mktemp -d)
make_fixture_repo "$REPO"
# Strip the coder marker out of the agent file entirely (simulates someone
# removing it, or it never being bootstrapped).
printf -- '---\nname: cursor-coder-delegator\ndescription: placeholder\nmodel: haiku\ntools: Bash, Read\n---\nno marker here at all\n' \
  > "$REPO/agents/cursor-coder-delegator.md"
bash "$SCRIPT" --check --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json" 2>/dev/null; rc=$?
check "--check fails when a required marker is missing" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rm -rf "$REPO"

# --- --check: 0 on a freshly-synced tree, non-zero on stale ---
REPO=$(mktemp -d)
make_fixture_repo "$REPO"
bash "$SCRIPT" --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json"
bash "$SCRIPT" --check --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json"; rc=$?
check "--check exits 0 on synced tree" "0" "$rc"
# Now mutate models.json without re-running sync.
cat > "$REPO/.claude-plugin/models.json" <<'EOF'
{"coder": {"id": "fixture-coder-2", "label": "Changed Label"}, "reviewer": {"id": "fixture-reviewer", "label": "Fixture Reviewer Label"}}
EOF
bash "$SCRIPT" --check --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json"; rc=$?
check "--check exits non-zero on drift" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rm -rf "$REPO"

# --- atomicity: a write failure partway through still reports which files it reached ---
REPO=$(mktemp -d)
make_fixture_repo "$REPO"
chmod 444 "$REPO/tests/e2e-smoke.md"  # force a write failure on the LAST file sync touches
out=$(bash "$SCRIPT" --repo-dir "$REPO" --models-json "$REPO/.claude-plugin/models.json" 2>&1); rc=$?
check "atomicity: exits non-zero on a write failure" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
check "atomicity: earlier file (plugin.json) was still updated" "1" \
  "$(jq -r '.description' "$REPO/.claude-plugin/plugin.json" | grep -c 'Fixture Coder Label')"
check "atomicity: reports the unreached file" "1" "$(echo "$out" | grep -c 'e2e-smoke.md')"
chmod 644 "$REPO/tests/e2e-smoke.md"
rm -rf "$REPO"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run to verify the new checks fail**

Run: `bash tests/test-sync-models.sh`
Expected: new marker-related checks fail (script doesn't handle markers yet); the missing-marker and atomicity checks likely fail too or error out.

- [ ] **Step 3: Implement marker-span regeneration, `--check` marker-presence, and atomicity**

Extend `scripts/sync-models.sh`. First, remove the leftover unused line and function from Task 7 per that task's note, if not already done. Then add, after the frontmatter-description block and before the final `if [[ "$CHECK" -eq 1 ...`:

```bash
# --- marker-wrapped spans ---
# file:tag pairs this repo requires. Extend this list if a new file gains a
# marker (see the spec's Rollout section for the authoritative inventory).
MARKER_TARGETS=(
  "$REPO_DIR/README.md:coder"
  "$REPO_DIR/README.md:reviewer"
  "$REPO_DIR/agents/cursor-coder-delegator.md:coder"
  "$REPO_DIR/agents/cursor-reviewer-delegator.md:reviewer"
  "$REPO_DIR/commands/cursor-implement-plans.md:coder"
  "$REPO_DIR/commands/cursor-review.md:reviewer"
  "$REPO_DIR/scripts/cc-delegate.sh:coder"
  "$REPO_DIR/scripts/cr-delegate.sh:reviewer"
  "$REPO_DIR/tests/e2e-smoke.md:reviewer"
)

# regen_markers <file> <which: coder|reviewer>
regen_markers() {
  local file="$1" which="$2" value tag
  [[ ! -f "$file" ]] && { echo "error: expected file missing: $file" >&2; exit 2; }
  if [[ "$which" == "coder" ]]; then value="$CODER_LABEL"; else value="$REVIEWER_LABEL"; fi
  tag="model:$which:label"
  if ! grep -q -- "<!-- $tag -->" "$file"; then
    echo "error: required marker <!-- $tag --> missing from $file" >&2
    exit 1
  fi
  local tmp; tmp="$(mktemp)"
  NEW_VALUE="$value" TAG="$tag" perl -0777 -pe '
    my $val = $ENV{NEW_VALUE};
    s/(<!-- \Q$ENV{TAG}\E -->).*?(<!-- \/\Q$ENV{TAG}\E -->)/$1 . $val . $2/ges;
  ' "$file" > "$tmp"
  if [[ "$CHECK" -eq 1 ]]; then
    if ! diff -q "$file" "$tmp" >/dev/null 2>&1; then STALE_FILES+=("$file"); fi
    rm -f "$tmp"
  else
    if ! mv "$tmp" "$file"; then
      echo "error: failed to write $file" >&2
      echo "reached: ${TOUCHED_FILES[*]:-<none>}" >&2
      echo "not reached: $file and everything after it in the file list" >&2
      exit 1
    fi
    TOUCHED_FILES+=("$file")
  fi
}

for entry in "${MARKER_TARGETS[@]}"; do
  file="${entry%%:*}"
  which="${entry##*:}"
  if [[ "$CHECK" -eq 1 ]]; then
    regen_markers "$file" "$which" || exit 1
  else
    # A permission-denied target can't be created as a temp+rename target in
    # the same directory in every environment, so simulate "can't write" by
    # checking writability up front and failing the same way a real I/O
    # error would, reporting progress so far.
    if [[ ! -w "$file" ]]; then
      echo "error: cannot write $file (permission denied or read-only)" >&2
      echo "reached: ${TOUCHED_FILES[*]:-<none>}" >&2
      echo "not reached: $file" >&2
      exit 1
    fi
    regen_markers "$file" "$which"
  fi
done
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-sync-models.sh`
Expected: `PASS=<N> FAIL=0` (33 checks total across both parts).

Debugging notes if a check fails:
- If the README "(read-only)" check fails, confirm the marker in the fixture wraps only the label text, not the trailing `(read-only)` — `perl`'s non-greedy `.*?` between the tag pairs should stop at the first `<!-- /model:reviewer:label -->`, leaving `(read-only)` outside untouched.
- If the atomicity test's "reports the unreached file" check fails, confirm `tests/e2e-smoke.md` really is last in `MARKER_TARGETS` (it is, as written above) — the permission-denied simulation only works on whichever file the test chmod's, so keep the list order and the test's target file in sync.

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-models.sh tests/test-sync-models.sh
git commit -m "feat: add marker-span regeneration, --check, and write atomicity to sync-models.sh"
```

---

## Task 9: Rollout — apply markers/dynamic reads to the real repo, fix the real drift

**Files:**
- Modify: `README.md`
- Modify: `agents/cursor-coder-delegator.md`
- Modify: `agents/cursor-reviewer-delegator.md`
- Modify: `commands/cursor-implement-plans.md`
- Modify: `commands/cursor-review.md`
- Modify: `scripts/cc-delegate.sh`
- Modify: `scripts/cr-delegate.sh`
- Modify: `tests/e2e-smoke.md`
- Modify: `.claude-plugin/plugin.json` (manual `keywords` edit — never done by sync)

**Interfaces:**
- Consumes: `scripts/sync-models.sh` (Tasks 7+8), the real `.claude-plugin/models.json` (Task 1).
- Produces: every file in the Problem section's original grep inventory is either reading `models.json` live or carries the correct marker/template, and `plugin.json`'s stale `"gpt-5.5"` keyword and `marketplace.json`'s stale "GPT-5.5" wording are gone.

This task is bootstrap + verification, not new logic — no new failing test. Each edit is exact text; apply with your editor's find/replace or a patch, then verify at the end with `sync-models.sh --check` and the full test suite.

- [ ] **Step 1: `README.md` — add all five markers**

```
- **Implementation** is delegated to Cursor's **Composer 2.5**.
```
→
```
- **Implementation** is delegated to Cursor's **<!-- model:coder:label -->Composer 2.5<!-- /model:coder:label -->**.
```

```
- **Independent review** of a design spec or plan is delegated to **Grok 4.5 (high effort, fast)** —
```
→
```
- **Independent review** of a design spec or plan is delegated to **<!-- model:reviewer:label -->Grok 4.5 (high effort, fast)<!-- /model:reviewer:label -->** —
```

```
| `cursor-coder-delegator` | `/cursor-implement-plans <plan-path>` | Composer 2.5 | Shells to Composer, runs the verify command, loops, commits, reports. No code-editing tools. |
```
→
```
| `cursor-coder-delegator` | `/cursor-implement-plans <plan-path>` | <!-- model:coder:label -->Composer 2.5<!-- /model:coder:label --> | Shells to Composer, runs the verify command, loops, commits, reports. No code-editing tools. |
```

```
| `cursor-reviewer-delegator` | `/cursor-review <spec\|plan> <doc-path> [spec-path]` | Grok 4.5 high fast (read-only) | Runs the review script and relays the report verbatim. Cannot author or judge. |
```
→
```
| `cursor-reviewer-delegator` | `/cursor-review <spec\|plan> <doc-path> [spec-path]` | <!-- model:reviewer:label -->Grok 4.5 (high effort, fast)<!-- /model:reviewer:label --> (read-only) | Runs the review script and relays the report verbatim. Cannot author or judge. |
```

```
**Review a spec or plan** (delegates to Grok 4.5):
```
→
```
**Review a spec or plan** (delegates to <!-- model:reviewer:label -->Grok 4.5 (high effort, fast)<!-- /model:reviewer:label -->):
```

- [ ] **Step 2: `agents/cursor-coder-delegator.md` — body marker**

```
You hand a single task to Cursor's Composer 2.5 model (via a bundled script),
```
→
```
You hand a single task to Cursor's <!-- model:coder:label -->Composer 2.5<!-- /model:coder:label --> model (via a bundled script),
```

- [ ] **Step 3: `agents/cursor-reviewer-delegator.md` — body marker**

```
write anything yourself. You hand one review job to Grok 4.5 (high effort, fast) via a
```
→
```
write anything yourself. You hand one review job to <!-- model:reviewer:label -->Grok 4.5 (high effort, fast)<!-- /model:reviewer:label --> via a
```

- [ ] **Step 4: `commands/cursor-implement-plans.md` — body marker + dynamic healthcheck**

```
delegating each task's implementation to Composer 2.5 (through the
```
→
```
delegating each task's implementation to <!-- model:coder:label -->Composer 2.5<!-- /model:coder:label --> (through the
```

```
   cursor-agent -p --force --trust --model composer-2.5 "Reply with the single word READY."
```
→
```
   CODER_MODEL=$(jq -er '.coder.id' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/models.json")
   if [[ -z "$CODER_MODEL" ]]; then
     echo "error: could not read .coder.id from models.json"; exit 2
   fi
   cursor-agent -p --force --trust --model "$CODER_MODEL" "Reply with the single word READY."
```

- [ ] **Step 5: `commands/cursor-review.md` — body marker + dynamic healthcheck**

```
named in `$ARGUMENTS` by delegating to Grok 4.5 (high effort, fast) through the
```
→
```
named in `$ARGUMENTS` by delegating to <!-- model:reviewer:label -->Grok 4.5 (high effort, fast)<!-- /model:reviewer:label --> through the
```

```
   cursor-agent -p --force --trust --mode ask --model cursor-grok-4.5-high-fast "Reply with the single word READY."
```
→
```
   REVIEWER_MODEL=$(jq -er '.reviewer.id' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/models.json")
   if [[ -z "$REVIEWER_MODEL" ]]; then
     echo "error: could not read .reviewer.id from models.json"; exit 2
   fi
   cursor-agent -p --force --trust --mode ask --model "$REVIEWER_MODEL" "Reply with the single word READY."
```

- [ ] **Step 6: `scripts/cc-delegate.sh` and `scripts/cr-delegate.sh` — header markers**

In `scripts/cc-delegate.sh`:
```
# cc-delegate.sh — delegate one task to Cursor Composer 2.5 and verify.
```
→
```
# cc-delegate.sh — delegate one task to Cursor <!-- model:coder:label -->Composer 2.5<!-- /model:coder:label --> and verify.
```

In `scripts/cr-delegate.sh`:
```
# cr-delegate.sh — delegate ONE design-spec or plan review to Grok 4.5 (high effort, fast)
```
→
```
# cr-delegate.sh — delegate ONE design-spec or plan review to <!-- model:reviewer:label -->Grok 4.5 (high effort, fast)<!-- /model:reviewer:label -->
```

- [ ] **Step 7: `tests/e2e-smoke.md` — heading marker + dynamic probe**

```
# Reviewer delegation (cr-delegate.sh — Grok 4.5 high fast)

Prereqs: `cursor-agent login` done; the probe
`cursor-agent -p --force --trust --mode ask --model cursor-grok-4.5-high-fast "Reply READY."`
returns `READY`.
```
→
```
# Reviewer delegation (cr-delegate.sh — <!-- model:reviewer:label -->Grok 4.5 (high effort, fast)<!-- /model:reviewer:label -->)

Prereqs: `cursor-agent login` done; the probe below returns `READY`:
```bash
REVIEWER_MODEL=$(jq -er '.reviewer.id' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/models.json")
if [[ -z "$REVIEWER_MODEL" ]]; then
  echo "error: could not read .reviewer.id from models.json"; exit 2
fi
cursor-agent -p --force --trust --mode ask --model "$REVIEWER_MODEL" "Reply READY."
```
```

- [ ] **Step 8: Run `sync-models.sh` for real and manually fix `keywords`**

```bash
scripts/sync-models.sh
jq '.keywords -= ["gpt-5.5"]' .claude-plugin/plugin.json > /tmp/pj.json && mv /tmp/pj.json .claude-plugin/plugin.json
```

- [ ] **Step 9: Review the full diff**

```bash
git diff
```

Confirm: every marker span now shows the real label (`Composer 2.5` / `Grok 4.5 (high effort, fast)`) with no leftover `old label`/placeholder text; `plugin.json`'s `description` and `keywords` no longer mention GPT-5.5/gpt-5.5; `marketplace.json`'s `description` no longer says "GPT-5.5"; both command files' healthcheck probes now read `models.json` dynamically; `tests/e2e-smoke.md`'s probe does too.

- [ ] **Step 10: Run the full test suite + drift check**

```bash
bash tests/test-cc-delegate.sh
bash tests/test-cr-delegate.sh
bash tests/test-gen-changelog.sh
bash tests/test-update-changelog.sh
bash tests/test-sync-models.sh
scripts/sync-models.sh --check
```

Expected: every test file prints `FAIL=0`; `sync-models.sh --check` exits 0 with no output (tree is now fully synced).

- [ ] **Step 11: Re-run Task 6's scratch-clone manual check, now end-to-end**

```bash
tmp=$(mktemp -d)
git clone -q "$(pwd)" "$tmp"
cd "$tmp"
echo "# scratch test" >> README.md
git add README.md && git commit -q -m "docs: scratch test change"
jq '.version = "99.0.0"' .claude-plugin/plugin.json > /tmp/pj.json && mv /tmp/pj.json .claude-plugin/plugin.json
git add .claude-plugin/plugin.json && git commit -q -m "chore: bump for scratch test"
make release 2>&1 | tail -30
cat CHANGELOG.md
```

Expected: `make release` succeeds (it will actually push from the scratch clone back to your local repo's default branch — that's fine for a throwaway scratch clone pointed at a local path, but do **not** run this variant against the real `origin` remote). `CHANGELOG.md` now exists with a `## [99.0.0]` section listing the two scratch commits. Clean up:

```bash
cd - && rm -rf "$tmp"
```

- [ ] **Step 12: Commit the rollout**

```bash
git add -A
git commit -m "feat: roll out models.json markers/dynamic reads, fix stale GPT-5.5 references"
```

---

## Task 10: Drift-coverage test for the dynamic probes

**Files:**
- Modify: `tests/test-sync-models.sh` (or create `tests/test-drift-coverage.sh` — either is fine; this plan uses a new small file to keep it independent of the sync-models fixture harness)
- Test: `tests/test-drift-coverage.sh`

**Interfaces:**
- Consumes: the real repo files modified in Task 9.
- Produces: a grep-based check that the four dynamic probes (two command healthchecks, the e2e-smoke.md probe, and both delegate scripts) reference `models.json`/a shell variable for `--model`, never a literal model-id string — catching a hand-reverted hardcode that `sync-models.sh --check` structurally can't see (those spots aren't templated/marked, they're supposed to be dynamic).

- [ ] **Step 1: Write the failing test**

Create `tests/test-drift-coverage.sh`:

```bash
#!/usr/bin/env bash
# Ensures the dynamic --model probes never regress to a hardcoded literal.
# sync-models.sh can't catch this (those spots are runtime-dynamic, not
# templated/marked), so this is a standalone grep-based guard.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$HERE/.."

PASS=0
FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1 (expected [$2], got [$3])"; FAIL=$((FAIL+1))
  fi
}

no_literal_model() {  # no_literal_model <description> <file>
  # A --model flag followed directly by a quoted variable ($VAR or "$VAR")
  # is fine; a literal id string (composer-2.5, cursor-grok-4.5-high-fast)
  # right after --model is the regression this guards against.
  check "$1" "0" "$(grep -Ec -- '--model[[:space:]]+"?(composer-2\.5|cursor-grok-4\.5-high-fast)"?' "$2")"
}

no_literal_model "cc-delegate.sh has no hardcoded --model" "$REPO/scripts/cc-delegate.sh"
no_literal_model "cr-delegate.sh has no hardcoded --model" "$REPO/scripts/cr-delegate.sh"
no_literal_model "cursor-implement-plans.md healthcheck has no hardcoded --model" "$REPO/commands/cursor-implement-plans.md"
no_literal_model "cursor-review.md healthcheck has no hardcoded --model" "$REPO/commands/cursor-review.md"
no_literal_model "e2e-smoke.md probe has no hardcoded --model" "$REPO/tests/e2e-smoke.md"

check "cc-delegate.sh reads MODEL from jq" "1" "$(grep -c 'jq -r .*\.coder\.id' "$REPO/scripts/cc-delegate.sh")"
check "cr-delegate.sh reads MODEL from jq" "1" "$(grep -c 'jq -r .*\.reviewer\.id' "$REPO/scripts/cr-delegate.sh")"
check "cursor-implement-plans.md reads CODER_MODEL from jq" "1" "$(grep -c 'jq -er .*\.coder\.id' "$REPO/commands/cursor-implement-plans.md")"
check "cursor-review.md reads REVIEWER_MODEL from jq" "1" "$(grep -c 'jq -er .*\.reviewer\.id' "$REPO/commands/cursor-review.md")"
check "e2e-smoke.md reads REVIEWER_MODEL from jq" "1" "$(grep -c 'jq -er .*\.reviewer\.id' "$REPO/tests/e2e-smoke.md")"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run it — it should already pass, since Task 9 already made these dynamic**

Run: `bash tests/test-drift-coverage.sh`
Expected: `PASS=10 FAIL=0`. If anything fails, it means Task 9's edits didn't land as specified — go back and re-check the corresponding file/step from Task 9 rather than editing this test to match.

- [ ] **Step 3: Commit**

```bash
git add tests/test-drift-coverage.sh
git commit -m "test: guard the dynamic --model probes against hardcoded regressions"
```

---

## Task 11: Update `README.md`'s Tests section + final full-suite pass

**Files:**
- Modify: `README.md` (the `## Tests` section, currently listing only `test-cc-delegate.sh` and `test-cr-delegate.sh`)

**Interfaces:**
- Produces: the README's test list matches the actual `tests/` directory contents.

- [ ] **Step 1: Update the Tests section**

Find:
```markdown
## Tests
```
bash tests/test-cc-delegate.sh     # coder delegate unit tests (mock cursor-agent)
bash tests/test-cr-delegate.sh     # reviewer delegate unit tests (mock cursor-agent)
```
See `tests/e2e-smoke.md` for the manual end-to-end checks with a real cursor-agent.
```

Replace with:
```markdown
## Tests
```
bash tests/test-cc-delegate.sh       # coder delegate unit tests (mock cursor-agent)
bash tests/test-cr-delegate.sh       # reviewer delegate unit tests (mock cursor-agent)
bash tests/test-gen-changelog.sh     # changelog section generation from commit history
bash tests/test-update-changelog.sh  # idempotent changelog file writes
bash tests/test-sync-models.sh       # models.json -> doc regeneration
bash tests/test-drift-coverage.sh    # guards the dynamic --model probes
```
See `tests/e2e-smoke.md` for the manual end-to-end checks with a real cursor-agent.
```

- [ ] **Step 2: Run every test file to confirm a clean full suite**

```bash
for f in tests/test-*.sh; do
  echo "=== $f ==="
  bash "$f" || echo "!!! $f FAILED !!!"
done
```

Expected: every file prints `FAIL=0` and nothing prints `!!! ... FAILED !!!`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: list the new test files in README's Tests section"
```

---

## Task 12: Bump version, verify `make release` produces a real changelog entry, and land it

**Files:**
- Modify: `.claude-plugin/plugin.json` (version, via `make bump-minor`)
- Create: `CHANGELOG.md` (via `make release`)

**Interfaces:**
- Consumes: everything from Tasks 1–11.
- Produces: this feature's own real release — `CHANGELOG.md` created for the first time, containing every commit made across Tasks 1–11, correctly bucketed.

This is the final integration step, run against the real repo (not a scratch clone) since it's the actual release for this work.

- [ ] **Step 1: Confirm a clean, fully-committed tree**

Run: `git status`
Expected: clean (everything from Tasks 1–11 committed).

- [ ] **Step 2: Bump the version**

This is a `feat`-heavy set of changes (new config file, new scripts, new runtime behavior) that's backward-compatible — no existing command's public interface changed. Use minor:

```bash
make bump-minor
```

- [ ] **Step 3: Run `make release`**

```bash
make release
```

Expected: succeeds; prints `released vX.Y.0`. Do NOT run this step if you're not prepared to push to the real `origin` remote — confirm with the user first if there's any doubt, since `make release` ends with `git push`.

- [ ] **Step 4: Verify the changelog**

```bash
cat CHANGELOG.md
```

Expected: a `## [X.Y.0] - <today>` section exists, with an `### Added` bucket listing the `feat:` commits from Tasks 1–5/7/8/10 and a `### Changed` bucket listing the `docs:`/`test:`/`build:`/`chore:` commits, correctly excluding the intermediate `release:` boundary commits (there are none yet in this range) and any merge commits.

- [ ] **Step 5: No further commit needed** — `make release` already committed and pushed `CHANGELOG.md` together with the version bump.
