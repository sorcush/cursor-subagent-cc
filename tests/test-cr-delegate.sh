#!/usr/bin/env bash
# Unit tests for cr-delegate.sh. Run: bash tests/test-cr-delegate.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/cr-delegate.sh"
MOCK="$HERE/mock-cursor-agent"
export CR_CURSOR_BIN="$MOCK"   # script must honor this override

PASS=0
FAIL=0
check() {  # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    echo "ok   - $1"; PASS=$((PASS+1))
  else
    echo "FAIL - $1 (expected [$2], got [$3])"; FAIL=$((FAIL+1))
  fi
}
has() {  # has <description> <needle> <file>   (>=1 occurrence => 1)
  check "$1" "1" "$([ "$(grep -c -- "$2" "$3")" -ge 1 ] && echo 1 || echo 0)"
}

# Stub rubric dir with sentinels so we can assert prompt assembly.
RUBRICS=$(mktemp -d)
echo "SPEC_RUBRIC_SENTINEL"   > "$RUBRICS/spec-review.md"
echo "PLAN_RUBRIC_SENTINEL"   > "$RUBRICS/plan-review.md"
echo "BACKEND_LENS_SENTINEL"  > "$RUBRICS/lens-backend.md"
echo "FRONTEND_LENS_SENTINEL" > "$RUBRICS/lens-frontend.md"
echo "UI_LENS_SENTINEL"       > "$RUBRICS/lens-ui.md"
echo "OUTPUT_FORMAT_SENTINEL" > "$RUBRICS/_output-format.md"

doc=$(mktemp); echo "# Some Spec" > "$doc"

# --- arg validation ---
out=$(bash "$SCRIPT" 2>/dev/null); rc=$?
check "no args exits 2" "2" "$rc"

bash "$SCRIPT" --target spec --rubric-dir "$RUBRICS" 2>/dev/null; rc=$?
check "missing --doc-file exits 2" "2" "$rc"

bash "$SCRIPT" --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null; rc=$?
check "missing --target exits 2" "2" "$rc"

bash "$SCRIPT" --target bogus --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null; rc=$?
check "invalid --target exits 2" "2" "$rc"

bash "$SCRIPT" --target spec --doc-file /no/such/file --rubric-dir "$RUBRICS" 2>/dev/null; rc=$?
check "unreadable --doc-file exits 2" "2" "$rc"

bash "$SCRIPT" --target spec --doc-file "$doc" --lenses bogus --rubric-dir "$RUBRICS" 2>/dev/null; rc=$?
check "invalid lens exits 2" "2" "$rc"

bash "$SCRIPT" --target spec --doc-file "$doc" --rubric-dir /no/such/dir 2>/dev/null; rc=$?
check "missing rubric dir exits 2" "2" "$rc"

# --- REVIEWED happy path ---
out=$(MOCK_SESSION=sess-9 MOCK_RESULT=myreview bash "$SCRIPT" \
  --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null)
check "status REVIEWED" "REVIEWED" "$(echo "$out" | jq -r .status)"
check "session captured" "sess-9" "$(echo "$out" | jq -r .session_id)"
check "target captured" "spec" "$(echo "$out" | jq -r .target)"
check "report captured" "myreview" "$(echo "$out" | jq -r .report)"

# --- prompt assembly (mock logs full argv incl. the prompt) ---
log=$(mktemp)
MOCK_LOG="$log" bash "$SCRIPT" --target spec --doc-file "$doc" \
  --lenses backend,ui --rubric-dir "$RUBRICS" >/dev/null 2>&1
has  "prompt tells reviewer to read the doc" "$doc" "$log"
has  "prompt includes spec rubric" "SPEC_RUBRIC_SENTINEL" "$log"
has  "prompt includes selected backend lens" "BACKEND_LENS_SENTINEL" "$log"
has  "prompt includes selected ui lens" "UI_LENS_SENTINEL" "$log"
check "prompt omits unselected frontend lens" "0" "$(grep -c 'FRONTEND_LENS_SENTINEL' "$log")"
has  "prompt includes output format" "OUTPUT_FORMAT_SENTINEL" "$log"
has  "invokes read-only --mode ask" "--mode ask" "$log"
has  "invokes gpt-5.5-high model" "gpt-5.5-high" "$log"
has  "invokes with --trust" "--trust" "$log"
has  "invokes with --approve-mcps" "--approve-mcps" "$log"
has  "invokes stream-json" "--output-format stream-json" "$log"
rm -f "$log"

# --- plan target reads the spec-file ---
spec=$(mktemp); echo "# Ref Spec" > "$spec"
log=$(mktemp)
MOCK_LOG="$log" bash "$SCRIPT" --target plan --doc-file "$doc" \
  --spec-file "$spec" --rubric-dir "$RUBRICS" >/dev/null 2>&1
has "plan: prompt references spec-file" "$spec" "$log"
has "plan: prompt includes plan rubric" "PLAN_RUBRIC_SENTINEL" "$log"
rm -f "$log" "$spec"

# --- lenses emitted as a JSON array ---
out=$(bash "$SCRIPT" --target spec --doc-file "$doc" \
  --lenses backend,frontend --rubric-dir "$RUBRICS" 2>/dev/null)
check "lenses[0] in json" "backend" "$(echo "$out" | jq -r '.lenses[0]')"
check "lenses[1] in json" "frontend" "$(echo "$out" | jq -r '.lenses[1]')"

# --- CLI failure -> BLOCKED ---
out=$(MOCK_FAIL_CLI=1 bash "$SCRIPT" --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null); rc=$?
check "cli failure status BLOCKED" "BLOCKED" "$(echo "$out" | jq -r .status)"
check "cli failure exit 1" "1" "$rc"

out=$(MOCK_FAIL_CLI=1 MOCK_STDERR="boom: untrusted" bash "$SCRIPT" \
  --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null)
check "cli failure captures stderr in diagnostic" "1" \
  "$([ "$(echo "$out" | jq -r .diagnostic | grep -c 'boom: untrusted')" -ge 1 ] && echo 1 || echo 0)"

# --- is_error JSON -> BLOCKED even though exit 0 ---
out=$(MOCK_IS_ERROR=1 bash "$SCRIPT" --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null); rc=$?
check "is_error status BLOCKED" "BLOCKED" "$(echo "$out" | jq -r .status)"
check "is_error exit 1" "1" "$rc"

# --- empty report -> BLOCKED ---
out=$(MOCK_RESULT="" bash "$SCRIPT" --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>/dev/null); rc=$?
check "empty report status BLOCKED" "BLOCKED" "$(echo "$out" | jq -r .status)"
check "empty report exit 1" "1" "$rc"

# --- stream-json: single stdout JSON line + progress to stderr ---
errf=$(mktemp)
out=$(MOCK_STREAM=1 MOCK_SESSION=sess-stream MOCK_RESULT=streamreview bash "$SCRIPT" \
  --target spec --doc-file "$doc" --rubric-dir "$RUBRICS" 2>"$errf")
check "stream: stdout single JSON line" "1" "$(echo "$out" | wc -l | tr -d ' ')"
check "stream: status REVIEWED" "REVIEWED" "$(echo "$out" | jq -r .status)"
check "stream: session from result event" "sess-stream" "$(echo "$out" | jq -r .session_id)"
check "stream: report from result event" "streamreview" "$(echo "$out" | jq -r .report)"
has   "stream: progress rendered to stderr" "README.md" "$errf"
rm -f "$errf"

# --- resume: --session adds --resume ---
log=$(mktemp)
MOCK_LOG="$log" bash "$SCRIPT" --target spec --doc-file "$doc" \
  --session prev-123 --rubric-dir "$RUBRICS" >/dev/null 2>&1
has "session adds --resume" "--resume" "$log"
rm -f "$log"

rm -rf "$RUBRICS"; rm -f "$doc"
echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
