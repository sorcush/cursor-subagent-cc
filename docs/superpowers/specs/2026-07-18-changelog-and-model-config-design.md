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

## [1.1.0] - ...
```

### Generation

New `scripts/gen-changelog.sh`:

1. **Find the boundary:** the most recent commit whose subject matches
   `^release: v` (this repo has no git tags — `release: vX.Y.Z` commit
   messages are the only release markers). If none exists (first-ever run),
   the boundary is the root of history.
2. **Collect commits** strictly after the boundary, up to `HEAD`, excluding
   merge commits and any commit itself matching `^release: v`.
3. **Parse each subject** against
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
   already written to `plugin.json` by the `bump-*` target and today's date.
   Empty buckets are omitted. If **all** buckets are empty (no qualifying
   commits since the boundary — e.g. a release re-run with nothing new),
   the section body is a single line, `_No notable changes._`, instead of
   any subsection headings.
6. Prints the new section to stdout; does not touch the file itself (keeps
   the script composable/testable).
7. **Idempotent by construction:** because step 5 always uses the version
   currently in `plugin.json`, re-running the script produces the same
   section for the same version regardless of how many times it's called.

### Wiring into `make release`

`make release` (in `Makefile`) is extended to, in order:
1. Run the existing dirty-tree-required check (unchanged).
2. Run `scripts/sync-models.sh --check` (see Part 2) — abort with a clear
   message if docs are stale.
3. Run `scripts/gen-changelog.sh` to get the new section text. **Idempotency
   guard:** if `CHANGELOG.md` already contains a `## [X.Y.Z]` heading for the
   version currently in `plugin.json`, skip this step entirely (a prior run
   already wrote it — e.g. the release commit failed after this step but
   before the git commit succeeded, and `make release` was re-run). Otherwise
   prepend the generated section to `CHANGELOG.md`, creating the file with
   the standard header first if it doesn't exist yet.
4. `git add -A && git commit -m "release: vX.Y.Z"` (unchanged message
   format) — now also includes `CHANGELOG.md` and any docs `sync-models.sh`
   regenerated.
5. `git push` (unchanged).

This makes the whole `make release` sequence safe to re-run after any step
fails: step 2 is naturally idempotent (drift-check), step 3 is guarded
explicitly, and step 4 only commits if there's something to commit (existing
behavior).

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
- `label` — human-readable name used in prose/docs.

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
  read `.claude-plugin/models.json`'s `.coder.id` first, e.g.:
  ```
  CODER_MODEL=$(jq -r '.coder.id' "${CLAUDE_PLUGIN_ROOT}/.claude-plugin/models.json")
  cursor-agent -p --force --trust --model "$CODER_MODEL" "Reply with the single word READY."
  ```
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
- **`agents/cursor-coder-delegator.md`** / **`agents/cursor-reviewer-delegator.md`**
  frontmatter `description:` — regenerated from a per-agent template
  (script rewrites just that YAML line).
- **`commands/cursor-implement-plans.md`** / **`commands/cursor-review.md`**
  frontmatter `description:` — same, per-command template.

**Marker-wrapped spans** (for prose embedded inside a document body, where
only a small span should be rewritten and everything else must survive
untouched — HTML comments, invisible when rendered):
```markdown
<!-- model:coder:label -->Composer 2.5<!-- /model:coder:label -->
```
The script replaces only the text strictly between a matching marker pair.
Applied to every remaining body-prose mention found in the grep:
- **`README.md`**: intro paragraph (2 spots), subagents table ("Delegates
  to" column, 2 spots), usage section heading text.
- **`agents/cursor-coder-delegator.md`** / **`agents/cursor-reviewer-delegator.md`**:
  the body sentence(s) naming the model (e.g. "You hand a single task to
  Cursor's `<!-- model:coder:label -->Composer 2.5<!-- /model:coder:label -->`
  model...").
- **`commands/cursor-implement-plans.md`** / **`commands/cursor-review.md`**:
  the body prose naming the model (outside the healthcheck probe line, which
  is already dynamic per the Runtime consumers section above).
- **`scripts/cc-delegate.sh`** / **`scripts/cr-delegate.sh`**: the header
  comment line (e.g. `# cc-delegate.sh — delegate one task to Cursor
  <!-- model:coder:label -->Composer 2.5<!-- /model:coder:label --> and
  verify.`).
- **`tests/e2e-smoke.md`**: the comment line and any prose mention (the
  probe command itself stays a literal example command, not synced, since
  it's illustrative documentation of a manual check, not something executed
  by tooling).

### Drift check

`scripts/sync-models.sh --check` runs the same regeneration logic but writes
to a temp copy and diffs against the real files instead of overwriting them;
exits non-zero (and prints which files would change) if anything is stale.
**If a file is expected to contain a marker pair (per the list above) and
that marker pair is missing entirely, `--check` fails loudly** rather than
silently skipping the file — a missing marker means someone removed it or it
was never added, either of which needs a human to notice, not a silent
no-op. This is what `make release` calls before releasing. Running
`scripts/sync-models.sh` with no flag performs the regeneration for real, so
the normal workflow after editing `models.json` is:

```
$EDITOR .claude-plugin/models.json
scripts/sync-models.sh
git diff   # review
```

## Revision log

- 2026-07-18: revised after independent review (Grok 4.5 via
  `/cursor-review spec`, backend lens, session `732efd68-22ed-4880-9f1b-22fa18475a00`).
  Widened doc-sync coverage to close the Goals-vs-Part-2 gap, made changelog
  generation idempotent, fixed silent-failure risk in the scripts, specified
  commit-parsing rules, empty-bucket behavior, and split the plugin/marketplace
  description templates instead of unifying them. See inline changes below.

## Testing

- Extend `tests/` with a shell test for `gen-changelog.sh`: given a fixed
  fake git history (feat/fix/docs commits after a `release:` marker), asserts
  the generated section buckets correctly and omits empty sections.
- New test for `sync-models.sh`: given a sample `models.json`, asserts every
  templated field (`plugin.json` / `marketplace.json` descriptions, all four
  frontmatter `description:` fields) and every marker span (README, agent
  bodies, command bodies, script header comments, e2e-smoke.md) match
  expected output; asserts `plugin.json`'s `keywords` is left untouched;
  asserts `--check` exits 0 on a synced tree, non-zero after mutating
  `models.json` without re-running sync, and non-zero if a required marker
  pair is missing from a target file.
- Extend `tests/test-cc-delegate.sh` / `tests/test-cr-delegate.sh` (or add
  cases) to confirm each script reads `MODEL` from `models.json` rather than
  a hardcoded literal — set `CC_MODELS_JSON` / `CR_MODELS_JSON` to a fixture
  file with a distinctive fake model id and assert the mock `cursor-agent`
  was invoked with that id. Also assert the fail-fast path: point the
  override var at a missing/invalid file and assert the script exits
  non-zero with the diagnostic message rather than invoking `cursor-agent`
  with an empty `--model`.
- New test for `gen-changelog.sh` idempotency: run `make release` twice in a
  row against a scratch clone (simulating a retry) and assert `CHANGELOG.md`
  ends up with exactly one `## [X.Y.Z]` section, not two.
- Manual: bump a version, run `make release` against a scratch clone, confirm
  `CHANGELOG.md` gets the right section and the release commit includes it.

## Rollout for this repo's existing drift

As part of implementing this spec (not deferred):
1. Create `models.json` with today's actual values (`composer-2.5` /
   `cursor-grok-4.5-high-fast`).
2. Manually add the marker pairs listed under "Marker-wrapped spans" to
   every body-prose spot in `README.md`, both `agents/*.md`, both
   `commands/*.md`, both `scripts/*.sh` header comments, and
   `tests/e2e-smoke.md` (one-time bootstrap — `sync-models.sh` only fills
   markers in, it doesn't insert new ones into arbitrary prose).
3. Run `sync-models.sh` once to populate every marker and regenerate every
   templated field — this also fixes the stale `"gpt-5.5"` keyword (manual
   one-time edit per the Doc consumers section) and the stale "GPT-5.5"
   wording in `marketplace.json`'s description (via its own template).
4. Update the four runtime consumers (two scripts, two healthcheck probes)
   to read from config.
5. Review the full `git diff` before committing — this is the one time
   every affected file changes at once.

`CHANGELOG.md` starts empty (created fresh) at the next release.
