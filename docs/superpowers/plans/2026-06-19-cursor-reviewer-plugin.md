# cursor-reviewer-plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Claude Code plugin that delegates independent review of design specs and implementation plans to GPT-5.5 (high effort) via `cursor-agent` in read-only mode, so the model that authored a document never grades it.

**Architecture:** A bash delegate script (`cr-delegate.sh`) assembles a review prompt from bundled rubric files and runs `cursor-agent -p --mode ask --model gpt-5.5-high`, returning one JSON line. A Haiku subagent (`cursor-reviewer-delegator`) runs the script and relays the report verbatim. A slash command (`/cursor-review`) is the Opus-controller entry point: preflight, lens selection, dispatch, triage via `receiving-code-review`. Plugin plumbing mirrors `cursor-coder-plugin`.

**Tech Stack:** Bash 5.x, `jq`, `cursor-agent`, Claude Code plugin format (`.claude-plugin/`), Markdown rubrics.

---

## Reference

This plugin mirrors `/Users/andrey.sloutsman.-nd/Dev/tmp/cursor-coder-plugin`. Conventions to follow:
- Delegate script: ONLY the final STATUS JSON goes to **stdout**; all progress/diagnostics go to **stderr**.
- Binary override via env var so tests can inject a mock (`CR_CURSOR_BIN`).
- Headless cursor-agent flags: `-p --force --trust --approve-mcps --output-format stream-json --model <model>`. This plugin **adds `--mode ask`** (read-only).
- Tests run the real script against a `mock-cursor-agent`.

Working directory is the plugin repo root: `/Users/andrey.sloutsman.-nd/Dev/tmp/cursor-reviewer-plugin` (already a git repo containing only the spec/plan docs).

---

## Task 1: Plugin plumbing (manifest, marketplace, release tooling)

**Files:**
- Create: `.claude-plugin/plugin.json`
- Create: `.claude-plugin/marketplace.json`
- Create: `Makefile`
- Create: `.gitignore`

- [ ] **Step 1: Create `.claude-plugin/plugin.json`**

```json
{
  "name": "cursor-reviewer-plugin",
  "description": "Delegate independent design-spec and implementation-plan review to GPT-5.5 (high effort) via cursor-agent, while Claude/Opus designs and decides.",
  "version": "0.1.0",
  "author": {
    "name": "Andrey Sloutsman"
  },
  "keywords": [
    "cursor",
    "gpt-5.5",
    "review",
    "delegation",
    "subagent",
    "superpowers"
  ]
}
```

- [ ] **Step 2: Create `.claude-plugin/marketplace.json`**

```json
{
  "name": "qc-point",
  "owner": {
    "name": "Andrey Sloutsman"
  },
  "plugins": [
    {
      "name": "cursor-reviewer-plugin",
      "source": "./",
      "description": "Delegate independent design-spec and implementation-plan review to GPT-5.5 (high effort) via cursor-agent, while Claude/Opus designs and decides."
    }
  ]
}
```

- [ ] **Step 3: Create `Makefile`**

```makefile
# Release tooling for cursor-reviewer-plugin.
# Version lives in .claude-plugin/plugin.json and follows semver (MAJOR.MINOR.PATCH).
#
#   make bump-patch   # 0.1.0 -> 0.1.1
#   make bump-minor   # 0.1.1 -> 0.2.0
#   make bump-major   # 0.2.0 -> 1.0.0
#   make release      # commit the version bump and push to origin
#
# Typical flow:  make bump-minor && make release

SHELL := /usr/bin/env bash
PLUGIN_JSON := .claude-plugin/plugin.json

.PHONY: bump-patch bump-minor bump-major release version

# Current version (e.g. "0.1.0").
version:
	@jq -r '.version' $(PLUGIN_JSON)

bump-patch:
	@$(MAKE) --no-print-directory _bump PART=patch

bump-minor:
	@$(MAKE) --no-print-directory _bump PART=minor

bump-major:
	@$(MAKE) --no-print-directory _bump PART=major

# Internal: PART={major|minor|patch}. Reads version, increments the right field,
# zeroes the lower fields, and writes it back to plugin.json.
.PHONY: _bump
_bump:
	@old=$$(jq -r '.version' $(PLUGIN_JSON)); \
	IFS=. read -r MA MI PA <<< "$$old"; \
	case "$(PART)" in \
	  major) MA=$$((MA+1)); MI=0; PA=0 ;; \
	  minor) MI=$$((MI+1)); PA=0 ;; \
	  patch) PA=$$((PA+1)) ;; \
	  *) echo "unknown PART: $(PART)" >&2; exit 2 ;; \
	esac; \
	new="$$MA.$$MI.$$PA"; \
	tmp=$$(mktemp); \
	jq --arg v "$$new" '.version = $$v' $(PLUGIN_JSON) > "$$tmp" && mv "$$tmp" $(PLUGIN_JSON); \
	echo "version: $$old -> $$new"

# Commit the current version and push. Fails if there is nothing to commit.
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

- [ ] **Step 4: Create `.gitignore`**

```gitignore
.DS_Store
*.tmp
```

- [ ] **Step 5: Verify the JSON parses and the Makefile reads the version**

Run:
```bash
jq -e . .claude-plugin/plugin.json >/dev/null && \
jq -e . .claude-plugin/marketplace.json >/dev/null && \
make version
```
Expected: no `jq` errors; final line prints `0.1.0`.

- [ ] **Step 6: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json Makefile .gitignore
git commit -m "feat: plugin manifest, marketplace, and release tooling"
```

---

## Task 2: Review rubric files

These are distilled, GPT-5.5-ready criteria — no Claude-Code scaffolding. The delegate script reads them to build the review prompt. Filenames are load-bearing: the script maps `--target spec` → `spec-review.md`, `--target plan` → `plan-review.md`, and `--lenses X` → `lens-X.md`, plus the shared `_output-format.md`.

**Files:**
- Create: `rubrics/_output-format.md`
- Create: `rubrics/spec-review.md`
- Create: `rubrics/lens-backend.md`
- Create: `rubrics/lens-frontend.md`
- Create: `rubrics/lens-ui.md`
- Create: `rubrics/plan-review.md`

- [ ] **Step 1: Create `rubrics/_output-format.md`**

```markdown
Produce your review in EXACTLY this structure. Be specific — cite the section,
heading, or line of the document for every issue. Do not pad.

## Summary
One paragraph: what the document proposes and your overall judgment.

## Strengths
- What is genuinely well-handled. Be specific; this calibrates trust in the rest.

## Issues

### Critical (must fix before proceeding)
For each: **[location]** — what is wrong — why it matters — how to fix.
Contradictions, missing requirements that block implementation, designs that will
break existing behavior, security or data-loss risks.

### Important (should fix)
Architecture problems, important-but-thinly-covered areas, unhandled error/edge
cases, integration gaps with the existing codebase.

### Minor (nice to have)
Clarity, naming, polish — anything that does not block.

## Codebase Integration & Regression Risk
Based on the existing code you explored: does the proposal fit current patterns?
What existing behavior could it break? Name the files or modules at risk.

## Verdict
One of: **Approve** | **Approve with fixes** | **Needs revision**
Plus one or two sentences of reasoning.

Rules: categorize by ACTUAL severity (not everything is Critical). If the document
itself (not its implementation) is wrong, say so. If you are unsure about something,
explore the repo before flagging it — do not invent issues.
```

- [ ] **Step 2: Create `rubrics/spec-review.md`**

```markdown
You are reviewing a DESIGN SPEC for a software feature. It describes intended
behavior and architecture — not code — so judge the design, completeness, and
clarity against the following criteria.

Internal consistency
- Do any sections contradict each other? Does the stated architecture match the
  feature descriptions and data flow?

Completeness
- Are there placeholders (TBD/TODO), vague requirements, or unanswered questions?
- Is error handling specified? Are failure modes and edge cases addressed?
- Are success criteria and scope (in scope / out of scope) explicit?

Coverage of important-but-thin areas
- Identify areas important to the feature's success but covered only superficially.
  Security, data migration, concurrency, observability, rollback, and backward
  compatibility are common blind spots — flag any that apply and are under-specified.

Ambiguity
- Could any requirement be read two different ways? Name the likely interpretations
  and point out where the spec must disambiguate.

Scope and decomposition
- Is the work focused enough to implement as one unit, or should it be split?
- Are component boundaries clear, with well-defined interfaces?

Fit with the existing codebase (explore the repo)
- Does the design follow existing patterns and conventions?
- Will the new feature break or regress existing behavior? Name specific modules or
  files at risk and explain how.
```

- [ ] **Step 3: Create `rubrics/lens-backend.md`**

```markdown
BACKEND / ARCHITECTURE LENS — apply in addition to the base rubric.

- Data flow: is the path of data through the system clear and sound? Are the
  sources of truth and ownership of state well-defined?
- Interfaces and boundaries: are module/service boundaries clean, with explicit
  contracts? Is coupling minimized?
- Error handling and failure modes: timeouts, retries, partial failures, and
  idempotency where it matters.
- Data and persistence: schema/migration strategy, backward compatibility, data
  integrity, transactions where needed.
- Concurrency and ordering: race conditions, ordering guarantees, idempotency.
- Performance and scalability: hot paths, N+1 patterns, unbounded growth, resource
  limits.
- Security: authn/authz, input validation, secret handling, and injection/SSRF/PII
  surfaces introduced by this design.
- Observability: are logging, metrics, and tracing considered for the new paths?
```

- [ ] **Step 4: Create `rubrics/lens-frontend.md`**

```markdown
FRONTEND DESIGN LENS — apply in addition to the base rubric. Judge from the
described components and structure, plus any markup/styles in the repo.

- Component structure: clear hierarchy, single-responsibility components, sensible
  state ownership, data-down/events-up flow.
- State management: is client state distinguished from server state? Are loading,
  empty, error, and success states all designed — not just the happy path?
- Reusability and consistency: shared components/design tokens reused rather than
  duplicated; consistent with existing UI patterns in the codebase.
- Data fetching: caching, optimistic updates, error/retry behavior, avoiding
  request waterfalls.
- Accessibility: semantic structure, keyboard navigation, focus management, and
  labels/roles — called out, not assumed.
- Performance: bundle/render cost, unnecessary re-renders, large lists
  (virtualization), image/asset strategy.
- Responsiveness: behavior across breakpoints is specified.
```

- [ ] **Step 5: Create `rubrics/lens-ui.md`**

```markdown
UI / UX LENS — apply in addition to the base rubric. Judge the described user
experience and any UI surfaces in the repo.

- Visual hierarchy: is the most important action or information clearly primary?
  Do layout, spacing, and typography support scanning?
- Consistency: spacing scale, color usage, component styling, and interaction
  patterns are consistent with the existing product.
- Affordances and feedback: interactive elements look interactive; every action has
  clear feedback (loading, success, error, disabled).
- Flows: the primary user flow is complete and low-friction; edge flows (empty,
  error, first-run, permission-denied) are designed.
- Content and clarity: labels, microcopy, and error messages are specific and
  actionable.
- Accessibility and inclusivity: color contrast, target sizes, motion/reduced-motion,
  and text scaling considered.
- Responsiveness: the experience holds up on small and large viewports.
```

- [ ] **Step 6: Create `rubrics/plan-review.md`**

```markdown
You are reviewing an IMPLEMENTATION PLAN that an engineer will follow task-by-task.
It should be buildable by someone with no prior context. A reference SPEC may be
provided — check the plan against it.

Spec coverage
- Walk each requirement/section of the spec. Can you point to a task that
  implements it? List any spec requirement with no corresponding task.
- Flag scope creep: tasks that go materially beyond the spec.

Completeness (no placeholders)
- Flag any TBD/TODO, "implement later", "add error handling/validation" without
  specifics, "write tests for the above" without test code, or "similar to Task N"
  cross-references instead of repeated content.
- Code steps must contain actual code, not descriptions.

Task decomposition
- Are tasks bite-sized and independently actionable, with clear boundaries?
- Does each task name exact files to create/modify and exact verification commands
  with expected output?

Type and signature consistency
- Do function/method names, signatures, and property names used in later tasks
  match those defined in earlier tasks? Flag mismatches (e.g. clearLayers vs
  clearFullLayers).

Buildability (explore the repo)
- Could an engineer follow this plan end-to-end without getting stuck or guessing?
- Do the referenced files/paths and existing APIs actually exist in the codebase?
  Flag references to code that is not present.

Calibration: only flag issues that would cause real problems during implementation
— the wrong thing built, the engineer stuck, or broken existing behavior. Stylistic
nits are Minor at most.
```

- [ ] **Step 7: Verify all rubric files exist, are non-empty, and contain no placeholder markers**

Run:
```bash
ls rubrics/_output-format.md rubrics/spec-review.md rubrics/lens-backend.md \
   rubrics/lens-frontend.md rubrics/lens-ui.md rubrics/plan-review.md && \
! grep -rIl -e 'TBD' -e 'FIXME' -e 'XXX' rubrics/ && \
echo "rubrics OK"
```
Expected: all six paths list without error, the `grep` finds nothing (so the `!` makes it succeed), and `rubrics OK` prints. (Note: the literal word "TODO" appears as review *criteria* inside the rubrics, so it is intentionally not in the placeholder scan above.)

- [ ] **Step 8: Commit**

```bash
git add rubrics/
git commit -m "feat: distilled review rubrics (spec, plan, backend/frontend/ui lenses, output format)"
```

---

## Task 3: Delegate script `cr-delegate.sh` (TDD)

The core unit. Write the mock and tests first, watch them fail, then implement the script until they pass.

**Files:**
- Create: `tests/mock-cursor-agent`
- Create: `tests/test-cr-delegate.sh`
- Create: `scripts/cr-delegate.sh`

- [ ] **Step 1: Create the mock `tests/mock-cursor-agent`**

```bash
#!/usr/bin/env bash
# Mock of `cursor-agent` for cr-delegate.sh unit tests. Mimics verified real behavior:
#   - prints stream-json / result JSON to stdout
#   - exits 0 on success, 1 on simulated CLI error
# Controls (env vars):
#   MOCK_FAIL_CLI=1     -> print a plain-text error to stderr, exit 1
#   MOCK_STDERR=<text>  -> also write this text to stderr
#   MOCK_IS_ERROR=1     -> emit well-formed JSON with is_error:true / subtype:error, exit 0
#   MOCK_SESSION=<id>   -> session_id to emit (default sess-mock-1)
#   MOCK_RESULT=<text>  -> result text to emit (default "done"; empty string stays empty)
#   MOCK_STREAM=1       -> emit progress events before the terminal result line
#   MOCK_LOG=<path>     -> append "ARGS: $*" (all argv, incl. the prompt) to this file
set -euo pipefail

if [[ -n "${MOCK_LOG:-}" ]]; then echo "ARGS: $*" >> "$MOCK_LOG"; fi
if [[ -n "${MOCK_STDERR:-}" ]]; then echo "$MOCK_STDERR" >&2; fi
if [[ "${MOCK_FAIL_CLI:-0}" == "1" ]]; then
  echo "Cannot use this model: simulated error." >&2
  exit 1
fi

session="${MOCK_SESSION:-sess-mock-1}"
# Use ${VAR-default} (not :-) so an explicit empty MOCK_RESULT stays empty.
result="${MOCK_RESULT-done}"

if [[ "${MOCK_STREAM:-0}" == "1" ]]; then
  printf '{"type":"system","subtype":"init","cwd":"/tmp","session_id":"%s","model":"gpt-5.5-high","permissionMode":"ask"}\n' "$session"
  printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"reviewing"}]},"session_id":"%s"}\n' "$session"
  printf '{"type":"tool_call","subtype":"started","call_id":"tc1","tool_call":{"readToolCall":{"args":{"path":"README.md"}}},"session_id":"%s"}\n' "$session"
  printf '{"type":"tool_call","subtype":"completed","call_id":"tc1","tool_call":{"readToolCall":{"args":{"path":"README.md"},"result":{"success":{}}}},"session_id":"%s"}\n' "$session"
fi

if [[ "${MOCK_IS_ERROR:-0}" == "1" ]]; then
  printf '{"type":"result","subtype":"error","is_error":true,"duration_ms":10,"result":"%s","session_id":"%s","request_id":"req-mock"}\n' \
    "$result" "$session"
  exit 0
fi

printf '{"type":"result","subtype":"success","is_error":false,"duration_ms":10,"result":"%s","session_id":"%s","request_id":"req-mock","usage":{"inputTokens":1,"outputTokens":1}}\n' \
  "$result" "$session"
exit 0
```

- [ ] **Step 2: Create the test suite `tests/test-cr-delegate.sh`**

```bash
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
```

- [ ] **Step 3: Make the test files executable and run the suite to confirm it FAILS (script absent)**

Run:
```bash
chmod +x tests/mock-cursor-agent tests/test-cr-delegate.sh
bash tests/test-cr-delegate.sh; echo "exit=$?"
```
Expected: FAIL — many checks fail and the run exits non-zero, because `scripts/cr-delegate.sh` does not exist yet (e.g. arg-validation calls return 127, not 2). This confirms the tests exercise a real, missing implementation.

- [ ] **Step 4: Implement `scripts/cr-delegate.sh`**

```bash
#!/usr/bin/env bash
# cr-delegate.sh — delegate ONE design-spec or plan review to GPT-5.5 (high effort)
# via cursor-agent in read-only mode, and return its report.
# Output discipline: ONLY the final STATUS JSON goes to stdout; diagnostics/progress to stderr.
set -uo pipefail

CURSOR_BIN="${CR_CURSOR_BIN:-cursor-agent}"
MODEL="gpt-5.5-high"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: cr-delegate.sh --target spec|plan --doc-file <path> [--spec-file <path>] [--lenses backend,frontend,ui] [--rubric-dir <path>] [--session <id>]" >&2
}

TARGET=""
DOC_FILE=""
SPEC_FILE=""
LENSES=""
RUBRIC_DIR="$SCRIPT_DIR/../rubrics"
SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)     TARGET="${2:-}"; shift 2 ;;
    --doc-file)   DOC_FILE="${2:-}"; shift 2 ;;
    --spec-file)  SPEC_FILE="${2:-}"; shift 2 ;;
    --lenses)     LENSES="${2:-}"; shift 2 ;;
    --rubric-dir) RUBRIC_DIR="${2:-}"; shift 2 ;;
    --session)    SESSION="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# --- arg validation ---
if [[ "$TARGET" != "spec" && "$TARGET" != "plan" ]]; then
  echo "error: --target must be 'spec' or 'plan'" >&2; usage; exit 2
fi
if [[ -z "$DOC_FILE" || ! -r "$DOC_FILE" ]]; then
  echo "error: --doc-file missing or unreadable" >&2; usage; exit 2
fi
if [[ -n "$SPEC_FILE" && ! -r "$SPEC_FILE" ]]; then
  echo "error: --spec-file given but unreadable: $SPEC_FILE" >&2; usage; exit 2
fi

# Map target -> rubric file; both target rubric and the output format are required.
TARGET_RUBRIC="$RUBRIC_DIR/${TARGET}-review.md"
OUTPUT_FMT="$RUBRIC_DIR/_output-format.md"
for f in "$TARGET_RUBRIC" "$OUTPUT_FMT"; do
  if [[ ! -r "$f" ]]; then
    echo "error: required rubric file missing: $f" >&2; exit 2
  fi
done

# Parse + validate lenses (spec reviews). Unknown lens or missing file -> exit 2.
LENS_FILES=()
if [[ -n "$LENSES" ]]; then
  IFS=',' read -ra _lenses <<< "$LENSES"
  for lens in "${_lenses[@]}"; do
    [[ -z "$lens" ]] && continue
    case "$lens" in
      backend|frontend|ui) ;;
      *) echo "error: unknown lens '$lens' (allowed: backend, frontend, ui)" >&2; exit 2 ;;
    esac
    lf="$RUBRIC_DIR/lens-${lens}.md"
    if [[ ! -r "$lf" ]]; then
      echo "error: lens rubric file missing: $lf" >&2; exit 2
    fi
    LENS_FILES+=("$lf")
  done
fi

# --- assemble the review prompt (inlines rubrics; points the reviewer at the doc) ---
assemble_prompt() {
  cat <<EOF
You are an independent, senior software reviewer. You did NOT author the document
under review — your job is to challenge it rigorously and surface problems before
implementation. You have READ-ONLY access to this repository: explore the existing
code as needed to judge how the proposed work fits the current codebase and whether
it risks breaking existing behavior. Do not attempt to modify any files.

The document under review is at: $DOC_FILE
Read it in full before reviewing.
EOF
  if [[ -n "$SPEC_FILE" ]]; then
    echo "The reference spec this document must satisfy is at: $SPEC_FILE"
    echo "Read it too and check the document against it."
  fi
  echo
  echo "Apply the following review rubric:"
  echo
  cat "$TARGET_RUBRIC"
  if [[ ${#LENS_FILES[@]} -gt 0 ]]; then
    for lf in "${LENS_FILES[@]}"; do
      echo
      cat "$lf"
    done
  fi
  echo
  echo "Produce your review in EXACTLY the following format:"
  echo
  cat "$OUTPUT_FMT"
}

PROMPT="$(assemble_prompt)"

# --- run cursor-agent once (read-only), render progress to stderr, keep result event ---
ERR_FILE=$(mktemp)
trap 'rm -f "$ERR_FILE"' EXIT
cursor_err() { cat "$ERR_FILE" 2>/dev/null; }

render_event() {  # render_event <json-line>
  local line="$1" type sub
  type=$(echo "$line" | jq -r '.type // ""' 2>/dev/null) || return 0
  case "$type" in
    assistant)
      local text
      text=$(echo "$line" | jq -r '.message.content[]? | select(.type=="text") | .text' 2>/dev/null)
      [[ -n "$text" ]] && echo "  · $text" >&2
      ;;
    tool_call)
      sub=$(echo "$line" | jq -r '.subtype // ""' 2>/dev/null)
      local tool path
      tool=$(echo "$line" | jq -r '.tool_call | keys[0] // "tool"' 2>/dev/null)
      path=$(echo "$line" | jq -r '.tool_call[]?.args.path // ""' 2>/dev/null)
      echo "  → ${tool} ${sub}${path:+ ($path)}" >&2
      ;;
  esac
}

run_cursor() {  # run_cursor <prompt> [session_id]
  local prompt="$1" sess="${2:-}"
  local rc result_line="" outfile
  : > "$ERR_FILE"
  outfile=$(mktemp)
  # --mode ask: read-only Q&A. --approve-mcps: never block on MCP approval headless.
  local -a cmd=("$CURSOR_BIN" -p --force --trust --approve-mcps --mode ask
                --output-format stream-json --model "$MODEL")
  [[ -n "$sess" ]] && cmd+=(--resume="$sess")
  cmd+=("$prompt")

  "${cmd[@]}" >"$outfile" 2>"$ERR_FILE"
  rc=$?

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$(echo "$line" | jq -r '.type // ""' 2>/dev/null)" == "result" ]]; then
      result_line="$line"
    else
      render_event "$line"
    fi
  done < "$outfile"
  rm -f "$outfile"

  if [[ $rc -ne 0 ]]; then return 1; fi
  if [[ -z "$result_line" ]] || ! echo "$result_line" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  local is_err sub
  is_err=$(echo "$result_line" | jq -r '.is_error // false')
  sub=$(echo "$result_line" | jq -r '.subtype // ""')
  if [[ "$is_err" == "true" || ( -n "$sub" && "$sub" != "success" ) ]]; then
    echo "$result_line" | jq -r '.result // "cursor-agent reported is_error"' > "$ERR_FILE"
    return 1
  fi
  echo "$result_line"
}

emit() {  # emit <status> <session> <target> <lenses_csv> <report> <diagnostic>
  jq -nc \
    --arg status "$1" --arg session "$2" --arg target "$3" \
    --arg lenses "$4" --arg report "$5" --arg diag "$6" \
    '{status:$status, session_id:$session, target:$target,
      lenses:($lenses|split(",")|map(select(length>0))),
      report:$report, diagnostic:$diag}'
}

CURSOR_OUT=$(run_cursor "$PROMPT" "$SESSION") || {
  emit "BLOCKED" "$SESSION" "$TARGET" "$LENSES" "" "cursor-agent invocation failed: $(cursor_err)"
  exit 1
}

SESSION_ID=$(echo "$CURSOR_OUT" | jq -r '.session_id // ""')
REPORT=$(echo "$CURSOR_OUT" | jq -r '.result // ""')

if [[ -z "$REPORT" ]]; then
  emit "BLOCKED" "$SESSION_ID" "$TARGET" "$LENSES" "" "cursor-agent returned an empty review"
  exit 1
fi

emit "REVIEWED" "$SESSION_ID" "$TARGET" "$LENSES" "$REPORT" ""
exit 0
```

- [ ] **Step 5: Make the script executable and syntax-check it**

Run:
```bash
chmod +x scripts/cr-delegate.sh
bash -n scripts/cr-delegate.sh && echo "syntax OK"
```
Expected: `syntax OK`, no errors.

- [ ] **Step 6: Run the test suite to confirm it PASSES**

Run:
```bash
bash tests/test-cr-delegate.sh; echo "exit=$?"
```
Expected: every line prints `ok   - ...`, the summary shows `FAIL=0`, and `exit=0`.

- [ ] **Step 7: Commit**

```bash
git add scripts/cr-delegate.sh tests/mock-cursor-agent tests/test-cr-delegate.sh
git commit -m "feat: cr-delegate.sh read-only review delegate + unit tests"
```

---

## Task 4: Reviewer delegator subagent

**Files:**
- Create: `agents/cursor-reviewer-delegator.md`

- [ ] **Step 1: Create `agents/cursor-reviewer-delegator.md`**

```markdown
---
name: cursor-reviewer-delegator
description: Delegates an independent design-spec or implementation-plan review to GPT-5.5 (high effort) via cursor-agent in read-only mode, and relays the report. Use as the reviewer when an independent, unbiased review of a spec or plan is needed. Does not author, judge, or edit — it delegates and relays.
model: haiku
tools: Bash, Read
---

You are **cursor-reviewer-delegator**, a delegator. You do NOT review, judge, or
write anything yourself. You hand one review job to GPT-5.5 (high effort) via a
bundled script that runs `cursor-agent` in READ-ONLY mode, and you relay the result
back verbatim. The controller (Opus) decides what to do with the findings.

**You have no authority to author, edit, or decide the validity of findings.** You
have no `Write`/`Edit` tools; do not attempt to modify any file by other means
(`Bash` redirection, `sed`, `tee`). You do not filter, reorder, soften, or embellish
the reviewer's report — you pass it through exactly. If the script cannot produce a
review, that is a **BLOCKED** outcome you report — never something you paper over by
writing your own review.

## What you receive in your prompt
- The **target**: `spec` or `plan`.
- The **doc path**: the spec or plan file to review.
- Optionally, a **spec path** (for `plan` reviews — the spec the plan must satisfy).
- Optionally, **lenses** (for `spec` reviews — a comma-separated subset of
  `backend,frontend,ui`).
- Optionally, a **session id** to resume (for a follow-up review round).

## Your procedure
1. Run the delegate script (resolve its path via the plugin root):
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-delegate.sh" \
     --target "<spec|plan>" \
     --doc-file "<doc path>" \
     [--spec-file "<spec path>" only for plan reviews when given] \
     [--lenses "<csv>" only for spec reviews when given] \
     [--session "<id>" only if you were given one to resume]
   ```
   You do NOT pass `--rubric-dir`; the script finds its bundled rubrics next to itself.
2. The script prints ONE line of JSON to stdout:
   `{"status":..., "session_id":..., "target":..., "lenses":..., "report":..., "diagnostic":...}`
   Read it with `jq`. Everything on stderr is progress/diagnostics.
3. Report back (see format). ALWAYS include the `session_id` verbatim so the
   controller can dispatch a follow-up round that resumes the reviewer's context.

## Report format
- **Status:** REVIEWED | BLOCKED
- **Review:** the script's `report` field, reproduced VERBATIM and in full. Do not
  summarize, truncate, or edit it.
- **Reviewer session id:** the script's `session_id`, copied verbatim (REQUIRED).
- **On BLOCKED:** include the script's `diagnostic` so the controller can decide. An
  empty or missing `session_id` together with BLOCKED means cursor-agent never ran a
  real session — report BLOCKED, never REVIEWED.

## Rules
- You never author, edit, or judge. Relaying is your only job.
- If `cursor-agent` is unauthenticated, untrusted, or unavailable, the script returns
  BLOCKED — report that and stop. Fixing the environment is the controller's/user's job.
- Keep stdout parsing strict: only the script's final JSON line matters.
```

- [ ] **Step 2: Verify the frontmatter declares the read-only tool set and Haiku model**

Run:
```bash
grep -q '^model: haiku' agents/cursor-reviewer-delegator.md && \
grep -q '^tools: Bash, Read' agents/cursor-reviewer-delegator.md && \
! grep -qE '(Write|Edit)' agents/cursor-reviewer-delegator.md && \
echo "agent frontmatter OK"
```
Expected: `agent frontmatter OK` (Haiku model, only Bash/Read tools, and no Write/Edit anywhere in the file).

- [ ] **Step 3: Commit**

```bash
git add agents/cursor-reviewer-delegator.md
git commit -m "feat: cursor-reviewer-delegator subagent (delegate + relay, no authoring)"
```

---

## Task 5: `/cursor-review` command

**Files:**
- Create: `commands/cursor-review.md`

- [ ] **Step 1: Create `commands/cursor-review.md`**

````markdown
---
description: Get an independent GPT-5.5 (high effort) review of a design spec or implementation plan, removing the bias of self-review. Usage: /cursor-review <spec|plan> <doc-path> [spec-path]
argument-hint: <spec|plan> <doc-path> [spec-path]
---

You are the **controller**. You will obtain an INDEPENDENT review of the document
named in `$ARGUMENTS` by delegating to GPT-5.5 (high effort) through the
`cursor-reviewer-delegator` subagent. You do NOT review it yourself — that is the
point: the model that authored the document must not be the one that grades it.

## Parse arguments
`$ARGUMENTS` is `<target> <doc-path> [spec-path]` where `target` is `spec` or `plan`.
- If `target` or `doc-path` is missing, ask the user for them and stop.
- `spec-path` is optional and used only for `plan` reviews (the spec the plan must satisfy).

## Preflight (do this first, stop on failure)

1. **Doc exists?** Confirm `doc-path` is a readable file. If not, tell the user and stop.
2. **cursor-agent healthy? Probe for real** — `cursor-agent status` is NOT enough. Run
   an actual read-only headless probe:
   ```
   cursor-agent -p --force --trust --mode ask --model gpt-5.5-high "Reply with the single word READY."
   ```
   If it does not return `READY` (auth error, "Workspace Trust Required", timeout, or
   anything else), tell the user to run `cursor-agent login` (suggest they type
   `! cursor-agent login`) and STOP. (Note: `timeout` is not on macOS by default — do
   not wrap the probe in it.)

## Determine lenses (spec reviews only)

For `target spec`, decide which review lenses apply by reading the spec:
- **backend** — always include.
- **frontend** — include if the spec describes UI components, client state, routes,
  screens, or styling.
- **ui** — include if the spec describes user-facing flows, layouts, or UX.

If it is genuinely unclear whether the spec has a frontend/UI surface, ask the user
once. For `target plan`, do not pass lenses.

## Dispatch the reviewer

Dispatch the **`cursor-reviewer-delegator`** subagent (NOT a general-purpose
subagent). Give it:
- the `target` (`spec` or `plan`),
- the `doc-path`,
- the `spec-path` if this is a plan review,
- the comma-separated `lenses` if this is a spec review.

It shells to the read-only reviewer and returns the report verbatim, plus a
`session_id` and a `status` (REVIEWED | BLOCKED).

If it returns **BLOCKED**, surface the diagnostic to the user and stop — do not
fabricate a review or substitute your own. Fixing the environment (login, trust) is
the user's job.

## Act on the review (you, Opus)

Apply the **superpowers:receiving-code-review** skill to the returned report. Engage
each finding with technical rigor:
- Verify it against the document and the actual codebase before accepting it.
- Where the reviewer is right, plan or make the fix.
- Where the reviewer is wrong, push back with specific reasoning — do not perform
  agreement, and do not reflexively dismiss.

Present a triaged summary to the user (accepted / rejected-with-reason / needs-their-
decision). Offer a fix → re-review loop; on re-review, pass the prior `session_id` to
the subagent so the reviewer resumes its own context.

## Final step: Review Effectiveness Summary (ALWAYS do this)

Produce a short **Review Effectiveness Summary** (≈10–15 lines). Do BOTH: print it,
and append it as a dated entry to `docs/cursor-reviewer/effectiveness-log.md` in the
working repo (create the dir/file if missing; if not writable or the user objects,
just print it and say where it would have gone). Capture:

- **Run:** date · target · doc path · lenses used.
- **Findings:** count by severity (Critical/Important/Minor) · the reviewer's verdict.
- **Triage outcome:** how many findings you accepted vs pushed back on, and why.
- **Reviewer quality:** were findings specific and codebase-grounded, or vague? Any
  false positives (flagged a non-issue) or things it missed that you caught?
- **Environment friction:** auth/trust/timeout, BLOCKED, missing `session_id`.
- **Recommendations:** concrete changes to the rubrics, lens selection, or dispatch
  prompt that would improve the next review.

Base every line on what actually happened this run — do not invent metrics.
````

- [ ] **Step 2: Verify the command frontmatter and key flow markers**

Run:
```bash
grep -q '^description:' commands/cursor-review.md && \
grep -q 'argument-hint:' commands/cursor-review.md && \
grep -q 'cursor-reviewer-delegator' commands/cursor-review.md && \
grep -q 'receiving-code-review' commands/cursor-review.md && \
grep -q 'gpt-5.5-high' commands/cursor-review.md && \
echo "command OK"
```
Expected: `command OK`.

- [ ] **Step 3: Commit**

```bash
git add commands/cursor-review.md
git commit -m "feat: /cursor-review controller command"
```

---

## Task 6: README and E2E smoke doc

**Files:**
- Create: `README.md`
- Create: `tests/e2e-smoke.md`

- [ ] **Step 1: Create `README.md`**

````markdown
# cursor-reviewer-plugin

Delegate **independent design review** to GPT-5.5 (high effort, via `cursor-agent`)
while Claude/Opus designs and decides. The mirror image of `cursor-coder-plugin`:
that plugin delegates *coding*; this one delegates *review* — so the model that wrote
a spec or plan is never the model that grades it.

## Why
In the superpowers workflow, the design spec (`brainstorming` step 7) and the
implementation plan (`writing-plans` Self-Review) are reviewed by the same Opus
session that authored them. Self-review by the author is a structural blind spot.
This plugin replaces that self-review with an independent GPT-5.5 reviewer that runs
**read-only inside your repo**, so it can judge codebase fit and regression risk.

## Roles
- **Opus session** — controller. Authors the spec/plan, dispatches the review, then
  triages findings via `superpowers:receiving-code-review` and decides fixes.
- **cursor-reviewer-delegator** (Haiku subagent) — delegates to the script and relays
  the report. No code-editing tools; cannot author or judge.
- **GPT-5.5 high** (`gpt-5.5-high` via `cursor-agent --mode ask`) — the independent,
  read-only reviewer.

## Requirements
- `cursor-agent` installed and logged in (`cursor-agent login`).
- `jq` and `bash` 5.x on PATH.
- The **superpowers** plugin installed — `/cursor-review` applies its
  `receiving-code-review` skill and plugs into its brainstorming/writing-plans gates.

## Usage
`/cursor-review <spec|plan> <doc-path> [spec-path]`

- Review a design spec:
  `/cursor-review spec docs/superpowers/specs/2026-01-01-foo-design.md`
- Review a plan against its spec:
  `/cursor-review plan docs/superpowers/plans/2026-01-01-foo.md docs/superpowers/specs/2026-01-01-foo-design.md`

### Where it fits the superpowers flow
- At **brainstorming** step 7 (Spec self-review): run `/cursor-review spec <spec-path>`.
- At **writing-plans** Self-Review: run `/cursor-review plan <plan-path> <spec-path>`.

For spec reviews the controller auto-selects review **lenses** (backend always;
frontend/ui when the spec has a UI surface).

## Limitations
- Review is **code- and document-based**, not visual: `cursor-agent` cannot render or
  screenshot a UI. The frontend/UI lenses judge source and the spec, not pixels.
- One read-only pass per review (single-pass, lens-parameterized).

## Installing
This repo also hosts a Claude Code marketplace named **`qc-point`**. Install is two
steps — register the marketplace by pointing at the repo, then install the plugin:

```
/plugin marketplace add <owner>/cursor-reviewer-plugin
/plugin install cursor-reviewer-plugin@qc-point
```

## Updating
```
/plugin marketplace update qc-point
```

## Releasing (maintainers)
Version lives in `.claude-plugin/plugin.json` (semver). The `Makefile` automates it:
```
make bump-minor && make release
```
`make release` refuses to run on a clean tree, so bump first.

## Tests
```
bash tests/test-cr-delegate.sh     # unit tests (mock cursor-agent)
```
See `tests/e2e-smoke.md` for the manual end-to-end check with a real cursor-agent.
````

- [ ] **Step 2: Create `tests/e2e-smoke.md`**

````markdown
# E2E Smoke Test (manual — uses real cursor-agent + GPT-5.5)

Prereqs: `cursor-agent login` done; the probe
`cursor-agent -p --force --trust --mode ask --model gpt-5.5-high "Reply READY."`
returns `READY`.

## Setup
```bash
tmp=$(mktemp -d); cd "$tmp"
git init -q && git commit -q --allow-empty -m "init"
cat > spec.md <<'EOF'
# Widget Cache Design
Goal: add an in-memory cache for widget lookups.
Architecture: a singleton map keyed by widget id, no eviction.
EOF
```

## 1. Spec review (happy path)
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/cr-delegate.sh" \
  --target spec --doc-file "$tmp/spec.md" --lenses backend
```
Expect: stdout is ONE JSON line with `"status":"REVIEWED"`, a non-empty `"report"`,
a real `"session_id"`, and `"lenses":["backend"]`. The report should follow the
output format (Summary / Strengths / Issues / Verdict) and likely flag the "no
eviction" unbounded-growth risk. No files in `$tmp` were modified.

## 2. Plan review against a spec
```bash
cat > plan.md <<'EOF'
# Widget Cache Implementation Plan
Task 1: add cache.py with get(id) and set(id, val).
EOF
bash "$CLAUDE_PLUGIN_ROOT/scripts/cr-delegate.sh" \
  --target plan --doc-file "$tmp/plan.md" --spec-file "$tmp/spec.md"
```
Expect: `"status":"REVIEWED"`, `"target":"plan"`; the report should note missing
eviction coverage / thin task decomposition relative to the spec.

## 3. BLOCKED path (logged out)
Temporarily log out (or unset auth) and re-run command 1. Expect `"status":"BLOCKED"`,
exit code 1, and a `diagnostic` explaining the auth/trust failure. No fabricated review.

## Cleanup
```bash
rm -rf "$tmp"
```
````

- [ ] **Step 3: Verify both docs exist and reference the real command/script names**

Run:
```bash
grep -q '/cursor-review' README.md && \
grep -q 'cr-delegate.sh' tests/e2e-smoke.md && \
echo "docs OK"
```
Expected: `docs OK`.

- [ ] **Step 4: Commit**

```bash
git add README.md tests/e2e-smoke.md
git commit -m "docs: README and manual e2e smoke test"
```

---

## Task 7: Final verification

No new files. Confirm the whole plugin is internally consistent and green.

- [ ] **Step 1: Syntax-check every shell file**

Run:
```bash
bash -n scripts/cr-delegate.sh && \
bash -n tests/mock-cursor-agent && \
bash -n tests/test-cr-delegate.sh && \
echo "all shell syntax OK"
```
Expected: `all shell syntax OK`.

- [ ] **Step 2: Validate every JSON file**

Run:
```bash
jq -e . .claude-plugin/plugin.json >/dev/null && \
jq -e . .claude-plugin/marketplace.json >/dev/null && \
echo "all JSON OK"
```
Expected: `all JSON OK`.

- [ ] **Step 3: Run the full unit-test suite**

Run:
```bash
bash tests/test-cr-delegate.sh; echo "exit=$?"
```
Expected: `FAIL=0` and `exit=0`.

- [ ] **Step 4: Confirm executables and final layout**

Run:
```bash
test -x scripts/cr-delegate.sh && \
test -x tests/mock-cursor-agent && \
ls -1 .claude-plugin agents commands rubrics scripts tests && \
echo "layout OK"
```
Expected: `layout OK`, with `agents/`, `commands/`, `rubrics/`, `scripts/`, `tests/`,
and `.claude-plugin/` all present.

- [ ] **Step 5: Confirm a clean tree (everything committed)**

Run:
```bash
git status --porcelain
```
Expected: empty output. If anything is uncommitted, commit it:
```bash
git add -A && git commit -m "chore: finalize cursor-reviewer-plugin"
```

## Notes for the implementer

- **Read-only is enforced twice on purpose:** `cursor-agent --mode ask` at the CLI
  layer, and the delegator subagent having no `Write`/`Edit` tools. Do not "simplify"
  either away.
- **Output discipline is a hard contract:** `cr-delegate.sh` must print exactly one
  JSON line to stdout; all progress/diagnostics go to stderr. The tests assert the
  single-line invariant.
- **Rubric filenames are an interface** the script depends on (`<target>-review.md`,
  `lens-<name>.md`, `_output-format.md`). Renaming a rubric file breaks prompt
  assembly.
