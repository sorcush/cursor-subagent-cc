You are reviewing a DESIGN SPEC for a software feature. It describes intended
behavior and architecture — not code — so judge the design, completeness, and
clarity against the following criteria.

Internal consistency
- Do any sections contradict each other? Does the stated architecture match the
  feature descriptions and data flow?

Completeness
- Are there placeholders (TBD/TODO), vague requirements, or unanswered questions?
- Is error handling specified? Are failure modes and edge cases addressed?
- Are success criteria and scope (in scope / out of scope) explicit?

Coverage of important-but-thin areas
- Identify areas important to the feature's success but covered only superficially.
  Security, data migration, concurrency, observability, rollback, and backward
  compatibility are common blind spots — flag any that apply and are under-specified.

Ambiguity
- Could any requirement be read two different ways? Name the likely interpretations
  and point out where the spec must disambiguate.

Scope and decomposition
- Is the work focused enough to implement as one unit, or should it be split?
- Are component boundaries clear, with well-defined interfaces?

Fit with the existing codebase (explore the repo)
- Does the design follow existing patterns and conventions?
- Will the new feature break or regress existing behavior? Name specific modules or
  files at risk and explain how.
