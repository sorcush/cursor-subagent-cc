# Changelog Tracking + Per-Agent Model Config — Design Spec

**Date:** 2026-07-18
**Status:** Approved (pending user spec review)

## Problem

Two separate gaps:

1. **No changelog.** Releases (`make release`) bump the version in
   `.claude-plugin/plugin.json` and push, but nothing records *what* changed.
   Users updating the plugin (`/plugin marketplace update qc-point`) have no
   way to see what's new between versions.
2. **Model names are hardcoded in every file that mentions them**, with no
   single source of truth. Confirmed by grepping the repo for model names —
   14 hits across 10 files: `scripts/cc-delegate.sh` (header comment +
   `MODEL="composer-2.5"`), `scripts/cr-delegate.sh` (header comment +
   `MODEL="cursor-grok-4.5-high-fast"`), `commands/cursor-implement-plans.md`
   (frontmatter `description:`, body prose, and the healthcheck probe's
   `--model composer-2.5` literal), `commands/cursor-review.md` (same three
   spots), `agents/cursor-coder-delegator.md` (frontmatter `description:` +
   body prose), `agents/cursor-reviewer-delegator.md` (same), `README.md`
   (intro paragraph, subagents table, usage section), `tests/e2e-smoke.md`
   (a comment and a probe line), and `.claude-plugin/plugin.json` /
   `.claude-plugin/marketplace.json`. This has already caused real drift:
   `plugin.json`'s `keywords` still lists `"gpt-5.5"` and
   `marketplace.json`'s `description` still says "GPT-5.5 (high effort)",
   even though `fd3275c` switched the reviewer to Grok 4.5 weeks ago. The user
   plans to swap models again as new ones ship and wants a single place to do
   it.

## Goals

- Every release documents its changes in a `CHANGELOG.md`, generated
  automatically from commit history — no manual writing required.
- Agent → model mapping lives in one config file. Changing a model means
  editing that one file.
- Everything that names a model (scripts, docs, prompts) either reads the
  config at runtime or is mechanically regenerated from it — nothing is
  hand-edited in more than one place.
- `make release` refuses to run if generated docs are stale relative to the
  config (same "refuse on drift" pattern the Makefile already uses for its
  dirty-tree-required check).

## Non-goals

- No model registry/validation of whether an `id` is a real, callable
  `cursor-agent` model — that's discovered at use time (the existing
  healthcheck probes already do this).
- No historical backfill of `CHANGELOG.md` for versions 0.1.0–1.1.0 — it
  starts fresh from the next release.
- No changelog editing UI/prompt step — generation is fully automatic from
  conventional-commit prefixes, per the user's explicit choice.
- No automatic SemVer bump selection from `!:`/`BREAKING` commits — which
  `bump-*` target to run stays a manual maintainer decision; the changelog's
  `**BREAKING:**` annotation is informational only (see Part 1 step 4).

## Part 1 — Changelog

### Format

`CHANGELOG.md` at repo root, following [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/). Illustrative example of the
header plus one generated section (not a claim about backfilled history —
per Non-goals, the file starts empty and only the next real release adds a
section):

```markdown
# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-07-18

### Added
- switch reviewer model from GPT-5.5 to Grok 4.5 high fast

### Changed
- fix marketplace add command to use renamed repo
```

### Generation

New `scripts/gen-changelog.sh`:

1. **Find the boundary:** the most recent commit whose subject matches
   `^release: v` (this repo has no git tags — `release: vX.Y.Z` commit
   messages are the only release markers). If none exists (first-ever run),
   the boundary is the root of history.
2. **Collect commits** strictly after the boundary, up to `HEAD`, excluding
   merge commits and any commit itself matching `^release: v`.
3. **Parse each subject** against this grammar (a spec, not a literal bash
   snippet — implement with `sed`/`perl`/`python` or equivalent, not bash's
   `[[ =~ ]]`, which doesn't support named groups):
   `^(?<type>[a-z]+)(\((?<scope>[^)]+)\))?(?<breaking>!)?:\s*(?<text>.+)$`.
   A subject that doesn't match this shape at all (no `type:` prefix) is
   treated as `type=chore`, `text=<full subject>`. The `scope` group, if
   present, is discarded (not shown in the bullet — this repo's history
   doesn't use scopes today, but the parser must not choke on one).
4. **Bucket by `type`:**
   - `feat` → `### Added`
   - `fix` → `### Fixed`
   - anything else (`docs`, `chore`, `refactor`, `build`, `test`, the
     no-prefix fallback) → `### Changed`
   - if `breaking` matched (`!` before the colon), prefix the bullet text
     with `**BREAKING:**` regardless of bucket. This is informational only —
     it does **not** change which `bump-*` target was already run; SemVer
     major-bump decisions stay a manual maintainer call (see Non-goals).
5. Each non-empty bucket becomes a `### Added` / `### Changed` / `### Fixed`
   section under a new `## [X.Y.Z] - YYYY-MM-DD` heading, using the version
   already written to `plugin.json` by the `bump-*` target and today's date
   (local system date — `date +%F` — matching how the user reasons about
   "when did I release this," not UTC).
   Empty buckets are omitted. If **all** buckets are empty (no qualifying
   commits since the boundary — e.g. a release re-run with nothing new),
   the section body is a single line, `_No notable changes._`, instead of
   any subsection headings.
6. Prints the new section to stdout; does not touch the file itself (keeps
   the script composable/testable), so re-running it always recomputes the
   section fresh from current git history and the current `plugin.json`
   version — it never reads or depends on what's already in `CHANGELOG.md`.

### Wiring into `make release`

`make release` (in `Makefile`) is extended to, in order:
1. Run the existing dirty-tree-required check (unchanged).
2. Run `scripts/sync-models.sh --check` (see Part 2) — abort with a clear
   message if docs are stale.
3. Run `scripts/gen-changelog.sh` to get the freshly-generated section text
   for the version currently in `plugin.json`. **Idempotency by
   replace-in-place:** if `CHANGELOG.md` already contains a `## [X.Y.Z]`
   heading for that version (from a prior run that generated the section but
   failed before/during the commit), delete that existing section first,
   then prepend the newly generated one in its place — never skip
   regeneration, since more commits may have landed since the stale section
   was written. **Section boundary:** the line matching `^## \[X.Y.Z\]`
   through the line immediately before the next line matching `^## \[` (any
   version), or through EOF if there is no next `## [` heading — deletes
   exactly one section, never touching earlier version entries below it. If
   no `## [X.Y.Z]` heading exists yet, just prepend, creating the file with
   the standard header first if it doesn't exist yet.
4. `git add -A && git commit -m "release: vX.Y.Z"` (unchanged message
   format) — commits the freshly generated/replaced `CHANGELOG.md` section
   together with whatever already-synced docs are sitting in the working
   tree (`sync-models.sh` itself was run manually beforehand per its own
   workflow; step 2 here only verifies that was done, it does not run sync).
5. `git push` (unchanged).

Steps 1–4 are safe to re-run after a failure in any of them: step 1 requires
a dirty tree so a fully-clean state (nothing pending) correctly refuses;
step 2 is a pure drift check; step 3 always regenerates fresh and replaces
rather than skips; step 4 only commits what's actually changed. **Step 5 is
the one exception:** if `git push` itself fails after a successful commit,
the tree is now clean, so re-running `make release` will correctly refuse
with "nothing to release" — recovery in that case is simply running
`git push` directly, not `make release` again.

## Part 2 — Per-agent model config

### Config file

New `.claude-plugin/models.json`, the single source of truth:

```json
{
  "coder": {
    "id": "composer-2.5",
    "label": "Composer 2.5"
  },
  "reviewer": {
    "id": "cursor-grok-4.5-high-fast",
    "label": "Grok 4.5 (high effort, fast)"
  }
}
```

- `id` — the exact string passed to `cursor-agent --model`.
- `label` — human-readable name used in prose/docs. Constrained to plain
  ASCII text with no `:`, `"`, backtick, or newline characters, so it can be
  substituted directly into a YAML frontmatter string and a Markdown span
  without escaping logic in `sync-models.sh`. `sync-models.sh` validates this
  and refuses to run if a label violates it, rather than emitting broken
  YAML/JSON.

To change a model, edit this file directly. To see the current mapping, read
it directly (`jq . .claude-plugin/models.json`) or run `make models`, a new
convenience target that pretty-prints the mapping.

### Runtime consumers (read the config directly, no sync needed)

- **`scripts/cc-delegate.sh`**: gains the same `SCRIPT_DIR`-relative
  resolution `cr-delegate.sh` already uses for `RUBRIC_DIR`, plus an
  override var mirroring the existing `CC_CURSOR_BIN` pattern (needed so
  tests can inject a fixture without touching the real config). Replace
  `MODEL="composer-2.5"` with:
  ```bash
  MODELS_JSON="${CC_MODELS_JSON:-$SCRIPT_DIR/../.claude-plugin/models.json}"
  MODEL="$(jq -r '.coder.id // empty' "$MODELS_JSON")"
  if [[ -z "$MODEL" ]]; then
    echo "error: could not read .coder.id from $MODELS_JSON" >&2
    exit 2
  fi
  ```
  The explicit empty-check is required because the script runs under
  `set -uo pipefail` without `-e`: a missing file, invalid JSON, or missing
  key would otherwise leave `MODEL` empty and silently pass a broken
  `--model ""` to `cursor-agent` instead of failing loudly.
- **`scripts/cr-delegate.sh`**: same pattern (override var `CR_MODELS_JSON`),
  `MODEL="$(jq -r '.reviewer.id // empty' "$MODELS_JSON")"`, same fail-fast
  check.
- **`commands/cursor-implement-plans.md`** healthcheck probe (step 2):
  replace the hardcoded `--model composer-2.5` literal with an instruction to
  read `.claude-plugin/models.json`'s `.coder.id` first, failing fast the
  same way the scripts do (mirrors the fail-fast check above, not a bare
  `jq -r` that could silently pass an empty `--model`):
  ```
  CODER_MODEL=$(jq -er '.coder.id' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/models.json")
  if [[ -z "$CODER_MODEL" ]]; then
    echo "error: could not read .coder.id from models.json"; exit 2
  fi
  cursor-agent -p --force --trust --model "$CODER_MODEL" "Reply with the single word READY."
  ```
  `jq -e` exits non-zero on `null`/missing (which leaves `CODER_MODEL` unset
  under `set -u`-style callers), and the explicit `-z` check also catches an
  empty-string value that `-e` alone would miss — the same two-layer check
  the scripts use.
- **`commands/cursor-review.md`** healthcheck probe: same pattern reading
  `.reviewer.id`.

These four are the only places model names have *functional* effect (they
choose which model actually runs). After this change none of them hardcode a
model string — they are correct for any value in `models.json` with zero
further edits.

### Doc consumers (regenerated by `scripts/sync-models.sh`)

Everything below is prose that names a model for human readers, evaluated by
Claude Code as static text (frontmatter/JSON/plain Markdown it loads
directly, not code that can shell out to `jq`). Two regeneration mechanisms,
applied to every file identified in the Problem section's grep — nothing
model-related is left un-synced:

**Whole-field template regeneration** (script owns one specific field
end-to-end; only that field is rewritten, the rest of the file is
untouched):
- **`.claude-plugin/plugin.json`** `description` — regenerated from its own
  template, e.g. `"Delegate implementation to Cursor's {coder.label} and
  independent design-spec/plan review to {reviewer.label} via cursor-agent,
  while Claude/Opus plans, decides, and reviews."` Only this field is
  touched — `.version` stays owned by the `bump-*` Makefile targets.
- **`.claude-plugin/plugin.json`** `keywords` — **not** synced going
  forward. This is a one-time manual fix as part of Rollout (drop the stale
  `"gpt-5.5"`, keep only generic terms: `cursor`, `composer`, `delegation`,
  `review`, `subagent`, `superpowers`). `sync-models.sh` never writes this
  field, so it can't reintroduce a model-specific keyword.
- **`.claude-plugin/marketplace.json`** `plugins[0].description` —
  regenerated from its **own**, shorter template distinct from
  `plugin.json`'s (matching the existing copy style — the two descriptions
  read differently today and this spec doesn't force them to converge):
  `"Two Cursor-backed delegation subagents: {coder.label} for implementation
  and {reviewer.label} for independent design/plan review."`
- **`agents/cursor-coder-delegator.md`** frontmatter `description:` —
  regenerated (only this one YAML line; `name:`, `model:`, `tools:` stay
  untouched) from: `"Delegates a single implementation task to Cursor's
  {coder.label} model via cursor-agent, verifies it, and reports back. Use
  as the implementer in subagent-driven development when delegating coding
  to Composer. Does not design, review, or write code itself — it delegates
  and verifies."`
- **`agents/cursor-reviewer-delegator.md`** frontmatter `description:` —
  same mechanism, from: `"Delegates an independent design-spec or
  implementation-plan review to {reviewer.label} via cursor-agent in
  read-only mode, and relays the report. Use as the reviewer when an
  independent, unbiased review of a spec or plan is needed. Does not
  author, judge, or edit — it delegates and relays."`
- **`commands/cursor-implement-plans.md`** frontmatter `description:` —
  from: `"Implement a written plan by delegating each task to Cursor's
  {coder.label} (via the cursor-coder-delegator subagent), while Opus
  reviews. Usage: /cursor-implement-plans <plan-path>"`
- **`commands/cursor-review.md`** frontmatter `description:` — from: `"Get
  an independent {reviewer.label} review of a design spec or implementation
  plan, removing the bias of self-review. Usage: /cursor-review
  <spec|plan> <doc-path> [spec-path]"`

  All four templates are the exact current text of each `description:`
  field with the model name substring replaced by `{coder.label}` /
  `{reviewer.label}` — i.e. `sync-models.sh` reproduces today's wording
  verbatim when run against today's `models.json` values, and only the
  substituted span changes on a model swap.

**Marker-wrapped spans** (for prose embedded inside a document body, where
only a small span should be rewritten and everything else must survive
untouched — HTML comments, invisible when rendered):
```markdown
<!-- model:coder:label -->Composer 2.5<!-- /model:coder:label -->
```
The script replaces only the text strictly between a matching marker pair.
**Only mentions that name a specific versioned model are marked** — generic
unversioned references to "Composer" or "Cursor" as a product/vendor name
are left as plain prose, not wrapped, to avoid over-marking every incidental
mention. Applied to every remaining versioned-model mention found in the
grep:
- **`README.md`** — five spots, each shown as it will read after sync
  (bold/table syntax unchanged, only the marked span is new):
  - Intro line 1: `- **Implementation** is delegated to Cursor's
    **<!-- model:coder:label -->Composer 2.5<!-- /model:coder:label
    -->**.`
  - Intro line 2: `- **Independent review** of a design spec or plan is
    delegated to **<!-- model:reviewer:label -->Grok 4.5 (high effort,
    fast)<!-- /model:reviewer:label -->** —`
  - Table, coder row's "Delegates to" cell: `<!-- model:coder:label
    -->Composer 2.5<!-- /model:coder:label -->`
  - Table, reviewer row's "Delegates to" cell: today reads "Grok 4.5 high
    fast (read-only)" — a short form that doesn't match the canonical
    label. Normalized to `<!-- model:reviewer:label -->Grok 4.5 (high
    effort, fast)<!-- /model:reviewer:label --> (read-only)` so the table
    uses the same label text as everywhere else; `(read-only)` stays
    outside the marker since it isn't part of the model name.
  - Usage section: "delegates to Grok 4.5" — same short-form issue,
    normalized to `(delegates to <!-- model:reviewer:label -->Grok 4.5
    (high effort, fast)<!-- /model:reviewer:label -->)`.
- **`agents/cursor-coder-delegator.md`** / **`agents/cursor-reviewer-delegator.md`**:
  the body sentence(s) naming the model (e.g. "You hand a single task to
  Cursor's `<!-- model:coder:label -->Composer 2.5<!-- /model:coder:label -->`
  model...").
- **`commands/cursor-implement-plans.md`** / **`commands/cursor-review.md`**:
  the body prose naming the model (outside the healthcheck probe line, which
  is already dynamic per the Runtime consumers section above).
- **`scripts/cc-delegate.sh`** / **`scripts/cr-delegate.sh`**: the header
  comment line. **Markers must stay entirely within the `#`-comment line**
  (never span onto a following code line) since these are executable bash
  files, not Markdown — an HTML comment marker landing outside a `#` line
  would be interpreted as a shell command. Single-line example:
  `# cc-delegate.sh — delegate one task to Cursor <!-- model:coder:label -->Composer 2.5<!-- /model:coder:label --> and verify.`
- **`tests/e2e-smoke.md`**: the comment line's label mention is
  marker-wrapped like everywhere else. The probe command's model **id** is
  a different case — a marker embedded inside a copy-pasteable shell
  argument would break the runbook (a human pasting `--model <!--
  model:reviewer:id -->...` gets invalid shell, since the marker text isn't
  stripped at use time). Instead, the probe itself becomes a two-line
  dynamic snippet, matching the pattern already used in the command
  healthchecks (Runtime consumers, above), so the id is read live and never
  hardcoded or marker-wrapped at all:
  ```
  REVIEWER_MODEL=$(jq -er '.reviewer.id' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/models.json")
  if [[ -z "$REVIEWER_MODEL" ]]; then
    echo "error: could not read .reviewer.id from models.json"; exit 2
  fi
  cursor-agent -p --force --trust --mode ask --model "$REVIEWER_MODEL" "Reply READY."
  ```

### Drift check

`scripts/sync-models.sh --check` runs the same regeneration logic but writes
to a temp copy and diffs against the real files instead of overwriting them;
exits non-zero (and prints which files would change) if anything is stale.
**If a file is expected to contain a marker pair (per the list above) and
that marker pair is missing entirely, `--check` fails loudly** rather than
silently skipping the file — a missing marker means someone removed it or it
was never added, either of which needs a human to notice, not a silent
no-op. This is what `make release` calls before releasing.

**Validation before any writes:** `sync-models.sh` first reads and validates
the entire `models.json` — required keys present, `id`s non-empty, `label`s
pass the charset check — and refuses to run (no files touched at all) if
validation fails. This is a whole-config check, not per-file, so a bad
label can never be "caught partway through."

**Atomicity for write failures:** once config is validated, `sync-models.sh`
writes each target file to a temp path first and only replaces the real
file once that file's regeneration succeeds — so a failure for an unrelated
reason (disk full, permission denied, a target file deleted out from under
it) partway through the file list leaves already-written files updated and
unwritten ones untouched, and the script exits non-zero printing exactly
which files it did and didn't reach, so a re-run after fixing the cause is
safe (regeneration is idempotent per-file: re-writing an already-correct
file is a no-op diff).

Running `scripts/sync-models.sh` with no flag performs the regeneration for
real, so the normal workflow after editing `models.json` is:

```
$EDITOR .claude-plugin/models.json
scripts/sync-models.sh
git diff   # review
```

## Revision log

- 2026-07-18 (round 1): revised after independent review (Grok 4.5 via
  `/cursor-review spec`, backend lens, session `732efd68-22ed-4880-9f1b-22fa18475a00`).
  Widened doc-sync coverage to close the Goals-vs-Part-2 gap, made changelog
  generation idempotent, fixed silent-failure risk in the scripts, specified
  commit-parsing rules, empty-bucket behavior, and split the plugin/marketplace
  description templates instead of unifying them.
- 2026-07-18 (round 2): revised after re-review of round 1 (same session).
  Replaced the skip-if-exists changelog guard with replace-in-place (the
  skip variant could ship a stale section on retry), narrowed the "safe to
  re-run" claim to exclude post-commit `git push` failure, synced the
  `tests/e2e-smoke.md` probe's model id (not just its comment) to close the
  last Goals exception, added fail-fast to the command healthcheck `jq`
  calls, constrained markers to single comment lines in script headers,
  fixed the Rollout/Doc-consumers contradiction over who edits `keywords`,
  added a label charset constraint, and specified `sync-models.sh`
  per-file write atomicity.
- 2026-07-18 (round 3): revised after re-review of round 2 (same session).
  Fixed a self-introduced defect: markers can't be embedded inside a
  copy-pasteable shell command, so `tests/e2e-smoke.md`'s probe now reads
  the model id dynamically (same pattern as the command healthchecks)
  instead of marker-wrapping a literal. Also: defined the exact
  changelog-section deletion boundary, moved `models.json` validation ahead
  of all file writes (was ambiguously "mid-run"), added the four
  frontmatter template strings that were named but not given, spelled out
  the exact wrapped text for all five README spots (normalizing two
  short-form model mentions to the canonical label), aligned the command
  healthcheck's empty-string check with the scripts', and two minor
  clarifications (regex is a grammar spec not a bash snippet; date is
  local, not UTC).

## Testing

- Extend `tests/` with a shell test for `gen-changelog.sh`: given a fixed
  fake git history (feat/fix/docs commits after a `release:` marker), asserts
  the generated section buckets correctly and omits empty sections; a
  separate case with zero qualifying commits since the boundary asserts the
  `_No notable changes._` fallback.
- New test for `sync-models.sh`: given a sample `models.json`, asserts every
  templated field (`plugin.json` / `marketplace.json` descriptions, all four
  frontmatter `description:` fields) and every marker span (README, agent
  bodies, command bodies, script header comments, and e2e-smoke.md's
  comment line — not its probe command, which is never marker-wrapped)
  match expected output; asserts `plugin.json`'s `keywords` is left
  untouched; asserts `--check` exits 0 on a synced tree, non-zero after
  mutating `models.json` without re-running sync, non-zero if a required
  marker pair is missing from a target file, and non-zero if `models.json`
  itself fails validation (missing key, empty id, or a label violating the
  charset constraint) with zero files touched.
- Extend `tests/test-cc-delegate.sh` / `tests/test-cr-delegate.sh` (or add
  cases) to confirm each script reads `MODEL` from `models.json` rather than
  a hardcoded literal — set `CC_MODELS_JSON` / `CR_MODELS_JSON` to a fixture
  file with a distinctive fake model id and assert the mock `cursor-agent`
  was invoked with that id. Also assert the fail-fast path: point the
  override var at a missing/invalid file and assert the script exits
  non-zero with the diagnostic message rather than invoking `cursor-agent`
  with an empty `--model`.
- New test for the replace-in-place guard: in a scratch clone, manually
  write a stale/incorrect `## [X.Y.Z]` section into `CHANGELOG.md` for the
  version currently in `plugin.json` (simulating a commit that failed after
  changelog generation but before `git commit` succeeded), then run
  `make release` and assert the stale section is replaced with a freshly
  generated one (not duplicated, not left stale) reflecting all commits up
  to the new `HEAD`.
- Manual: bump a version, run `make release` against a scratch clone, confirm
  `CHANGELOG.md` gets the right section and the release commit includes it.

## Rollout for this repo's existing drift

As part of implementing this spec (not deferred):
1. Create `models.json` with today's actual values (`composer-2.5` /
   `cursor-grok-4.5-high-fast`).
2. Manually add the marker pairs listed under "Marker-wrapped spans" to
   every body-prose spot in `README.md`, both `agents/*.md`, both
   `commands/*.md`, both `scripts/*.sh` header comments, and the comment
   line in `tests/e2e-smoke.md` (one-time bootstrap — `sync-models.sh` only
   fills markers in, it doesn't insert new ones into arbitrary prose).
   Separately, replace `tests/e2e-smoke.md`'s probe *command* with the
   dynamic jq-read snippet given above — that spot takes no marker at all.
3. Run `sync-models.sh` once to populate every marker and regenerate every
   templated field — this fixes the stale "GPT-5.5" wording in
   `marketplace.json`'s description (via its own template) and every other
   templated/marked spot.
4. Separately, by hand, drop the stale `"gpt-5.5"` entry from
   `.claude-plugin/plugin.json`'s `keywords` (this field is never touched by
   `sync-models.sh`, per Doc consumers above — it's a one-time manual fix,
   not something sync performs).
5. Update the four runtime consumers (two scripts, two healthcheck probes)
   to read from config.
6. Review the full `git diff` before committing — this is the one time
   every affected file changes at once.

`CHANGELOG.md` starts empty (created fresh) at the next release.
