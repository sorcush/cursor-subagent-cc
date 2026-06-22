# cursor-subagent-cc — Merge Design Spec

**Date:** 2026-06-22
**Status:** Approved (pending user spec review)

## Problem

`cursor-coder-plugin` and `cursor-reviewer-plugin` live in two separate repos,
but each defines a Claude Code marketplace with the **same name**, `qc-point`.
Claude Code keys marketplaces by `name`, which must be unique, so only one
`qc-point` marketplace can be registered at a time. Adding the second repo
collides with the first — you can install the coder *or* the reviewer, never
both. Each plugin provides exactly one agent definition, so there is no reason
for them to be separate plugins.

## Goal

Collapse both into a **single plugin, `cursor-subagent-cc`**, hosted in the
existing `cursor-coder-plugin` repo, that provides **both** subagents
(coder-delegator + reviewer-delegator) and both slash commands. One
`qc-point` marketplace install then delivers coder + reviewer together.

## Constraints & Decisions

- **Host repo:** the current `cursor-coder-plugin` repo. Reviewer files are
  copied in; the `cursor-reviewer-plugin` repo is left untouched and superseded
  (user may delete later).
- **Directory name:** stays physically `cursor-coder-plugin` for this work.
  Plugin identity lives in `.claude-plugin/*.json` (`name` fields) and the
  marketplace `source` is `./` (relative), so the on-disk directory name is
  cosmetic and can be renamed later, outside the working session, with zero
  functional impact. Renaming the cwd mid-session would break absolute-path
  tool calls, so it is explicitly out of scope here.
- **Marketplace name:** stays `qc-point`.
- **Plugin name:** `cursor-subagent-cc`.
- **Version:** `1.0.0` (the rename + merge is a major release).
- **Reviewer historical docs:** `docs/superpowers/{specs,plans}` from the
  reviewer repo are copied in for reference.

## Why the merge needs almost no rewrites

The two plugins are structurally parallel and already collision-free in their
core assets:

| Asset | coder | reviewer | Collision? |
|---|---|---|---|
| agent `name:` | `cursor-coder-delegator` | `cursor-reviewer-delegator` | No |
| command file | `commands/cursor-implement-plans.md` | `commands/cursor-review.md` | No |
| script | `scripts/cc-delegate.sh` | `scripts/cr-delegate.sh` | No |
| rubrics | — | `rubrics/*` | No (reviewer-only) |
| test driver | `tests/test-cc-delegate.sh` | `tests/test-cr-delegate.sh` | No |

Every script reference uses `${CLAUDE_PLUGIN_ROOT}/scripts/...`, and the two
scripts keep distinct names, so copying the reviewer's `agents/`, `commands/`,
`scripts/`, and `rubrics/` into the host repo requires **no edits** to those
files.

## Final layout (in the host repo)

```
.claude-plugin/
  plugin.json        # name: cursor-subagent-cc, version 1.0.0, merged desc + keywords
  marketplace.json   # qc-point → single plugin entry: cursor-subagent-cc
agents/
  cursor-coder-delegator.md      (unchanged)
  cursor-reviewer-delegator.md   (copied in, unchanged)
commands/
  cursor-implement-plans.md      (unchanged)
  cursor-review.md               (copied in, unchanged)
scripts/
  cc-delegate.sh                 (unchanged)
  cr-delegate.sh                 (copied in, unchanged)
rubrics/                         (copied in wholesale — reviewer-only)
  _output-format.md
  lens-backend.md
  lens-frontend.md
  lens-ui.md
  plan-review.md
  spec-review.md
tests/
  mock-cursor-agent              (one unified copy — see below)
  test-cc-delegate.sh            (unchanged)
  test-cr-delegate.sh            (copied in, unchanged)
  e2e-smoke.md                   (merged: coder section + reviewer section)
docs/superpowers/
  specs/2026-06-22-cursor-subagent-cc-merge-design.md   (this file)
  specs/2026-06-19-cursor-reviewer-plugin-design.md      (copied in, historical)
  plans/2026-06-19-cursor-reviewer-plugin.md             (copied in, historical)
Makefile                         (kept; header comment generalized)
README.md                        (rewritten to document both subagents)
```

## The shared-name merges

Five files share a name across the two repos and must be reconciled:

1. **`.claude-plugin/plugin.json`** — single object: `name` →
   `cursor-subagent-cc`, `version` → `1.0.0`, `description` merged to cover both
   delegation roles, `keywords` = union of both lists.

2. **`.claude-plugin/marketplace.json`** — keep `name: qc-point`; `plugins`
   array holds exactly one entry, `cursor-subagent-cc`, `source: "./"`, with the
   merged description.

3. **`tests/mock-cursor-agent`** — the two mocks honor an **identical env-var
   contract** (`MOCK_FAIL_CLI`, `MOCK_STDERR`, `MOCK_IS_ERROR`, `MOCK_SESSION`,
   `MOCK_RESULT`, `MOCK_STREAM`, `MOCK_LOG`); they differ only cosmetically. Adopt
   the **reviewer's** version as the single shared mock (it has the
   `${MOCK_RESULT-done}` fix that preserves an explicit empty result). Then run
   **both** test suites against it. **Fallback:** if the coder suite asserts on a
   mock-specific detail (e.g. a model string in the stream-init line) and fails,
   keep two distinctly-named mocks instead (e.g. `mock-cursor-agent` for one
   suite, `mock-cursor-agent-cr` for the other) and point each test driver at
   its own.

4. **`Makefile`** — keep the coder's (generic semver bump/release on
   `plugin.json`); only generalize the header comment to name
   `cursor-subagent-cc`. No logic change.

5. **`tests/e2e-smoke.md`** — merge into one document with a "Coder delegation"
   section (the `cc-delegate.sh` cases) and a "Reviewer delegation" section (the
   `cr-delegate.sh` cases).

6. **`README.md`** — rewrite to describe the single `cursor-subagent-cc` plugin,
   both subagents, both slash commands, and the (unchanged) two-step
   `qc-point` install flow.

## Out of scope

- The `cursor-reviewer-plugin` repo is not modified or deleted.
- The `docs/cursor-coder/` and `docs/cursor-reviewer/` effectiveness-log paths
  referenced by the commands live in *consuming* projects, not this repo, and do
  not collide.
- Physically renaming the host directory to `cursor-subagent-cc`.

## Verification

- `bash tests/test-cc-delegate.sh` → passes.
- `bash tests/test-cr-delegate.sh` → passes.
- `bash -n scripts/cc-delegate.sh` and `bash -n scripts/cr-delegate.sh` → syntax OK.
- `jq . .claude-plugin/plugin.json` and `jq . .claude-plugin/marketplace.json` → valid JSON.
- `jq -r '.name' .claude-plugin/plugin.json` → `cursor-subagent-cc`.
- Both `agents/*.md` present with their distinct `name:` headers.
