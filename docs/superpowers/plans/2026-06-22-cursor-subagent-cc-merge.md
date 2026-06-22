# cursor-subagent-cc Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the standalone `cursor-reviewer-plugin` into the existing `cursor-coder-plugin` repo as a single plugin named `cursor-subagent-cc` that ships both the coder-delegator and reviewer-delegator subagents.

**Architecture:** The two plugins are structurally parallel with collision-free core assets (distinct agent `name:` fields, distinct command files, distinct `cc-`/`cr-` script names, reviewer-only `rubrics/`). All script references are `${CLAUDE_PLUGIN_ROOT}`-relative, so the reviewer's `agents/`, `commands/`, `scripts/`, `rubrics/`, test driver, and historical docs copy in with **no edits**. Only five shared-name files need reconciling: both `.claude-plugin/*.json`, the unified `tests/mock-cursor-agent`, `Makefile`, `tests/e2e-smoke.md`, and `README.md`.

**Tech Stack:** Bash 5.x, `jq`, Claude Code plugin/marketplace JSON, `cursor-agent`.

## Global Constraints

- Work happens in the **current** repo: `/Users/andrey.sloutsman.-nd/Dev/tmp/cursor-coder-plugin`. Do NOT rename this directory — it is the live working dir and renaming corrupts the session.
- Reviewer source repo (read-only source for copies): `/Users/andrey.sloutsman.-nd/Dev/tmp/cursor-reviewer-plugin`. Do NOT modify or delete it.
- Plugin name: `cursor-subagent-cc`. Marketplace name: `qc-point` (unchanged). Version: `1.0.0`.
- Marketplace `source` stays `"./"` (relative) — the on-disk directory name is cosmetic.
- The unified mock is the **reviewer's** `mock-cursor-agent` (it uses `${MOCK_RESULT-done}`, a strict superset). Both unit suites must pass against it.
- No edits to copied `agents/`, `commands/`, `scripts/`, `rubrics/` files — they are already `${CLAUDE_PLUGIN_ROOT}`-relative and name-distinct.
- Commit after each task.

---

### Task 1: Bring in reviewer assets + unify the mock; both unit suites green

**Files:**
- Create: `agents/cursor-reviewer-delegator.md` (copy)
- Create: `commands/cursor-review.md` (copy)
- Create: `scripts/cr-delegate.sh` (copy)
- Create: `rubrics/_output-format.md`, `rubrics/lens-backend.md`, `rubrics/lens-frontend.md`, `rubrics/lens-ui.md`, `rubrics/plan-review.md`, `rubrics/spec-review.md` (copy)
- Create: `tests/test-cr-delegate.sh` (copy)
- Modify: `tests/mock-cursor-agent` (overwrite with reviewer's version)
- Create: `docs/superpowers/specs/2026-06-19-cursor-reviewer-plugin-design.md` (copy, historical)
- Create: `docs/superpowers/plans/2026-06-19-cursor-reviewer-plugin.md` (copy, historical)
- Test: `tests/test-cc-delegate.sh` (existing, must still pass), `tests/test-cr-delegate.sh` (copied, must pass)

**Interfaces:**
- Consumes: nothing from later tasks.
- Produces: `scripts/cr-delegate.sh` invoked as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-delegate.sh" --target spec|plan --doc-file <path> [--spec-file <path>] [--lenses ...] [--rubric-dir <path>] [--session <id>]`, defaulting `--rubric-dir` to `${CLAUDE_PLUGIN_ROOT}/rubrics`. Agent `cursor-reviewer-delegator` (model haiku, tools `Bash, Read`). These names are consumed by Task 3's README/e2e docs.

- [ ] **Step 1: Confirm the cr unit suite currently fails (cr-delegate.sh absent)**

```bash
cd /Users/andrey.sloutsman.-nd/Dev/tmp/cursor-coder-plugin
cp /Users/andrey.sloutsman.-nd/Dev/tmp/cursor-reviewer-plugin/tests/test-cr-delegate.sh tests/test-cr-delegate.sh
chmod +x tests/test-cr-delegate.sh
bash tests/test-cr-delegate.sh; echo "exit=$?"
```
Expected: FAIL / non-zero exit — `scripts/cr-delegate.sh` does not exist yet (checks error out, e.g. 127). This confirms the suite exercises real, missing code.

- [ ] **Step 2: Copy the no-edit reviewer assets in**

```bash
cd /Users/andrey.sloutsman.-nd/Dev/tmp/cursor-coder-plugin
src=/Users/andrey.sloutsman.-nd/Dev/tmp/cursor-reviewer-plugin
cp "$src/agents/cursor-reviewer-delegator.md" agents/
cp "$src/commands/cursor-review.md" commands/
cp "$src/scripts/cr-delegate.sh" scripts/
mkdir -p rubrics
cp "$src"/rubrics/*.md rubrics/
mkdir -p docs/superpowers/specs docs/superpowers/plans
cp "$src/docs/superpowers/specs/2026-06-19-cursor-reviewer-plugin-design.md" docs/superpowers/specs/
cp "$src/docs/superpowers/plans/2026-06-19-cursor-reviewer-plugin.md" docs/superpowers/plans/
chmod +x scripts/cr-delegate.sh
```
Expected: no output, exit 0.

- [ ] **Step 3: Unify the mock (adopt the reviewer's version)**

```bash
cd /Users/andrey.sloutsman.-nd/Dev/tmp/cursor-coder-plugin
cp /Users/andrey.sloutsman.-nd/Dev/tmp/cursor-reviewer-plugin/tests/mock-cursor-agent tests/mock-cursor-agent
chmod +x tests/mock-cursor-agent
```
Expected: no output, exit 0.

- [ ] **Step 4: Run the reviewer unit suite against the merged tree**

Run: `bash tests/test-cr-delegate.sh; echo "exit=$?"`
Expected: PASS, `exit=0` (all checks green).

- [ ] **Step 5: Run the coder unit suite against the unified mock (regression check)**

Run: `bash tests/test-cc-delegate.sh; echo "exit=$?"`
Expected: PASS, `exit=0`. The unified (reviewer) mock emits the same stream events including the `README.md` tool_call (line 79 check) and the model assertion reads the args log, so all coder checks still pass.

**Fallback (only if Step 5 fails):** keep two mocks. Restore the coder mock and point the cr suite at its own copy:
```bash
git checkout tests/mock-cursor-agent                       # restore coder's mock
cp /Users/andrey.sloutsman.-nd/Dev/tmp/cursor-reviewer-plugin/tests/mock-cursor-agent tests/mock-cursor-agent-cr
sed -i '' 's#mock-cursor-agent#mock-cursor-agent-cr#g' tests/test-cr-delegate.sh   # only if the cr suite hardcodes the mock name
chmod +x tests/mock-cursor-agent-cr
bash tests/test-cc-delegate.sh && bash tests/test-cr-delegate.sh; echo "exit=$?"
```
Expected: both suites PASS, `exit=0`. (Inspect `tests/test-cr-delegate.sh` to confirm how it locates the mock before editing.)

- [ ] **Step 6: Syntax-check both delegate scripts**

Run: `bash -n scripts/cc-delegate.sh && bash -n scripts/cr-delegate.sh && echo "syntax OK"`
Expected: `syntax OK`.

- [ ] **Step 7: Commit**

```bash
cd /Users/andrey.sloutsman.-nd/Dev/tmp/cursor-coder-plugin
git add agents/cursor-reviewer-delegator.md commands/cursor-review.md scripts/cr-delegate.sh rubrics/ tests/test-cr-delegate.sh tests/mock-cursor-agent docs/superpowers/specs/2026-06-19-cursor-reviewer-plugin-design.md docs/superpowers/plans/2026-06-19-cursor-reviewer-plugin.md
git commit -m "feat: bring reviewer subagent assets into the plugin; unify test mock

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: commit succeeds. (If the fallback ran, also `git add tests/mock-cursor-agent-cr`.)

---

### Task 2: Rename the plugin to `cursor-subagent-cc` in both manifests

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a plugin whose `name` is `cursor-subagent-cc` at version `1.0.0`, installable as `cursor-subagent-cc@qc-point`. Task 3's README documents this install string.

- [ ] **Step 1: Rewrite `.claude-plugin/plugin.json`**

Replace the entire file contents with:
```json
{
  "name": "cursor-subagent-cc",
  "description": "Delegate implementation to Cursor's Composer 2.5 and independent design-spec/plan review to GPT-5.5 (high effort) via cursor-agent, while Claude/Opus plans, decides, and reviews.",
  "version": "1.0.0",
  "author": {
    "name": "Andrey Sloutsman"
  },
  "keywords": [
    "cursor",
    "composer",
    "gpt-5.5",
    "delegation",
    "review",
    "subagent",
    "superpowers"
  ]
}
```

- [ ] **Step 2: Rewrite `.claude-plugin/marketplace.json`**

Replace the entire file contents with:
```json
{
  "name": "qc-point",
  "owner": {
    "name": "Andrey Sloutsman"
  },
  "plugins": [
    {
      "name": "cursor-subagent-cc",
      "source": "./",
      "description": "Two Cursor-backed delegation subagents: Composer 2.5 for implementation and GPT-5.5 (high effort) for independent design/plan review."
    }
  ]
}
```

- [ ] **Step 3: Validate both JSON files and assert the new name**

Run:
```bash
jq . .claude-plugin/plugin.json >/dev/null && jq . .claude-plugin/marketplace.json >/dev/null && \
test "$(jq -r .name .claude-plugin/plugin.json)" = "cursor-subagent-cc" && \
test "$(jq -r .version .claude-plugin/plugin.json)" = "1.0.0" && \
test "$(jq -r '.plugins[0].name' .claude-plugin/marketplace.json)" = "cursor-subagent-cc" && \
test "$(jq -r '.plugins | length' .claude-plugin/marketplace.json)" = "1" && \
echo "manifests OK"
```
Expected: `manifests OK`.

- [ ] **Step 4: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "feat: rename plugin to cursor-subagent-cc (v1.0.0), single qc-point entry

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: commit succeeds.

---

### Task 3: Reconcile docs & tooling (Makefile, e2e-smoke, README, .gitignore)

**Files:**
- Modify: `Makefile` (header comment only)
- Modify: `tests/e2e-smoke.md` (merge in reviewer section)
- Modify: `README.md` (full rewrite)
- Create: `.gitignore`

**Interfaces:**
- Consumes: plugin name/install string from Task 2; agent + script names from Task 1.
- Produces: nothing downstream.

- [ ] **Step 1: Generalize the Makefile header comment**

In `Makefile`, replace the first line:
```
# Release tooling for cursor-coder-plugin.
```
with:
```
# Release tooling for cursor-subagent-cc.
```
(No other Makefile changes — the logic is name-agnostic; it bumps `.version` in `plugin.json`.)

- [ ] **Step 2: Append the reviewer section to `tests/e2e-smoke.md`**

Retitle the document's first line from
`# E2E Smoke Test (manual — uses real cursor-agent + Composer)`
to
`# E2E Smoke Tests (manual — real cursor-agent)`,
then add a top-level divider and the reviewer cases after the existing coder `## Cleanup` section so the file ends with:

````markdown
---

# Reviewer delegation (cr-delegate.sh — GPT-5.5 high)

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

## R1. Spec review (happy path)
```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/cr-delegate.sh" \
  --target spec --doc-file "$tmp/spec.md" --lenses backend
```
Expect: stdout is ONE JSON line with `"status":"REVIEWED"`, a non-empty `"report"`,
a real `"session_id"`, and `"lenses":["backend"]`. The report should follow the
output format (Summary / Strengths / Issues / Verdict) and likely flag the "no
eviction" unbounded-growth risk. No files in `$tmp` were modified.

## R2. Plan review against a spec
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

## R3. BLOCKED path (logged out)
Temporarily log out (or unset auth) and re-run command R1. Expect `"status":"BLOCKED"`,
exit code 1, and a `diagnostic` explaining the auth/trust failure. No fabricated review.

## Cleanup
```bash
rm -rf "$tmp"
```
````

- [ ] **Step 3: Rewrite `README.md`**

Replace the entire file contents with:
````markdown
# cursor-subagent-cc

Two Cursor-backed delegation subagents for the Claude Code / superpowers workflow,
in one plugin. Claude/Opus stays the controller; Cursor's `cursor-agent` does the
work that benefits from a different model:

- **Implementation** is delegated to Cursor's **Composer 2.5**.
- **Independent review** of a design spec or plan is delegated to **GPT-5.5 (high effort)** —
  so the model that authored a doc is never the model that grades it.

## Subagents & commands
| Subagent (Haiku) | Command | Delegates to | Role |
|---|---|---|---|
| `cursor-coder-delegator` | `/cursor-implement-plans <plan-path>` | Composer 2.5 | Shells to Composer, runs the verify command, loops, commits, reports. No code-editing tools. |
| `cursor-reviewer-delegator` | `/cursor-review <spec\|plan> <doc-path> [spec-path]` | GPT-5.5 high (read-only) | Runs the review script and relays the report verbatim. Cannot author or judge. |

Opus is the controller for both: it plans/authors, dispatches the subagent, then
reviews (coder) or triages findings via `superpowers:receiving-code-review` (reviewer).

## Requirements
- `cursor-agent` installed and logged in (`cursor-agent status` / `cursor-agent login`).
- `jq` and `bash` 5.x on PATH.
- The **superpowers** plugin installed — both commands plug into its skills
  (`subagent-driven-development`, `requesting-code-review`, `receiving-code-review`,
  and the brainstorming / writing-plans gates).

## Usage
**Implement a plan** (delegates each task to Composer):
- New plan, same session: at the superpowers execution handoff, pick subagent-driven and run `/cursor-implement-plans <plan-path>`.
- Prior plan, new session: `/cursor-implement-plans <plan-path>`.

**Review a spec or plan** (delegates to GPT-5.5):
- Spec: `/cursor-review spec docs/superpowers/specs/2026-01-01-foo-design.md`
- Plan vs spec: `/cursor-review plan docs/superpowers/plans/2026-01-01-foo.md docs/superpowers/specs/2026-01-01-foo-design.md`

Where it fits the superpowers flow: run `/cursor-review spec <spec-path>` at the
brainstorming Spec self-review gate, and `/cursor-review plan <plan-path> <spec-path>`
at the writing-plans Self-Review. For spec reviews the controller auto-selects review
**lenses** (backend always; frontend/ui when the spec has a UI surface).

Review is code- and document-based, not visual: `cursor-agent` cannot render or
screenshot a UI.

## Installing
This repo hosts a Claude Code marketplace named **`qc-point`**. Install is two steps —
register the marketplace by pointing at the repo that contains it, then install the
plugin from that marketplace:

```
# 1. Add the marketplace. The argument is the GitHub repo that HOSTS the marketplace
#    (owner/repo) — NOT a marketplace or plugin name. Claude Code reads
#    .claude-plugin/marketplace.json and registers it as "qc-point".
/plugin marketplace add sorcush/cursor-coder-plugin

# 2. Install the plugin. The form is <plugin-name>@<marketplace-name>.
/plugin install cursor-subagent-cc@qc-point
```

## Updating an installed plugin
Git-backed marketplaces do **not** auto-refresh by default:
```
/plugin marketplace update qc-point     # refresh the cached marketplace
```
Claude Code then detects the newer `version` from `plugin.json` and updates the
installed plugin (you may be prompted to `/reload-plugins` or restart). To update
automatically on startup, enable auto-update for the `qc-point` marketplace in the
`/plugin` UI → **Marketplaces** tab.

## Releasing a new version (maintainers)
Version lives in `.claude-plugin/plugin.json` and follows semver. Because the
`version` field is what installed users pin to, **every release must bump it**.
The `Makefile` automates the flow:
```
make bump-patch    # 1.0.0 -> 1.0.1   (backward-compatible fixes)
make bump-minor    # 1.0.1 -> 1.1.0   (new features, backward-compatible)
make bump-major    # 1.1.0 -> 2.0.0   (breaking changes)
make release       # commit the bump as "release: vX.Y.Z" and push to origin
make version       # print the current version
```
`make release` refuses to run on a clean working tree, so run a bump target first.

## Tests
```
bash tests/test-cc-delegate.sh     # coder delegate unit tests (mock cursor-agent)
bash tests/test-cr-delegate.sh     # reviewer delegate unit tests (mock cursor-agent)
```
See `tests/e2e-smoke.md` for the manual end-to-end checks with a real cursor-agent.
````

- [ ] **Step 4: Add a `.gitignore`**

Create `.gitignore` with:
```
.DS_Store
*.tmp
```

- [ ] **Step 5: Verify docs reference the right names**

Run:
```bash
grep -q 'cursor-subagent-cc@qc-point' README.md && \
grep -q '/cursor-review' README.md && grep -q '/cursor-implement-plans' README.md && \
grep -q 'cursor-subagent-cc' Makefile && \
grep -q 'cr-delegate.sh' tests/e2e-smoke.md && grep -q 'cc-delegate.sh' tests/e2e-smoke.md && \
echo "docs OK"
```
Expected: `docs OK`.

- [ ] **Step 6: Final full verification**

Run:
```bash
bash tests/test-cc-delegate.sh && bash tests/test-cr-delegate.sh && \
jq . .claude-plugin/plugin.json >/dev/null && jq . .claude-plugin/marketplace.json >/dev/null && \
test -f agents/cursor-coder-delegator.md && test -f agents/cursor-reviewer-delegator.md && \
echo "ALL GREEN"
```
Expected: `ALL GREEN`.

- [ ] **Step 7: Commit**

```bash
git add Makefile tests/e2e-smoke.md README.md .gitignore
git commit -m "docs: rewrite README/e2e/Makefile for merged cursor-subagent-cc plugin

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: commit succeeds.

---

## Post-plan (manual, outside this session)
- Optionally rename the directory `cursor-coder-plugin` → `cursor-subagent-cc` (cosmetic; `source` is `./`). Re-add the marketplace if its local path changed.
- Optionally delete the now-superseded `cursor-reviewer-plugin` repo.
- Run `make release` to publish v1.0.0 so existing `qc-point` installs pick up the rename.
