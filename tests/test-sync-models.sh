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
  "$(grep -c 'You hand a single task' "$REPO/agents/cursor-coder-delegator.md")"
check "reviewer agent frontmatter description updated" "1" \
  "$(grep '^description:' "$REPO/agents/cursor-reviewer-delegator.md" | grep -c 'Fixture Reviewer Label')"
check "coder command frontmatter description updated" "1" \
  "$(grep '^description:' "$REPO/commands/cursor-implement-plans.md" | grep -c 'Fixture Coder Label')"
check "reviewer command frontmatter description updated" "1" \
  "$(grep '^description:' "$REPO/commands/cursor-review.md" | grep -c 'Fixture Reviewer Label')"
check "other frontmatter keys untouched (name:)" "1" \
  "$(grep -c '^name: cursor-coder-delegator$' "$REPO/agents/cursor-coder-delegator.md")"
check "README coder intro marker updated" "1" \
  "$(sed -n '3p' "$REPO/README.md" | grep -c 'Fixture Coder Label')"
check "README reviewer table cell updated, read-only suffix survives" "1" \
  "$(grep -c 'Fixture Reviewer Label.*(read-only)' "$REPO/README.md")"
check "README no old-label text remains" "0" "$(grep -c 'old label' "$REPO/README.md")"
check "agent body marker updated" "1" \
  "$(awk 'BEGIN{p=0} /^---$/{p++} p>=2' "$REPO/agents/cursor-coder-delegator.md" | grep -c 'Fixture Coder Label')"
check "command body marker updated" "1" \
  "$(awk 'BEGIN{p=0} /^---$/{p++} p>=2' "$REPO/commands/cursor-review.md" | grep -c 'Fixture Reviewer Label')"
check "script header marker updated, stays on comment line" "1" \
  "$(grep -c '^# cc-delegate.sh.*Fixture Coder Label' "$REPO/scripts/cc-delegate.sh")"
check "script body untouched" "1" "$(grep -c 'unrelated body' "$REPO/scripts/cc-delegate.sh")"
check "e2e heading marker updated" "1" \
  "$(grep -c 'Fixture Reviewer Label' "$REPO/tests/e2e-smoke.md")"
rm -rf "$REPO"

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
check "atomicity: reports the unreached file" "1" "$(echo "$out" | grep -c 'not reached:.*e2e-smoke.md')"
chmod 644 "$REPO/tests/e2e-smoke.md"
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
