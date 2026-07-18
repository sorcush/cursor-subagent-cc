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
