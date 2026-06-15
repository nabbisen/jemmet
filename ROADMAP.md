# jemmet ROADMAP

Full detail: `docs/jemmet_rfc_roadmap_v2.md`. Central fact: the plaintext edge
depends only on iotakt (contract confirmed) and ships without waiting for kroopt;
TLS is a later additive step gated on kroopt's real-iotakt validation.

- **M0 — Startup & design freeze.** Skeleton, conventions, RFC 001 (scope +
  iotakt-v1.0 decision) and RFC 002 (connection abstraction). Seed from
  iotakt:jemmet-handoff/prototype.
- **M1 — Pure HTTP core (no wiring).** Parser, framing engine, response serializer,
  routing, the `Conn` interface, `FakeConn`. Headline proofs begin
  (framing soundness, parser bounds, router totality, response wf). *Parallel-safe.*
- **M2 — Plaintext edge (gated only on iotakt).** `PlainIotaktConn`, serve loop /
  driver, keep-alive (+ proven boundary), chunked, limits/timeouts/backpressure.
  Usable plaintext HTTP/1.1 edge without kroopt.
- **M3 — TLS edge (gated on kroopt).** `TlsConn` over kroopt once its
  `IotaktTransport` is validated; ALPN; HTTPS E2E; plaintext+TLS listeners coexist.
- **M4 — Hardening & v0.1.** Error/limit/timeout matrix, observability, docs, CI
  gate, proof/trust/test matrix, compatibility matrix, tag.
- **Future.** HTTP/2 (design kept non-precluding), compression (with bomb limits),
  client mode.

RFCs: 001 scope · 002 connection abstraction · 003 framing soundness · 004 parser ·
005 response · 006 routing · 007 serve loop · 008 PlainIotaktConn · 009 TlsConn
(gated) · 010 errors/limits/backpressure · 011 proof-trust-test · 012 CI/release ·
013 HTTP/2 readiness.
