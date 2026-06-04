#!/usr/bin/env bash
# Unit tests for cc-delegate.sh. Run: bash tests/test-cc-delegate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/cc-delegate.sh"
MOCK="$HERE/mock-cursor-agent"
export CC_CURSOR_BIN="$MOCK"   # script must honor this override

PASS=0
FAIL=0
check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1 (expected [$2], got [$3])"; FAIL=$((FAIL+1))
  fi
}

# --- arg validation ---
out=$(bash "$SCRIPT" 2>/dev/null); rc=$?
check "no args exits 2" "2" "$rc"

tf=$(mktemp); echo "do the thing" > "$tf"
out=$(bash "$SCRIPT" --task-file "$tf" 2>/dev/null); rc=$?
check "missing --verify-cmd exits 2" "2" "$rc"

out=$(bash "$SCRIPT" --task-file /no/such/file --verify-cmd "" 2>/dev/null); rc=$?
check "unreadable task-file exits 2" "2" "$rc"
rm -f "$tf"

# --- invocation + parse (no verify) ---
tf=$(mktemp); echo "implement X" > "$tf"

out=$(MOCK_SESSION=sess-42 MOCK_RESULT=builtit bash "$SCRIPT" --task-file "$tf" --verify-cmd "" 2>/dev/null)
check "no-verify status DONE" "DONE" "$(echo "$out" | jq -r .status)"
check "session captured" "sess-42" "$(echo "$out" | jq -r .session_id)"
check "verified false when no verify cmd" "false" "$(echo "$out" | jq -r .verified)"
check "result captured" "builtit" "$(echo "$out" | jq -r .result)"

# the prompt must instruct Composer to READ the task file (no @file inlining)
log=$(mktemp)
MOCK_LOG="$log" bash "$SCRIPT" --task-file "$tf" --verify-cmd "" >/dev/null 2>&1
check "prompt tells composer to read the file" "1" "$(grep -c -- "$tf" "$log")"
check "invokes with --trust" "1" "$(grep -c -- "--trust" "$log")"
check "invokes composer-2.5 model" "1" "$(grep -c -- "composer-2.5" "$log")"

# CLI failure -> BLOCKED
out=$(MOCK_FAIL_CLI=1 bash "$SCRIPT" --task-file "$tf" --verify-cmd "" 2>/dev/null); rc=$?
check "cli failure status BLOCKED" "BLOCKED" "$(echo "$out" | jq -r .status)"
check "cli failure exit 1" "1" "$rc"
rm -f "$tf" "$log"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
