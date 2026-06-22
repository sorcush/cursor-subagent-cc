BACKEND / ARCHITECTURE LENS — apply in addition to the base rubric.

- Data flow: is the path of data through the system clear and sound? Are the
  sources of truth and ownership of state well-defined?
- Interfaces and boundaries: are module/service boundaries clean, with explicit
  contracts? Is coupling minimized?
- Error handling and failure modes: timeouts, retries, partial failures, and
  idempotency where it matters.
- Data and persistence: schema/migration strategy, backward compatibility, data
  integrity, transactions where needed.
- Concurrency and ordering: race conditions, ordering guarantees, idempotency.
- Performance and scalability: hot paths, N+1 patterns, unbounded growth, resource
  limits.
- Security: authn/authz, input validation, secret handling, and injection/SSRF/PII
  surfaces introduced by this design.
- Observability: are logging, metrics, and tracing considered for the new paths?
