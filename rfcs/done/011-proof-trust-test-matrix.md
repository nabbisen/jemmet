# RFC 011: Proof, trust, and test matrix

## Status
Implemented (M1–M2 scope — proof/trust/test matrix + matrix-honesty guard. Deferred: TLS rows at M3 / 0.6.0)

## Summary
jemmet's claim taxonomy — what is PROVEN, TESTED, ASSUMED, OUTSCOPE — the theorem
inventory, the fuzzing targets, and the CI classification, with a matrix-honesty
guard.

## Motivation
A verified edge must be honest about what verification covers. jemmet is mostly
TESTED (HTTP conformance is established by interop), with a focused PROVEN core and
explicit ASSUMED dependencies on its siblings. Stating this precisely is the
credibility posture (as iotakt and kroopt do).

## Goals
1. Classify every claim.
2. Inventory the theorems and the conformance/fuzz tests.
3. Define the CI guard that keeps the matrix honest.

## Non-Goals
Re-proving iotakt/kroopt (ASSUMED); proving handler logic (application).

## External Design (the matrix)
| Claim | Class | Where |
|-------|------:|-------|
| Framing soundness / no smuggling (**raw-stream** unique boundaries) | PROVEN | RFC 003 + 007 |
| Parser step: consume-bounded / need-more / reject; no drop/dup/reorder | PROVEN | RFC 004 |
| Parser bounds safety (by construction) | PROVEN | RFC 004 |
| Router totality & determinism | PROVEN | RFC 006 |
| Response well-formedness / no header injection | PROVEN | RFC 005 |
| Keep-alive request-boundary state machine | PROVEN | RFC 007 |
| **Egress + ingress boundedness** (mandatory, not optional) | PROVEN / model-checked | RFC 010 |
| Phase-indexed connection error policy is total | PROVEN | RFC 007 + 010 |
| HTTP/1.1 conformance (methods, framing, keep-alive, chunked) | TESTED | interop |
| HTTPS conformance E2E | TESTED | interop (M3) |
| Limit & timeout enforcement | TESTED | scenarios |
| iotakt I/O correctness | ASSUMED | iotakt matrix |
| kroopt TLS correctness | ASSUMED | kroopt matrix |
| Lean runtime / toolchain | ASSUMED | TCB |
| Cryptographic security, TLS correctness | OUTSCOPE | kroopt/HACL* |
| Kernel/TCP, volumetric DoS | OUTSCOPE | OS/deployment |
| Application authn/authz, handler logic | OUTSCOPE | application |

Cleanliness criterion (adopted from kroopt): *no project-local `sorry`, `axiom`,
or `unsafe` in the proven core, except explicitly whitelisted, documented
Lean/Foundation assumptions.*

Fuzzing targets: request-line parser, header parser, chunked decoder, framing
decision.

**Actor/driver property tests (added per review — more important than additional
ordinary parser unit tests):** randomized event interleavings; randomized
`wouldBlock`; repeated `interrupted`; 0/1/N partial reads and writes; arbitrary
tick insertion; connection close at every phase; bounded fairness (no connection
starves while another pipelines aggressively); stale `FdKey` events; close-then-
reuse raw fd. Driven by the RFC 014 fake event-trace runner.

## Proof Obligations
The matrix's PROVEN rows are discharged by RFC 003–007/010.

## Test Obligations
Conformance + interop + fuzz suites enumerated and wired into CI (RFC 012).

## Trust / Assumption Changes
Formalizes iotakt/kroopt as ASSUMED.

## Acceptance Criteria
`docs/proof-trust-test-matrix.md` present and current; the matrix-honesty CI guard
asserts 0 `sorry`/`axiom`/`unsafe` in the proven core and that the theorem count
matches the matrix.

## Alternatives Considered
- *Claim "verified HTTP server" broadly:* rejected — dishonest; jemmet proves a
  focused core and tests conformance.

## Open Questions
1. Which conformance suite(s) to adopt for the TESTED rows (h2spec-style, custom).
