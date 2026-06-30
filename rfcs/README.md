# jemmet RFCs

jemmet adopts **RFC 000 — RFC lifecycle policy** verbatim (vendored into
[`done/000-rfc-lifecycle-policy.md`](./done/000-rfc-lifecycle-policy.md) so this repo
describes its own policy). RFCs live under `proposed/`, `done/`, `archive/`; a file's
folder is the source of truth for its state; numbers are stable and never reused; the
`Status` field mirrors the folder.

## Index

### Proposed
| ID | Title | Milestone |
|----|-------|-----------|
| 009 | [TlsConn (kroopt binding) — gated](./proposed/009-tls-conn-kroopt-binding.md) | M3 |
| 013 | [HTTP/2 readiness & future protocols](./proposed/013-http2-readiness-future.md) | future |

### Done
| ID | Title | Status / notes |
|----|-------|----------------|
| 000 | [RFC lifecycle policy](./done/000-rfc-lifecycle-policy.md) | Implemented — in effect for this directory; adopted from iotakt verbatim |
| 001 | [Scope, boundary, non-goals, iotakt-v1.0 dependency](./done/001-scope-boundary-and-dependency.md) | Implemented (M0) |
| 002 | [The connection abstraction (keystone)](./done/002-connection-abstraction.md) | Implemented (M1) |
| 003 | [HTTP framing soundness & smuggling defense](./done/003-http-framing-soundness.md) | Implemented (M1) |
| 004 | [HTTP/1.1 request parser & bounds safety](./done/004-http1-request-parser.md) | Implemented (M1) |
| 005 | [Response model & HTTP/1.1 serialization](./done/005-response-serialization.md) | Implemented (M1) |
| 006 | [Routing](./done/006-routing.md) | Implemented (M1) |
| 007 | [Serve loop & connection driver](./done/007-serve-loop-driver.md) | Implemented (M2) |
| 008 | [PlainIotaktConn (iotakt byte-level binding)](./done/008-plain-iotakt-conn.md) | Implemented (M2) |
| 010 | [Errors, limits, timeouts, write-backpressure](./done/010-errors-limits-backpressure.md) | Implemented (M2); TLS ciphertext egress tier deferred → 009 |
| 011 | [Proof, trust & test matrix](./done/011-proof-trust-test-matrix.md) | Implemented (M1–M2); TLS rows at 0.6.0 |
| 012 | [CI, packaging & release gates](./done/012-ci-packaging-release.md) | Implemented (M2); HTTPS E2E step gated → M3 |
| 014 | [Driver & henret/iotakt event semantics](./done/014-driver-event-semantics.md) | Implemented (M1.5) |
| 015 | [Handler execution policy](./done/015-handler-execution-policy.md) | Implemented (M2) |
| 016 | [Production lifecycle](./done/016-production-lifecycle.md) | Implemented (M4 plaintext scope); TLS re-validation at 0.6.0 |

### Archive
_(none yet)_

> Migration note: the M0–M2 and M4-hardening RFCs moved `proposed → done` once their
> designs shipped on `main` (per RFC 000); the `Status` fields and these index links were
> updated in the same change. 009 (TLS, gated on kroopt) and 013 (HTTP/2, forward-only)
> remain in `proposed/`.

## RFC template
```markdown
# RFC NNN: Title
## Status
Proposed / Done / Archived
## Summary
## Motivation
## Goals / Non-Goals
## External Design
## Proof Obligations
## Test Obligations
## Trust / Assumption Changes
## Acceptance Criteria
## Alternatives Considered
## Open Questions
```
Every RFC must cover goals, non-goals, and its proof/test obligations explicitly.
