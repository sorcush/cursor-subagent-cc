# Changelog Tracking + Per-Agent Model Config — Design Spec

**Date:** 2026-07-18
**Status:** Approved (pending user spec review)

## Problem

Two separate gaps:

1. **No changelog.** Releases (`make release`) bump the version in
   `.claude-plugin/plugin.json` and push, but nothing records *what* changed.
   Users updating the plugin (`/plugin marketplace update qc-point`) have no
   way to see what's new between versions.
2. **Model names are hardcoded in six places**, with no single source of
   truth: `scripts/cc-delegate.sh` (`MODEL="composer-2.5"`),
   `scripts/cr-delegate.sh` (`MODEL="cursor-grok-4.5-high-fast"`), the
   healthcheck probes in `commands/cursor-implement-plans.md` and
   `commands/cursor-review.md`, the `description:` frontmatter in
   `agents/cursor-coder-delegator.md` / `agents/cursor-reviewer-delegator.md`,
   `README.md`, and `.claude-plugin/plugin.json` /
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
  config (same "refuse on drift" pattern the Makefile already uses for the
  clean-tree check).

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
Changelog](https://keepachangelog.com/en/1.1.0/):

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
3. **Bucket by the existing conventional-commit prefixes** this repo already
   uses consistently:
   - `feat:` → `### Added`
   - `fix:` → `### Fixed`
   - anything else (`docs:`, `chore:`, `refactor:`, `build:`, `test:`,
     unprefixed) → `### Changed`
   - a commit subject containing `!:` (breaking-change marker) is bucketed
     normally but prefixed `**BREAKING:**` in the bullet text
4. Each bucket becomes a `### Added` / `### Changed` / `### Fixed` section
   under a new `## [X.Y.Z] - YYYY-MM-DD` heading, using the version already
   written to `plugin.json` by the `bump-*` target and today's date. Empty
   buckets are omitted entirely. Bullet text is the commit subject with its
   `type:` prefix stripped.
5. Prints the new section to stdout; does not touch the file itself (keeps
   the script composable/testable).

### Wiring into `make release`

`make release` (in `Makefile`) is extended to, in order:
1. Run the existing clean-tree check (unchanged).
2. Run `scripts/sync-models.sh --check` (see Part 2) — abort with a clear
   message if docs are stale.
3. Run `scripts/gen-changelog.sh`, prepend its output to `CHANGELOG.md`
   (creating the file with the standard header if it doesn't exist yet).
4. `git add -A && git commit -m "release: vX.Y.Z"` (unchanged message
   format) — now also includes `CHANGELOG.md` and any docs `sync-models.sh`
   regenerated.
5. `git push` (unchanged).

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
  resolution `cr-delegate.sh` already uses for `RUBRIC_DIR`. Replace
  `MODEL="composer-2.5"` with:
  ```bash
  MODELS_JSON="$SCRIPT_DIR/../.claude-plugin/models.json"
  MODEL="$(jq -r '.coder.id' "$MODELS_JSON")"
  ```
- **`scripts/cr-delegate.sh`**: same pattern, `MODEL="$(jq -r '.reviewer.id' "$MODELS_JSON")"`.
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
Claude Code as static text (frontmatter/JSON it loads directly, not code that
can shell out to `jq`). New `scripts/sync-models.sh` regenerates these from
`models.json`:

- **`.claude-plugin/plugin.json`**
  - `description`: fully regenerated from a template in the script, e.g.
    `"Delegate implementation to Cursor's {coder.label} and independent
    design-spec/plan review to {reviewer.label} via cursor-agent, while
    Claude/Opus plans, decides, and reviews."`
  - `keywords`: drop version-specific model keywords entirely (remove the
    stale `"gpt-5.5"` now, and don't reintroduce model-specific keywords —
    keep only generic ones: `cursor`, `composer`, `delegation`, `review`,
    `subagent`, `superpowers`). This keyword list no longer needs syncing at
    all going forward.
- **`.claude-plugin/marketplace.json`**: `plugins[0].description` regenerated
  from the same template as `plugin.json`'s description.
- **`agents/cursor-coder-delegator.md`** / **`agents/cursor-reviewer-delegator.md`**:
  the YAML frontmatter `description:` field is regenerated in place from a
  per-agent template (script rewrites just that line, leaves the rest of the
  file untouched).
- **`README.md`**: the handful of spots that name a model (intro paragraph,
  the subagents table's "Delegates to" column) are wrapped in HTML comment
  markers, e.g.:
  ```markdown
  <!-- model:coder:label -->Composer 2.5<!-- /model:coder:label -->
  ```
  The script replaces only the text strictly between a matching marker pair,
  leaving all surrounding prose untouched. Markers are invisible in rendered
  Markdown.

### Drift check

`scripts/sync-models.sh --check` runs the same regeneration logic but writes
to a temp copy and diffs against the real files instead of overwriting them;
exits non-zero (and prints which files would change) if anything is stale.
This is what `make release` calls before releasing. Running
`scripts/sync-models.sh` with no flag performs the regeneration for real, so
the normal workflow after editing `models.json` is:

```
$EDITOR .claude-plugin/models.json
scripts/sync-models.sh
git diff   # review
```

## Testing

- Extend `tests/` with a shell test for `gen-changelog.sh`: given a fixed
  fake git history (feat/fix/docs commits after a `release:` marker), asserts
  the generated section buckets correctly and omits empty sections.
- New test for `sync-models.sh`: given a sample `models.json`, asserts
  regenerated `plugin.json` description/keywords, `marketplace.json`
  description, both agent frontmatter `description:` fields, and README
  marker spans match expected output; asserts `--check` exits 0 on a
  synced tree and non-zero after mutating `models.json` without re-running
  sync.
- Extend `tests/test-cc-delegate.sh` / `tests/test-cr-delegate.sh` (or add
  cases) to confirm each script reads `MODEL` from `models.json` rather than
  a hardcoded literal — e.g. point them at a fixture `models.json` with a
  distinctive fake model id and assert the mock `cursor-agent` was invoked
  with that id.
- Manual: bump a version, run `make release` against a scratch clone, confirm
  `CHANGELOG.md` gets the right section and the release commit includes it.

## Rollout for this repo's existing drift

As part of implementing this spec (not deferred): create `models.json` with
today's actual values (`composer-2.5` / `cursor-grok-4.5-high-fast`), run
`sync-models.sh` once to fix the stale `"gpt-5.5"` keyword and the stale
"GPT-5.5" wording in `marketplace.json`'s description, and update the four
runtime consumers to read from config. `CHANGELOG.md` starts empty (created
fresh) at the next release.
