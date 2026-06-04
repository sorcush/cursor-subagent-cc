#!/usr/bin/env bash
# cc-delegate.sh — delegate one task to Cursor Composer 2.5 and verify.
# Output discipline: ONLY the final STATUS JSON goes to stdout; diagnostics to stderr.
set -uo pipefail

CURSOR_BIN="${CC_CURSOR_BIN:-cursor-agent}"
MODEL="composer-2.5"

usage() {
  echo "usage: cc-delegate.sh --task-file <path> --verify-cmd <cmd> [--max-retries N] [--session <id>]" >&2
}

TASK_FILE=""
VERIFY_CMD=""
VERIFY_CMD_SET=0
MAX_RETRIES=3
SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-file)   TASK_FILE="${2:-}"; shift 2 ;;
    --verify-cmd)  VERIFY_CMD="${2:-}"; VERIFY_CMD_SET=1; shift 2 ;;
    --max-retries) MAX_RETRIES="${2:-3}"; shift 2 ;;
    --session)     SESSION="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$TASK_FILE" || ! -r "$TASK_FILE" ]]; then
  echo "error: --task-file missing or unreadable" >&2; usage; exit 2
fi
if [[ "$VERIFY_CMD_SET" -ne 1 ]]; then
  echo "error: --verify-cmd is required (use \"\" for no verification)" >&2; usage; exit 2
fi

# --- helper: run cursor-agent once, echo JSON on success, return non-zero on failure ---
run_cursor() {  # run_cursor <prompt> [session_id]
  local prompt="$1" sess="${2:-}"
  local out
  if [[ -n "$sess" ]]; then
    out=$("$CURSOR_BIN" -p --force --trust --output-format json --model "$MODEL" --resume="$sess" "$prompt" 2>/dev/null)
  else
    out=$("$CURSOR_BIN" -p --force --trust --output-format json --model "$MODEL" "$prompt" 2>/dev/null)
  fi
  local rc=$?
  if [[ $rc -ne 0 ]]; then return 1; fi
  # plain-text (non-JSON) output is a failure
  if ! echo "$out" | jq -e . >/dev/null 2>&1; then return 1; fi
  echo "$out"
}

emit() {  # emit <status> <session> <attempts> <verified> <result> <verify_output>
  jq -nc \
    --arg status "$1" --arg session "$2" --argjson attempts "$3" \
    --argjson verified "$4" --arg result "$5" --arg vout "$6" \
    '{status:$status, session_id:$session, attempts:$attempts, verified:$verified, result:$result, verify_output:$vout}'
}

PROMPT="Read the file $TASK_FILE and implement the task it describes. Make all necessary code edits."

CURSOR_OUT=$(run_cursor "$PROMPT" "$SESSION") || {
  emit "BLOCKED" "$SESSION" 0 false "" "cursor-agent invocation failed"
  exit 1
}

SESSION_ID=$(echo "$CURSOR_OUT" | jq -r '.session_id // ""')
RESULT_TEXT=$(echo "$CURSOR_OUT" | jq -r '.result // ""')

# No verify command -> trust Composer, report DONE/unverified.
if [[ -z "$VERIFY_CMD" ]]; then
  emit "DONE" "$SESSION_ID" 0 false "$RESULT_TEXT" ""
  exit 0
fi

# Verify, and on failure resume the same session up to MAX_RETRIES times.
attempts=0
verify_out=$(eval "$VERIFY_CMD" 2>&1)
if [[ $? -eq 0 ]]; then
  emit "DONE" "$SESSION_ID" "$attempts" true "$RESULT_TEXT" "$verify_out"
  exit 0
fi

while [[ $attempts -lt $MAX_RETRIES ]]; do
  attempts=$((attempts+1))
  fix_prompt="The verification command failed with this output:

$verify_out

Fix the code so the verification passes. Make all necessary edits."
  CURSOR_OUT=$(run_cursor "$fix_prompt" "$SESSION_ID") || {
    emit "BLOCKED" "$SESSION_ID" "$attempts" false "$RESULT_TEXT" "cursor-agent failed during fix attempt $attempts"
    exit 1
  }
  SESSION_ID=$(echo "$CURSOR_OUT" | jq -r '.session_id // ""')
  RESULT_TEXT=$(echo "$CURSOR_OUT" | jq -r '.result // ""')
  verify_out=$(eval "$VERIFY_CMD" 2>&1)
  if [[ $? -eq 0 ]]; then
    emit "DONE" "$SESSION_ID" "$attempts" true "$RESULT_TEXT" "$verify_out"
    exit 0
  fi
done

emit "BLOCKED" "$SESSION_ID" "$attempts" false "$RESULT_TEXT" "$verify_out"
exit 1
