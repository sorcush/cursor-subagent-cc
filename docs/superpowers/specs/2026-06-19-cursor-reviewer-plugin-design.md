# cursor-reviewer-plugin — Design Spec

**Date:** 2026-06-19
**Status:** Approved for planning

## Goal

Provide an **independent design review** of Opus-authored design specs and
implementation plans by delegating the review to a different vendor/model —
**GPT-5.5 at high effort** (`gpt-5.5-high`) running inside `cursor-agent` —
so the model that *wrote* the document is not the model that *grades* it.

This is the mirror image of `cursor-coder-plugin`: where that plugin delegates
*coding* to Composer 2.5 while Opus plans and reviews, this plugin delegates
*review* to GPT-5.5 while Opus designs and decides.

## Problem

In the superpowers workflow, two documents are reviewed by the same Opus session
that authored them:

- **`brainstorming`** step 7 — *"Spec self-review"*: Opus checks its own spec for
  placeholders, contradictions, ambiguity, and scope.
- **`writing-plans`** *Self-Review* section — explicitly *"a checklist you run
  yourself — not a subagent dispatch."*

Self-review by the author is a structural conflict of interest: the same
assumptions that produced a gap are unlikely to catch it. (Notably,
`writing-plans` even ships a `plan-document-reviewer-prompt.md` template but tells
Opus *not* to dispatch it — a latent seam this plugin activates.)

Code review is **out of scope** — Opus reviewing `cursor-coder`'s output is
already a clean separation of authoring and review.

## Scope

**In scope:**
- Independent review of a **design spec** (`target: spec`).
- Independent review of an **implementation plan** (`target: plan`).
- For spec review, three **lenses** layered onto the one document: backend,
  frontend, UI. Lenses are facets of a single review pass — not separate targets.
- Grounding the review in the **existing codebase** (integration fit, regression
  risk — "this new feature won't break anything"), enabled by GPT-5.5's read-only
  access to the repo via `cursor-agent --mode ask`.

**Out of scope (v1):**
- Code review of implemented changes.
- Visual/rendered UI review (screenshots). Frontend/UI review is code- and
  spec-based, since `cursor-agent` cannot render or screenshot. (Documented
  limitation.)
- Multi-pass per-lens review (Approach B). Single-pass, lens-parameterized only;
  multi-pass is a documented future toggle.
- Conversational/iterative review — `cursor-agent -p` is one-shot headless.

## Roles

| Role | Who | Responsibility |
|------|-----|----------------|
| Controller | Opus session | Authors spec/plan, dispatches review, critically triages findings via `superpowers:receiving-code-review`, decides fixes. |
| Delegator | `cursor-reviewer-delegator` (Haiku subagent, `tools: Bash, Read`) | Runs the delegate script, relays the report verbatim. Never edits, judges, filters, or fabricates. |
| Reviewer | `gpt-5.5-high` via `cursor-agent --mode ask` (read-only) | Reads the document **and** explores the existing repo, produces the structured review. |

## Technical grounding (verified)

- Model id: **`gpt-5.5-high`** ("GPT-5.5 1M High") — effort is encoded in the model
  id; there is no separate effort flag. Confirmed via `cursor-agent --list-models`.
- Read-only enforcement: **`cursor-agent --mode ask`** (Q&A, read-only). Combined
  with the delegator having no `Write`/`Edit` tools, the reviewer cannot mutate
  the repo (defense in depth).
- Headless plumbing (same as `cc-delegate.sh`):
  `cursor-agent -p --force --trust --approve-mcps --output-format stream-json
  --model gpt-5.5-high`.
- `cursor-agent` version verified: `2026.06.03-0bbb28e`.

## Components

### 1. `scripts/cr-delegate.sh`

The delegate script. Adapts `cc-delegate.sh`'s structure and output discipline:
**only the final STATUS JSON goes to stdout; all diagnostics/progress go to stderr.**

**Arguments:**
- `--target spec|plan` (required)
- `--doc-file <path>` (required) — the spec or plan markdown under review
- `--spec-file <path>` (optional) — for `plan` reviews, the spec to check coverage against
- `--lenses backend,frontend,ui` (optional) — lens rubrics to include for `spec` reviews
- `--rubric-dir <path>` (defaults to `${CLAUDE_PLUGIN_ROOT}/rubrics`)

**Behavior:**
1. Validate args (mirror `cc-delegate.sh`: unknown/missing args exit 2; unreadable
   `--doc-file` exits 2; unknown `--target` exits 2).
2. Assemble the prompt from rubric files: role preamble + the target rubric
   (`spec-review.md` or `plan-review.md`) + selected lens rubrics + the shared
   `_output-format.md` + an explicit instruction to **explore relevant existing
   code in the workspace** to judge integration fit and regression risk + a
   pointer to read `--doc-file` (and `--spec-file` when given).
3. Run `cursor-agent -p --mode ask --force --trust --approve-mcps
   --output-format stream-json --model gpt-5.5-high "<prompt>"`. Render
   `assistant`/`tool_call` events to stderr as progress (reuse `cc-delegate.sh`'s
   `render_event`). Keep the terminal `result` event.
4. Treat as failure (→ `BLOCKED`): non-zero exit, no/ malformed `result` event,
   `is_error:true` or non-`success` subtype, or an empty report.
5. Emit one JSON line:
   `{"status": "REVIEWED"|"BLOCKED", "session_id": ..., "target": ..., "lenses": ..., "report": ..., "diagnostic": ...}`.

**No verify loop, no commit, no retries.** A review is one read-only pass; the
script does not attempt to "fix" anything (contrast with the coder's verify/resume
loop). `session_id` is captured and returned so Opus can dispatch a follow-up
question that resumes the reviewer's context.

### 2. `agents/cursor-reviewer-delegator.md`

Haiku subagent, `tools: Bash, Read`. Mirrors the `cursor-coder-delegator` contract,
inverted for review:

- Receives in its prompt: `target`, doc path, optional spec path, lenses.
- Runs `cr-delegate.sh`, parses the JSON with `jq`, relays the `report` **verbatim**
  plus `session_id` and `status`.
- **Hard contract:** never edits files, never writes code, never decides whether a
  finding is valid (that is Opus's job), never filters/reorders findings, and never
  fabricates a report — if the script returns `BLOCKED`, it reports `BLOCKED` with
  the diagnostic and stops.
- Report format: `Status` (REVIEWED | BLOCKED), the verbatim review, `session_id`
  (required, copied verbatim), and any script diagnostic on BLOCKED.

### 3. `commands/cursor-review.md`

`/cursor-review <spec|plan> <doc-path> [spec-path]`. The controller flow:

1. **Preflight:** require a target and doc path; confirm the doc exists; run a real
   headless probe `cursor-agent -p --force --trust --mode ask --model gpt-5.5-high
   "Reply with the single word READY."`. On any failure, tell the user to run
   `cursor-agent login` (suggest `! cursor-agent login`) and stop. (Note: no
   `timeout` wrapper — not present on macOS by default.)
2. **Lens detection (spec only):** scan the spec for frontend/UI content
   (components, CSS, routes, screens, design tokens, UX flows). Include `backend`
   always; include `frontend`/`ui` when detected. If ambiguous, ask the user once.
3. **Dispatch** the `cursor-reviewer-delegator` with target/doc/spec/lenses.
4. **Triage:** apply `superpowers:receiving-code-review` so Opus engages each
   finding critically — verify against the codebase, push back with reasoning where
   the reviewer is wrong, accept and fix where it is right. No blind agreement, no
   reflexive dismissal.
5. **Present** triaged findings to the user and offer a fix → re-review loop
   (re-dispatch can pass the prior `session_id` to resume reviewer context).
6. **Review Effectiveness Summary** (always): print it and append a dated entry to
   `docs/cursor-reviewer/effectiveness-log.md` (create if missing). Capture: target,
   doc, lenses, # findings by severity, how many Opus accepted vs pushed back on,
   any BLOCKED/environment friction, and recommendations for improving the rubrics
   or prompts. This is the raw material for tuning the plugin.

### 4. `rubrics/` (distilled, gpt-5.5-ready)

Each file contains the review *criteria* only — no Claude-Code scaffolding (trigger
frontmatter, "use the X tool" lines, cross-skill references).

- `spec-review.md` — internal consistency, completeness, ambiguity, scope,
  **coverage of important-but-thinly-covered areas**, integration with existing
  code, regression risk.
- `lens-backend.md` — backend/architecture design lens (data flow, error handling,
  scalability, security, interfaces/boundaries).
- `lens-frontend.md` — distilled from the frontend-design skill criteria.
- `lens-ui.md` — distilled from the ui-ux-pro-max skill criteria.
- `plan-review.md` — distilled from `plan-document-reviewer-prompt.md` +
  `writing-plans` Self-Review (spec coverage, task decomposition, buildability,
  placeholder scan, type/signature consistency).
- `_output-format.md` — shared output contract: **Strengths**, **Issues**
  (Critical / Important / Minor, each with location · what's wrong · why it matters
  · how to fix), **Recommendations**, **Verdict** (Approve | Approve with fixes |
  Needs revision).

### 5. Integration guidance (README)

The superpowers skills cannot be edited, so integration is by convention at their
self-review gates:

- **brainstorming** step 7 (Spec self-review): run `/cursor-review spec <spec-path>`.
- **writing-plans** Self-Review: run `/cursor-review plan <plan-path> <spec-path>`.

Independent review *replaces the bias of* self-review; Opus still owns every fix
decision via `receiving-code-review`.

### 6. Plumbing

- `.claude-plugin/plugin.json` — name `cursor-reviewer-plugin`, semver `version`,
  author, keywords.
- `.claude-plugin/marketplace.json` — reuse the `qc-point` marketplace name for
  consistency with `cursor-coder-plugin`.
- `Makefile` — same `bump-patch|minor|major` + `release` flow.
- `README.md` — roles, requirements (`cursor-agent` logged in, `jq`, bash 5.x,
  superpowers installed), usage, install, release.
- `tests/` — `mock-cursor-agent` (adapted), `test-cr-delegate.sh` (arg validation,
  JSON parsing, REVIEWED/BLOCKED paths, lens assembly, read-only mode flag present),
  `e2e-smoke.md` (manual end-to-end with a real `cursor-agent`).

## Data flow

```
/cursor-review spec docs/.../spec.md
  → preflight (READY probe, doc exists)
  → lens detection (backend [+frontend +ui])
  → dispatch cursor-reviewer-delegator(target, doc, lenses)
      → cr-delegate.sh assembles prompt (rubric + lenses + output-format)
      → cursor-agent --mode ask --model gpt-5.5-high  (reads doc + explores repo)
      → emits {status, session_id, target, lenses, report}
  → delegator relays report + session_id verbatim
  → Opus triages via superpowers:receiving-code-review
  → present to user → optional fix → re-review (resume session_id)
  → Review Effectiveness Summary (print + append to effectiveness-log.md)
```

## Error handling

| Condition | Outcome |
|-----------|---------|
| `cursor-agent` unauth / untrusted / timeout / no READY | Preflight stops; user runs `cursor-agent login`. |
| Missing/unreadable doc | Preflight stops. |
| Non-zero exit / no `result` event / malformed JSON | Script `BLOCKED` with diagnostic. |
| `is_error` / non-`success` subtype | Script `BLOCKED` with the error text. |
| Empty report | Script `BLOCKED` — never fabricated. |
| Delegator sees BLOCKED | Reports BLOCKED verbatim; never improvises a review. |
| Reviewer attempts a file edit | Impossible: `--mode ask` is read-only **and** delegator has no Write/Edit tools. |

## Testing strategy

- **Unit** (`tests/test-cr-delegate.sh` against `tests/mock-cursor-agent`): arg
  validation and exit codes; REVIEWED happy path with captured `session_id` and
  `report`; BLOCKED on cursor-agent failure, on missing `result` event, and on
  `is_error`; correct lens rubric assembly into the prompt; presence of
  `--mode ask` (read-only) in the invoked command line.
- **E2E smoke** (`tests/e2e-smoke.md`): manual run of `/cursor-review spec` and
  `/cursor-review plan` against a sample doc with a real logged-in `cursor-agent`,
  confirming a structured report comes back and no files were modified.

## Open items / future

- **Approach B (multi-pass per lens):** documented future toggle if single-pass
  reviews spread too thin across lenses.
- **Visual UI review:** out of v1; would require a Claude-side screenshot step
  (e.g. playwright) feeding the reviewer.
