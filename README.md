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

## Usage
- New plan, same session: at the superpowers execution handoff, pick subagent-driven and run `/cursor-implement-plans <plan-path>`.
- Prior plan, new session: `/cursor-implement-plans <plan-path>`.
