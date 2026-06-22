FRONTEND DESIGN LENS — apply in addition to the base rubric. Judge from the
described components and structure, plus any markup/styles in the repo.

- Component structure: clear hierarchy, single-responsibility components, sensible
  state ownership, data-down/events-up flow.
- State management: is client state distinguished from server state? Are loading,
  empty, error, and success states all designed — not just the happy path?
- Reusability and consistency: shared components/design tokens reused rather than
  duplicated; consistent with existing UI patterns in the codebase.
- Data fetching: caching, optimistic updates, error/retry behavior, avoiding
  request waterfalls.
- Accessibility: semantic structure, keyboard navigation, focus management, and
  labels/roles — called out, not assumed.
- Performance: bundle/render cost, unnecessary re-renders, large lists
  (virtualization), image/asset strategy.
- Responsiveness: behavior across breakpoints is specified.
