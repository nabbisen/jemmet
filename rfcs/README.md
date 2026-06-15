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
| 001 | [Scope, boundary, non-goals, iotakt-v1.0 dependency](./proposed/001-scope-boundary-and-dependency.md) | M0 |
| 002 | [The connection abstraction (keystone)](./proposed/002-connection-abstraction.md) | M0/M1 |
| 003 | [HTTP framing soundness & smuggling defense](./proposed/003-http-framing-soundness.md) | M1 |
| 004 | [HTTP/1.1 request parser & bounds safety](./proposed/004-http1-request-parser.md) | M1 |
| 005 | [Response model & HTTP/1.1 serialization](./proposed/005-response-serialization.md) | M1 |
| 006 | [Routing](./proposed/006-routing.md) | M1 |
| 007 | [Serve loop & connection driver](./proposed/007-serve-loop-driver.md) | M2 |
| 008 | [PlainIotaktConn (iotakt byte-level binding)](./proposed/008-plain-iotakt-conn.md) | M2 |
| 009 | [TlsConn (kroopt binding) — gated](./proposed/009-tls-conn-kroopt-binding.md) | M3 |
| 010 | [Errors, limits, timeouts, write-backpressure](./proposed/010-errors-limits-backpressure.md) | M2/M4 |
| 011 | [Proof, trust & test matrix](./proposed/011-proof-trust-test-matrix.md) | M1–M4 |
| 012 | [CI, packaging & release gates](./proposed/012-ci-packaging-release.md) | M4 |
| 013 | [HTTP/2 readiness & future protocols](./proposed/013-http2-readiness-future.md) | future |
| 014 | [Driver & henret/iotakt event semantics](./proposed/014-driver-event-semantics.md) | M1.5/M2 |
| 015 | [Handler execution policy](./proposed/015-handler-execution-policy.md) | M2 |
| 016 | [Production lifecycle](./proposed/016-production-lifecycle.md) | M4 |

### Done
| ID | Title | Notes |
|----|-------|-------|
| 000 | [RFC lifecycle policy](./done/000-rfc-lifecycle-policy.md) | Implemented — in effect for this directory; adopted from iotakt verbatim |

### Archive
_(none yet)_

> Implementation note: RFC 002's `Conn` interface and `FakeConn` (with the
> determinism proof and conformance suite) are implemented as of the M0 skeleton, but
> RFC 002 stays in `proposed/` until the M1 pure-core set is formally accepted
> together, to avoid moving the many inbound cross-references to `../proposed/002…`
> before then. See `CHANGELOG.md`.

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
