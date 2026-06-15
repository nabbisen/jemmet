# jemmet

*A small, auditable, formally-disciplined HTTP/1.1 edge server for Lean 4.*

[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](./LICENSE)

## Overview

jemmet is the internet-facing **HTTP/1.1 edge server** of a three-project Lean
stack. It terminates its own connections — plaintext directly, and HTTPS via
kroopt — parses HTTP itself, and proves the framing-soundness property that makes a
verified edge worth more than an unverified one.

```
jemmet (HTTP)  ──▶  kroopt (TLS)  ──▶  iotakt (non-blocking I/O)
   │                                      │
   └────────── iotakt directly (plaintext)┘
```

iotakt moves bytes; kroopt secures bytes; jemmet interprets bytes.

## Why / when

Use jemmet when you want the process actually exposed to the internet to be the
verified one — no unverified proxy in front. jemmet is the edge, not an app server
behind nginx. Its headline guarantee is **no HTTP request smuggling / desync**,
machine-checked, plus a bounds-safe parser, total routing, and well-formed
responses.

## Status

**Pre-implementation, M0 in progress.** This tree is the project seed —
requirements, external design, the RFC roadmap, and the full RFC set — now with a
buildable Lake skeleton and the keystone landed:

- **RFC 002 (the connection abstraction) is implemented**: the `Conn` interface plus
  `ConnProgress`/outcome/metadata/error types (`Jemmet/Conn/Conn.lean`), the
  deterministic in-model `FakeConn` (`Jemmet/Conn/Fake.lean`), the **FakeConn
  determinism proof** (`Jemmet/Proofs/ConnFakeDet.lean`, axiom-clean), and the
  **`Conn` conformance suite** (`Test/`, run via `lake test`).

Implementation then proceeds M0→M4 (see `ROADMAP.md`): the pure HTTP core (no
wiring), then a plaintext edge over iotakt, then HTTPS via kroopt (gated on kroopt's
real-iotakt validation), then hardening and v0.1.

## Build

```sh
lake build            # core library (Jemmet)
lake build JemmetProofs   # the proven core
lake test             # the Conn conformance suite
python3 scripts/check-cleanliness.py   # assert 0 sorry/axiom/unsafe (RFC 011/012)
```

Toolchain: Lean 4.15.0 (pinned in `lean-toolchain`). No external dependencies yet —
the trusted computing base is the Lean runtime/toolchain only; iotakt and kroopt are
vendored as pinned tarballs at M2/M3 (RFC 001/012).

## Design notes

- One **connection abstraction** (`recv`/`send`/`flush`/`close`/`metadata`, each
  returning a `ConnProgress`) that plaintext and TLS both implement, so the HTTP path
  is identical for both — TLS is a wiring choice, not a code branch.
- jemmet consumes iotakt strictly at the **byte level**; it owns all HTTP parsing
  (iotakt's HTTP modules are stand-ins it supersedes).
- Mostly **TESTED** (conformance via interop) with a focused **PROVEN** core
  (framing soundness, parser bounds, routing totality, response well-formedness,
  keep-alive boundaries) and **ASSUMED** siblings (iotakt, kroopt).

## More detail

- `docs/jemmet_requirements_v2.md` — executive summary, library requirements, threat
  model / security requirements.
- `docs/jemmet_external_design_v2.md` — the connection abstraction, parser, framing
  engine, response, routing, serve loop.
- `docs/jemmet_rfc_roadmap_v2.md` — milestones and the RFC breakdown.
- `rfcs/` — the RFC set (adopts RFC 000 lifecycle, vendored in `rfcs/done/`).

## License

Apache-2.0 · author: nabbisen. See `LICENSE` and `NOTICE`.
