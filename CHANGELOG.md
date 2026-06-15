# Changelog

All notable changes to jemmet are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); jemmet releases as version-named
tarballs at logical breakpoints (RFC 012).

## [Unreleased]

### M0 — project startup & design freeze (in progress)

Added:
- Lake project skeleton pinned to **Lean 4.15.0** (`lean-toolchain`,
  `lakefile.toml`), with libraries `Jemmet` (core) and `JemmetProofs` (proven core),
  and the `conformance` test executable (`lake test`). No external dependencies.
- The full RFC set under `rfcs/proposed/` (001–016) plus the **RFC 000 lifecycle
  policy vendored** into `rfcs/done/` so the repo describes its own policy.
- Project docs under `docs/` (requirements, external design, RFC roadmap), aligned to
  the `_v2` filenames the README references.
- `scripts/check-cleanliness.py` — the RFC 011/012 cleanliness guard (asserts no
  project-local `sorry`/`axiom`/`unsafe`), comment-aware.
- CI skeleton (`.github/workflows/ci.yml`): build → proofs → cleanliness → test.

### RFC 002 — the connection abstraction (keystone): implemented

Added:
- `Jemmet/Conn/Conn.lean` — the `Conn` typeclass (`recv`/`send`/`flush`/`close`/
  `metadata`, each returning a `ConnProgress`), the unified `ConnError`/`CloseState`
  model, the `RecvOutcome`/`SendOutcome`/`FlushOutcome`/`CloseMode` outcomes,
  `ConnMetadata`/`FdKey`/`PeerAddr`, and `ConnProgress.consistent` (write-interest
  accounting + closed-is-quiescent invariants).
- `Jemmet/Conn/Fake.lean` — `FakeConn`, the deterministic in-model instance: scripted
  inbox, owned-output/sink model, per-step write schedule (partial sends /
  backpressure), built on total pure transition functions.
- `Jemmet/Proofs/ConnFakeDet.lean` — **FakeConn determinism** (the RFC 002 proof
  obligation): each `Conn` op is `pure` of its pure transition, and replay of an
  operation script is exact. Axiom-clean (only `Quot.sound` via `funext`).
- `Test/Conformance.lean` + `Test/Main.lean` — the **`Conn` conformance suite** (the
  RFC 002 test obligation): would-block, split reads (`ownedInBytes`), partial send +
  retry, flush draining, graceful vs abortive close, EOF/error mapping, with
  `ConnProgress.consistent` asserted after every operation. 49/49 checks pass.

Notes:
- RFC 002 remains in `rfcs/proposed/` (not yet moved to `done/`) until the M1
  pure-core set is accepted together, to avoid prematurely breaking the many inbound
  cross-references to `../proposed/002…`.
