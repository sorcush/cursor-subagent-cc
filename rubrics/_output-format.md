Produce your review in EXACTLY this structure. Be specific — cite the section,
heading, or line of the document for every issue. Do not pad.

## Summary
One paragraph: what the document proposes and your overall judgment.

## Strengths
- What is genuinely well-handled. Be specific; this calibrates trust in the rest.

## Issues

### Critical (must fix before proceeding)
For each: **[location]** — what is wrong — why it matters — how to fix.
Contradictions, missing requirements that block implementation, designs that will
break existing behavior, security or data-loss risks.

### Important (should fix)
Architecture problems, important-but-thinly-covered areas, unhandled error/edge
cases, integration gaps with the existing codebase.

### Minor (nice to have)
Clarity, naming, polish — anything that does not block.

## Codebase Integration & Regression Risk
Based on the existing code you explored: does the proposal fit current patterns?
What existing behavior could it break? Name the files or modules at risk.

## Verdict
One of: **Approve** | **Approve with fixes** | **Needs revision**
Plus one or two sentences of reasoning.

Rules: categorize by ACTUAL severity (not everything is Critical). If the document
itself (not its implementation) is wrong, say so. If you are unsure about something,
explore the repo before flagging it — do not invent issues.
