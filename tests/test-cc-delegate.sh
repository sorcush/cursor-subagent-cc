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

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
