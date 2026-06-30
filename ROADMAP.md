# jemmet ROADMAP

Full detail: `docs/jemmet_rfc_roadmap_v2.md`. Central fact: the plaintext edge
depends only on iotakt (contract confirmed) and ships without waiting for kroopt;
TLS is a later additive step gated on kroopt's real-iotakt validation.

- **M0 — Startup & design freeze (0.1.0).** Skeleton, conventions, RFC 001 (scope +
  iotakt-v1.0 decision) and RFC 002 (connection abstraction). Seed from
  iotakt:jemmet-handoff/prototype.
- **M1 — Pure HTTP core (no wiring) (0.2.0).** Parser, framing engine, response
  serializer, routing, the `Conn` interface, `FakeConn`. Headline proofs begin
  (framing soundness, parser bounds, router totality, response wf). *Parallel-safe.*
- **M1.5 — Driver model checkpoint (0.3.0).** Deterministic fake henret/iotakt
  event-trace runner passes the adversarial suite; RFC 010/014/015 accepted.
- **M2 — Plaintext edge (gated only on iotakt) (0.4.0).** `PlainIotaktConn`, serve
  loop / driver, keep-alive (+ proven boundary), chunked, limits/timeouts/backpressure.
  Usable plaintext HTTP/1.1 edge without kroopt.
- **M3 — TLS edge (gated on kroopt) (0.5.0).** `TlsConn` over kroopt once its
  `IotaktTransport` is validated; ALPN; HTTPS E2E; plaintext+TLS listeners coexist.
- **M4 — Hardening (0.6.0).** Error/limit/timeout matrix, observability, docs, CI
  gate, proof/trust/test matrix, compatibility matrix — re-validated across plaintext
  + TLS — then tag.
- **Future.** HTTP/2 (design kept non-precluding), compression (with bomb limits),
  client mode.

## Release versions

One minor per milestone (SemVer 0.x — anything may change before 1.0.0):

| Version | Milestone | Status |
|---|---|---|
| 0.1.0 | M0 — startup & design freeze | done |
| 0.2.0 | M1 — pure HTTP core | done |
| 0.3.0 | M1.5 — driver model checkpoint | done |
| 0.4.0 | M2 — plaintext edge | released 2026-06-15 |
| 0.5.0 | M3 — TLS edge | blocked on kroopt |
| 0.6.0 | M4 — full hardening (plaintext + TLS) | after 0.5.0 |
| 1.0.0 | stable release | requires maintainer confirmation |

The hardening already in the tree — observability, RFC 016 lifecycle, interop corpus,
audit, proof/trust/test matrix, CI gate — lands in **0.4.0** as part of the plaintext
edge (the limits/timeouts were M2's own acceptance criteria). **0.6.0 (M4)** re-runs and
extends that discipline so the matrix, conformance/interop suite, and CI gate also cover
the TLS path — which is why M4 follows M3 rather than preceding it. Nothing is tagged
until cut, and **1.0.0 is never cut without explicit maintainer confirmation.**

RFCs: 001 scope · 002 connection abstraction · 003 framing soundness · 004 parser ·
005 response · 006 routing · 007 serve loop · 008 PlainIotaktConn · 009 TlsConn
(gated) · 010 errors/limits/backpressure · 011 proof-trust-test · 012 CI/release ·
013 HTTP/2 readiness.
