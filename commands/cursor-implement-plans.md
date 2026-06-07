---
description: Implement a written plan by delegating each task to Cursor's Composer 2.5 (via the cursor-coder-delegator subagent), while Opus reviews. Usage: /cursor-implement-plans <plan-path>
argument-hint: <path-to-plan-file>
---

You are the **controller**. You will implement the plan at `$ARGUMENTS` by
delegating each task's implementation to Composer 2.5 (through the
`cursor-coder-delegator` subagent) while YOU do the planning extraction and all
review. Composer writes code; you never let it review.

## Preflight (do this first, stop on failure)

1. **Plan path given?** If `$ARGUMENTS` is empty, ask the user for the plan file
   path and stop until provided.
2. **cursor-agent healthy? Probe for real — `cursor-agent status` is NOT enough.**
   `status` can report "Logged in (unable to fetch user details)" while headless
   calls still fail auth, and it does not catch the workspace-trust gate. Run an
   actual headless probe instead:
   ```
   cursor-agent -p --force --trust --model composer-2.5 "Reply with the single word READY."
   ```
   - If it does not return `READY` — auth error ("Authentication required"),
     "Workspace Trust Required", a timeout, or anything else — the setup is NOT
     healthy. Tell the user to run `cursor-agent login` (suggest they type
     `! cursor-agent login`) and STOP. Do not proceed until the probe returns
     `READY`. (Note: `timeout` is not present on macOS by default — do not wrap the
     probe in it.)
3. **Branch safety:** Run `git rev-parse --abbrev-ref HEAD`. If it is `main` or
   `master`, tell the user and ask them to confirm or create a branch before you
   start. Do not implement on main/master without explicit consent.
4. **Load context:** Read the plan file at `$ARGUMENTS`. If it references a spec
   (e.g. a `docs/superpowers/specs/...` file), read that too — you'll need it for
   spec-compliance review.

## Then: run subagent-driven development with the implementer overridden

Invoke the **superpowers:subagent-driven-development** skill and follow it, with
these THREE overrides (state them to yourself before starting):

1. **Implementer = cursor-coder-delegator.** For each task's implementation step,
   dispatch the `cursor-coder-delegator` subagent (NOT a general-purpose subagent). Give it: the
   task's full text, scene-setting context, and a concrete **verify command** for
   that task (derive it from the plan's verification steps; if a task has none,
   use the plan's general test command, or ask the user once). If you are
   re-dispatching to fix a prior task, pass the **Composer session id** the agent
   returned last time so Composer resumes its own context.

2. **No interactive implementer Q&A.** Composer is one-shot; `cursor-coder-delegator`
   cannot hold a back-and-forth. If `cursor-coder-delegator` returns **NEEDS_CONTEXT** or
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

## Final step: Delegation Effectiveness Summary (ALWAYS do this)

After `finishing-a-development-branch` completes — or if the run is abandoned
partway — produce a short **Delegation Effectiveness Summary**. This is the raw
material for improving the plugin, so it is required even when the run went well.

Do BOTH:
1. Print the summary to the user.
2. Append it as a dated entry to `docs/cursor-coder/effectiveness-log.md` in the
   working repo (create the dir/file if missing). If that repo is not writable or
   the user objects, just print it and say where it would have gone.

Keep it tight (≈10–15 lines). Capture:

- **Run:** date · plan path · branch · number of tasks delegated.
- **Outcome:** how many tasks passed verification first-try (`attempts:0`) vs
  needed fix loops · total fix attempts across the run · any `BLOCKED` /
  `NEEDS_CONTEXT` and the cause.
- **Composer fidelity:** did it follow the task specs? Note any **out-of-scope
  file edits** or **autonomous commits** (e.g. `Co-authored-by: Cursor`) you had
  to reconcile, and whether they were correct.
- **Environment friction:** auth/login, workspace-trust, `cursor-agent`
  anomalies, missing `session_id` / resume failures, latency or attempt-count
  outliers.
- **Reliability flags (most important):** any case where `cursor-coder-delegator`
  did NOT actually delegate — e.g. it wrote code itself, reported `DONE` without a
  real Composer `session_id`, or otherwise bypassed the script. Call these out
  explicitly; they indicate the delegation contract was broken.
- **Recommendations:** concrete changes to the plan format, dispatch prompts, the
  `cursor-coder-delegator` agent, or `cc-delegate.sh` that would make delegation
  smoother next time.

Base every line on what actually happened this run (per-task `attempts`/
`verified`/`session_id` from the agent reports, the commits created, and your
reviews) — do not invent metrics.
