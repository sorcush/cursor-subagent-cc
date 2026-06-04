---
description: Implement a written plan by delegating each task to Cursor's Composer 2.5 (via the cursor-coder subagent), while Opus reviews. Usage: /cursor-implement-plans <plan-path>
argument-hint: <path-to-plan-file>
---

You are the **controller**. You will implement the plan at `$ARGUMENTS` by
delegating each task's implementation to Composer 2.5 (through the `cursor-coder`
subagent) while YOU do the planning extraction and all review. Composer writes
code; you never let it review.

## Preflight (do this first, stop on failure)

1. **Plan path given?** If `$ARGUMENTS` is empty, ask the user for the plan file
   path and stop until provided.
2. **cursor-agent healthy?** Run: `cursor-agent status`
   - If it errors or shows "not logged in", tell the user to run `cursor-agent login`
     (suggest they type `! cursor-agent login`) and STOP. Do not proceed.
3. **Branch safety:** Run `git rev-parse --abbrev-ref HEAD`. If it is `main` or
   `master`, tell the user and ask them to confirm or create a branch before you
   start. Do not implement on main/master without explicit consent.
4. **Load context:** Read the plan file at `$ARGUMENTS`. If it references a spec
   (e.g. a `docs/superpowers/specs/...` file), read that too — you'll need it for
   spec-compliance review.

## Then: run subagent-driven development with the implementer overridden

Invoke the **superpowers:subagent-driven-development** skill and follow it, with
these THREE overrides (state them to yourself before starting):

1. **Implementer = cursor-coder.** For each task's implementation step, dispatch
   the `cursor-coder` subagent (NOT a general-purpose subagent). Give it: the
   task's full text, scene-setting context, and a concrete **verify command** for
   that task (derive it from the plan's verification steps; if a task has none,
   use the plan's general test command, or ask the user once). If you are
   re-dispatching to fix a prior task, pass the **Composer session id** the agent
   returned last time so Composer resumes its own context.

2. **No interactive implementer Q&A.** Composer is one-shot; `cursor-coder`
   cannot hold a back-and-forth. If `cursor-coder` returns **NEEDS_CONTEXT** or
   **BLOCKED**, treat it exactly as the skill says: provide more context and
   re-dispatch, break the task smaller, switch the verify command, or escalate to
   the user. Never silently retry unchanged.

3. **Reviews stay with you (Opus).** Keep the skill's two-stage review after each
   task — spec compliance first, then code quality — using
   `superpowers:requesting-code-review` as the skill specifies. Composer is NEVER
   a reviewer. When all tasks are done, follow the skill into
   `superpowers:finishing-a-development-branch`.

Everything else about subagent-driven-development (serial dispatch, TodoWrite
task tracking, fix-and-re-review loops, handling DONE/DONE_WITH_CONCERNS) is
UNCHANGED.
