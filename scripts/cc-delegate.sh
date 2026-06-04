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

# (invocation + verify loop added in later tasks)
echo '{"status":"DONE","session_id":"","attempts":0,"verified":false,"result":"","verify_output":""}'
exit 0
