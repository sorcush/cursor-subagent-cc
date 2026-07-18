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
  if [[ "$2" == *$'\n'* ]]; then
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

if [[ "$CHECK" -eq 1 && ${#STALE_FILES[@]} -gt 0 ]]; then
  echo "stale (would change on sync):" >&2
  printf '  %s\n' "${STALE_FILES[@]}" >&2
  exit 1
fi

exit 0
