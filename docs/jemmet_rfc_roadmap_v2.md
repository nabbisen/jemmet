# jemmet RFC Roadmap v1

**Project:** jemmet
**Document type:** RFC roadmap and milestone plan (§5 road map + §6 RFC milestones)
**Status:** Draft v2 (revised per senior review)
**Preceded by:** jemmet Requirements v1, jemmet External Design v1

This document defines jemmet's milestones (§5) and the RFC set mapped onto them
(§6). It applies the lesson kroopt learned: build the smallest verifiable thing
first, and gate cross-project integration so a mismatch cannot force rework in two
projects at once.

---

## 5. Road Map (milestones)

The central sequencing fact: **the plaintext edge depends only on iotakt (whose
consumer contract is confirmed), so it ships without waiting for kroopt; TLS is a
later, additive wiring step gated on kroopt's real-iotakt validation.**

```text
M0  Project startup & design freeze
M1  Pure HTTP core (no wiring)          ← parallel-safe; the "start now" bucket
M2  Plaintext edge server               ← gated only on iotakt (confirmed)
M3  TLS edge server                     ← gated on kroopt IotaktTransport validation
M4  Hardening (0.6.0)
(future) HTTP/2, compression, client mode
```

### M0 — Project startup & design freeze
Lake project (Lean 4.15.0), repo conventions, `rfcs/` adopting iotakt RFC 000,
README/ROADMAP/CHANGELOG, CI skeleton. Requirements + external design accepted.
**RFC 001 (scope/boundary, the iotakt-v1.0 dependency decision)** and **RFC 002
(connection abstraction)** written. Seed from `iotakt:jemmet-handoff/prototype`.
*Acceptance:* docs accepted; RFC 001/002 accepted; iotakt dependency decision
recorded; project builds an empty skeleton.

### M1 — Pure HTTP core (no wiring) — **the parallel-startable bucket**
HTTP/1.1 request parser, the framing engine, the response serializer, routing, the
`Conn` interface, and `FakeConn`. All pure / deterministic; no iotakt or kroopt
wiring. The headline framing-soundness and parser-bounds proofs begin here over
`FakeConn`-driven tests. *Acceptance:* parse→route→respond runs end-to-end over
`FakeConn`; framing-soundness, parser-bounds, router-totality, response-wf proofs
build clean (no project-local `sorry`/`axiom`/`unsafe`); parser fuzzers run.

### M1.5 — Driver model checkpoint (added per review)
Before `PlainIotaktConn` is treated as stable, a deterministic **fake
henret/iotakt event-trace runner** (RFC 014) must pass an adversarial suite: stale
`FdKey` events; duplicate readiness/coalescing; timeout/read/write in one batch;
close-then-reuse raw fd; partial write + re-arm; pipelined request with carried
remainder; handler timeout/cancellation. RFC 010 (limits/backpressure/error policy)
and RFC 014 (event semantics) and RFC 015 (handler policy) are **accepted here** —
they shape `Conn`, `ConnState`, and response streaming, so they precede RFC 007/008
completion. *Acceptance:* the event-trace runner passes the adversarial suite; the
egress boundedness invariant (RFC 010) holds in model/stress tests.

### M2 — Plaintext edge server — gated only on iotakt
`PlainIotaktConn` over the confirmed iotakt binding spec; the serve loop/driver
(`runStepAuto` dispatch, per-`FdKey` demux, ack-discipline); keep-alive (with the
proven request-boundary state machine), chunked, request-size/connection limits →
413/431; write backpressure and timeouts. *Acceptance:* a real **plaintext**
HTTP/1.1 request from curl gets a correct `HTTP/1.1` response; keep-alive and a
pipelined pair work; limits and timeouts enforce; two concurrent connections
interleave on one loop. Delivers a usable plaintext edge **without kroopt**.

### M3 — TLS edge server — gated on kroopt
`TlsConn` over kroopt (once kroopt's `IotaktTransport` is validated over real
iotakt); TLS-vs-plaintext chosen by listener/port; ALPN → handler/protocol
selection; HTTPS E2E. *Acceptance:* the **TLS progress matrix** (RFC 009 — handshake
read/write ordering, ciphertext-backlog backpressure, mid-request close_notify, EOF
without close_notify, ALPN variants, slow-draining TLS client, graceful shutdown
with pending close_notify) passes, **not just** happy-path curl/browser HTTPS; the
HTTP path is byte-identical to M2; plaintext and TLS listeners coexist.

### M4 — Hardening (0.6.0)
Error-policy completeness, full limit/timeout matrix, observability (redacted),
docs (mdbook), conformance/interop suite, the proof/trust/test matrix finalized,
CI gate (build + proofs + unit + plaintext E2E + HTTPS E2E + fuzzers), compatibility
matrix. *Acceptance:* full suite green; matrix current and honest; v0.1 tagged and
archived.

### Future (post-v0.1)
HTTP/2 (ALPN `h2`, multiplexed streams over the existing loop), content
compression (with decompression-bomb limits), outbound/client mode, performance
work. Each a forward RFC; none a v0.1 blocker.

### Gating summary
- M0, M1: independent — start now.
- M2: needs iotakt only (contract confirmed) — start once M1's `Conn` interface and
  `PlainIotaktConn` are ready; ideally on a **cut iotakt v1.0** (RFC 001).
- M3: **hold** until kroopt's `IotaktTransport` is implemented and its interop
  re-validated over real iotakt — so jemmet is never layered on an unvalidated
  transport boundary.

---

## 6. RFC Milestones (the RFC breakdown)

Each detailed RFC follows the template in `rfcs/README.md`. Ordering de-risks the
project: lock scope and the keystone interface, build the provable pure core, then
integrate plaintext, then TLS, then harden.

### RFC 001 — Scope, boundary, non-goals, and the iotakt-v1.0 dependency
**Milestone:** M0 · **Layer:** cross-cutting · **Deps:** none
Locks jemmet's identity (verified HTTP edge), the three-project boundary, the
byte-level iotakt consumption (no reuse of iotakt's HTTP modules), the non-goals,
and the **iotakt-v1.0 gate decision** (cut v1.0 vs. pin a `-dev` candidate) plus
the vendored-tarball dependency + compatibility-matrix policy.
*Outputs:* boundary statement, non-goals, dependency decision. *Proof/test:* none.

### RFC 002 — The connection abstraction (keystone)
**Milestone:** M0/M1 · **Layer:** `Jemmet.Conn` · **Deps:** 001
The `Conn` interface (`recv`/`send`/`flush`/`close`/`metadata`), the
plaintext-consumption `send` semantics, the heavy-instance (`IO`) effect model,
the unified `ConnError`/close model, and the three instances'
contracts. Designed against **both** the iotakt binding spec and kroopt's `TlsConn`
shape so they are uniform.
*Outputs:* the typeclass + outcome/metadata/error types; `FakeConn` contract.
*Proof/test:* `FakeConn` determinism; instance-conformance test plan.

### RFC 003 — HTTP framing soundness and smuggling defense (headline)
**Milestone:** M1 · **Layer:** `Jemmet.Http.Framing` · **Deps:** 002, 004
The framing engine and its single-valued resolution of Content-Length /
Transfer-Encoding / Connection; the rejection rules; and the **proof** that no
ambiguous boundary interpretation exists (no smuggling) — jemmet's analog of
kroopt's no-early-plaintext.
*Proof:* `FramingSound` (unique boundaries or rejection). *Test:* smuggling-vector
corpus; chunked edge cases; fuzzing.

### RFC 004 — HTTP/1.1 request parser and bounds safety
**Milestone:** M1 · **Layer:** `Jemmet.Http` · **Deps:** 002
The bounds-safe byte reader, request-line and header parsing, header
name/value validation, the `HttpRequest` model, and limit handling
(request-line/header count/size → 400/414/431).
*Proof:* `ParserBounds` (bounds-safe by construction). *Test:* malformed-input
corpus; header-injection rejection; fuzzers (request line, headers).

### RFC 005 — Response model and HTTP/1.1 serialization
**Milestone:** M1 · **Layer:** `Jemmet.Http.Response` · **Deps:** 004
`HttpResponse`, correct HTTP/1.1 status-line serialization (superseding iotakt's
`HTTP/1.0` stand-in), auto `Date`/`Server`/`Content-Length`/chunked, keep-alive
`Connection`, and output validation (no response splitting).
*Proof:* `ResponseWf` (well-formed; no header injection). *Test:* serialization
golden tests; CRLF-injection rejection.

### RFC 006 — Routing
**Milestone:** M1 · **Layer:** `Jemmet.Route` · **Deps:** 004
Method+path dispatch, `:param` capture, the `Handler` type and request context,
404/405. jemmet's own router (iotakt's is not used).
*Proof:* `RouterTotal` (total, deterministic dispatch). *Test:* route-table cases;
adversarial-key complexity bound.

### RFC 007 — Serve loop and connection driver
**Milestone:** M2 · **Layer:** `Jemmet.Serve` · **Deps:** 002, 003, 005, 006, 008
The driver-owned `runStepAuto` loop, per-`FdKey` demultiplexing, the
ack-discipline, the per-connection state machine (read→frame→route→respond), and
the keep-alive request-boundary handling. Shared infrastructure for plaintext and
TLS.
*Proof:* `KeepAlive` (request-boundary state machine). *Test:* multi-connection
interleave; pipelining; keep-alive over `FakeConn` then `PlainIotaktConn`.

### RFC 008 — PlainIotaktConn (iotakt byte-level binding)
**Milestone:** M2 · **Layer:** `Jemmet.Conn.Plain` · **Deps:** 002
The `Conn` instance over iotakt: `recvAck`/`sendAck`/`enableWrite`/`disableWrite`/
`closeConnection`, `FdKey` translation, and the iotakt `ReadResult`/`WriteResult`
→ outcome mapping (incl. `interrupted`→retry, `closed`→error), per the iotakt
binding spec.
*Test:* against real iotakt — readable-across-records (ack/coalescing), forced
partial write (suffix/`offset` + re-arm), two concurrent connections.

### RFC 009 — TlsConn (kroopt binding) — gated
**Milestone:** M3 · **Layer:** `Jemmet.Conn.Tls` · **Deps:** 002, 007, 008
The `Conn` instance over kroopt: drive kroopt progress inside `recv`/`send`/
`flush`, surface ALPN/secure in `metadata`, route close through kroopt then iotakt.
Written **with** the kroopt team against kroopt's `TlsConn` surface; **held** until
kroopt's `IotaktTransport` is validated over real iotakt.
*Test:* HTTPS E2E (curl/browser) through the full stack; byte-identical HTTP path
to M2.

### RFC 010 — Errors, limits, timeouts, and write-backpressure
**Milestone:** M2/M4 · **Layer:** `Jemmet.Serve.Backpressure` + cross-cutting ·
**Deps:** 004, 007
Deterministic malformed-input→status mapping; the full limit matrix
(request-line/header/body/connection/chunk, with 400/413/431/431); read timeouts
(header/body/idle) and **write-side backpressure + slow-client timeout** (egress
slowloris); bounded pending output.
*Test:* limit-enforcement and timeout scenarios; slow-reader/slow-writer.

### RFC 011 — Proof, trust, and test matrix
**Milestone:** M1→M4 · **Layer:** docs/verification · **Deps:** 003–009
The claim taxonomy (PROVEN: framing soundness, parser bounds, router totality,
response wf, keep-alive boundary; TESTED: HTTP/HTTPS interop conformance; ASSUMED:
iotakt, kroopt, runtime; OUTSCOPE: crypto, kernel, volumetric DoS, authn/z), the
theorem inventory, the fuzzing targets, and the CI classification — with the
matrix-honesty guard (assert 0 `sorry`/`axiom`/`unsafe` in the proven core and that
the theorem count matches the matrix).
*Outputs:* `docs/proof-trust-test-matrix.md`.

### RFC 012 — CI, packaging, and release gates
**Milestone:** M4 · **Layer:** project ops · **Deps:** 003–011
Build + proof build + unit suites + plaintext E2E (curl) + HTTPS E2E (gated) +
fuzzers + matrix-honesty guard; tarball release layout (version in name, files at
root); the compatibility matrix; vendored iotakt/kroopt pinning.
*Outputs:* CI gate, release checklist.

### RFC 013 — HTTP/2 readiness and future protocols
**Milestone:** future · **Layer:** forward planning · **Deps:** 002, 007
What v0.1 must not preclude for h2 (multiplexed streams over one connection, ALPN
`h2` selection via `metadata`), and the parking lot (compression with bomb limits,
client mode). No v0.1 obligations beyond "do not foreclose."

### RFC 014 — Driver & henret/iotakt event semantics
**Milestone:** M1.5/M2 · **Layer:** `Jemmet.Serve` (contract) · **Deps:** 002, 007
The event-batch ordering, stale-event handling, per-batch step bounds/fairness, the
close/cancel/timeout/pending-output interaction, the no-nested-`runStepAuto` rule,
and the deterministic fake event-trace runner. The highest-risk seam made a
model-level contract.
*Proof/test:* no event for a removed `FdKey`; batch termination; the adversarial
event-trace + property suites.

### RFC 015 — Handler execution policy
**Milestone:** M2 · **Layer:** `Jemmet.Serve` · **Deps:** 007, 014
Handler execution cannot block the loop: henret task-handoff (default) with a
phase-indexed `WaitingForHandler` (deadline, cancellation), a strict-inline fast
path, and a bounded in-flight cap. Coordinates with iotakt/henret on the task API.
*Proof/test:* total phase transitions; slow handler does not stall the loop;
deadline cancels; no late response after close.

### RFC 016 — Production lifecycle
**Milestone:** M4 · **Layer:** ops · **Deps:** 007, 010, 012
Graceful shutdown (bounded drain), resource-leak detection, redacted observability,
the compatibility matrix (incl. tested Linux backend), and documented failure modes.

### Dependency map
```text
001
 ├─ 002 ─┬─ 003 ──┐
 │        ├─ 004 ─┼─ 005
 │        │        └─ 006
 │        ├─ 008 ──┐
 │        ├─ 010 ──┤   (accepted at M1.5, before 007/008 complete)
 │        ├─ 014 ──┤   (event semantics; M1.5)
 │        ├─ 015 ──┤   (handler policy; needs 014)
 │        └─ 007 ◀─┴─ (003,005,006,008,010,014,015) ─┬─ 009 (gated; TLS progress matrix)
 │                                                    └─ 016 (lifecycle; M4)
 ├─ 011 (spans 003–010,014,015)
 └─ 012 (spans 003–016) ;  013 (future)
```

### v0.1 RFC scope
Required for v0.1: 001–008, 010, 011, 012, 014, 015, 016. Gated-but-required for
HTTPS: 009. Forward only: 013. RFC 010/014/015 are accepted at **M1.5**, before
007/008 are considered complete.

---

## 7. Recommended first batch
Write RFC 001 (scope + iotakt-v1.0 decision) and RFC 002 (connection abstraction)
first — they lock the boundary and the keystone everything composes around — then
the M1 pure-core batch (003 framing soundness, 004 parser, 005 response, 006
routing) which can proceed in parallel with no wiring. Begin RFC 007/008 (plaintext
integration) once 002 is frozen and (ideally) iotakt v1.0 is cut. Hold RFC 009
(TLS) until kroopt's real-iotakt binding is validated.
