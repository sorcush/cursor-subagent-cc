# cursor-coder-plugin

Delegate plan implementation to Cursor's Composer 2.5 (via `cursor-agent`) while
Claude/Opus does the planning and reviewing.

## Roles
- **Opus session** — controller + reviewer (plans, extracts tasks, two-stage review)
- **cursor-coder** (Haiku subagent) — delegator + verifier (shells to Composer, runs tests, loops, commits, reports)
- **Composer 2.5** (cursor-agent) — implementer (writes the code)

## Requirements
- `cursor-agent` installed and logged in (`cursor-agent status`)
- `jq` and `bash` 5.x on PATH
- The **superpowers** plugin installed — `/cursor-implement-plans` reuses its
  commands (`subagent-driven-development`, `requesting-code-review`,
  `finishing-a-development-branch`). Without it the controller flow will not run.

## Usage
- New plan, same session: at the superpowers execution handoff, pick subagent-driven and run `/cursor-implement-plans <plan-path>`.
- Prior plan, new session: `/cursor-implement-plans <plan-path>`.

## Installing

The repo doubles as its own marketplace (`qc-point`):

```
/plugin marketplace add sorcush/cursor-coder-plugin
/plugin install cursor-coder-plugin@qc-point
```

## Updating an installed plugin

Git-backed marketplaces do **not** auto-refresh by default, so updates are a
two-step pull on the user's machine:

```
/plugin marketplace update qc-point     # refresh the cached marketplace
```

Claude Code then detects the newer `version` from `plugin.json` and updates the
installed plugin (you may be prompted to `/reload-plugins` or restart). There is
no per-plugin update command — refreshing the marketplace is what triggers it.

To get updates automatically on startup, enable auto-update for the `qc-point`
marketplace in the `/plugin` UI → **Marketplaces** tab.

## Releasing a new version (maintainers)

Version lives in `.claude-plugin/plugin.json` and follows semver. Because the
`version` field is what installed users pin to, **every release must bump it** —
pushing commits without a bump ships nothing to existing installs.

The `Makefile` automates the flow:

```
make bump-patch    # 0.1.0 -> 0.1.1   (backward-compatible fixes)
make bump-minor    # 0.1.1 -> 0.2.0   (new features, backward-compatible)
make bump-major    # 0.2.0 -> 1.0.0   (breaking changes)
make release       # commit the bump as "release: vX.Y.Z" and push to origin
make version       # print the current version
```

Typical release:

```
make bump-minor && make release
```

`make release` refuses to run on a clean working tree, so run a bump target (or
stage your changes) first. After it pushes, users pull the update via the
**Updating an installed plugin** steps above.
