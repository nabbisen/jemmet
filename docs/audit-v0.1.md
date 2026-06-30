# jemmet v0.1 — Codebase Audit

Scope: (1) the codebase fulfils the "done" RFCs; (2) dead code removed where genuinely
useless; (3) tests match the requirements and external design; (4) the codebase matches the
tests; (5) the docs fit the codebase. Findings are recorded with the action taken. All fixes
in this pass are built, gated (`scripts/ci.sh`), and tested (`lake test`, exit 0): 52 core +
test modules, 94 proven theorems (all axiom-clean), 270 conformance checks across 11 suites,
and 5,400 fuzz iterations.

> **Note (post-audit, v0.4.1).** This audit reflects the **v0.1 (v0.4.0)** state, when
> iotakt (0.13.1) and henret (0.15.2) were consumed as *vendored* Lean-only trees. After
> this audit, the dependency-consumption mechanism changed: siblings are now **pinned Lake
> git dependencies** (iotakt 0.14.6, henret 0.34.4), per RFC 001 *Amendment (v0.4.1)* and
> `docs/compatibility.md`. The findings below are unchanged — they record the audited state.

---

## 1. Fulfilment of the "done" RFCs

A "done" RFC is one whose milestone (M0–M2, M1.5, and the implemented M4 tiers) is complete.
RFC 009 (TLS) is gated on kroopt and not started; RFC 013 (HTTP/2) is forward-only.

| RFC | Subject | Deliverable in tree | Status |
|---|---|---|---|
| 001 | Scope / boundary / iotakt-v1.0 pin | `docs/compatibility.md`, vendored `iotakt` (byte-level only) | **Done** |
| 002 | `Conn` abstraction (keystone) | `Conn/Conn.lean`, `Conn/Fake.lean`; `ConnFakeDet` proofs; `Conformance` (49) | **Done** |
| 003 | Framing soundness / no smuggling | `Http/Framing.lean`; `FramingSound`, `FramingSoundStream`; `HttpConformance`, interop corpus | **Done** |
| 004 | Parser bounds safety | `Http/Bytes.lean`, `Http/Request.lean`; `ParserBounds`; fuzzers | **Done** |
| 005 | Response model + serialization + streaming | `Http/Response.lean`, `Http/Stream.lean`; `ResponseWf`, `StreamBound` | **Done** |
| 006 | Routing | `Route/*`; `RouterTotal`; integration + interop tests | **Done** |
| 007 | Serve loop / driver | `Serve/Loop.lean`, `Serve/ConnState.lean`; `KeepAlive`; `ServeConformance` | **Done** |
| 008 | `PlainIotaktConn` (iotakt binding) | `Iotakt.lean` (`JemmetIotakt`); `IotaktConformance` (43) | **Done** |
| 010 | Errors / limits / timeouts / backpressure | `Serve/Egress.lean`, `Serve/Backpressure`; `EgressBound`, `LimitStatus`; `LimitConformance` | **Done** (incl. the serve-path error-response fix below) |
| 011 | Proof / trust / test matrix | `docs/proof-trust-test-matrix.md`; matrix-honesty guard | **Done** |
| 012 | CI / packaging / release gate | `scripts/ci.sh`, `check-axioms.py`, `check-cleanliness.py` | **Done** |
| 014 | Driver / event semantics | `Serve/Event.lean`; `EventSemantics`; `EventConformance` | **Done** |
| 015 | Handler execution policy | `Serve/HandlerPolicy.lean`; `HandlerPolicy` proofs; `HandlerConformance`; `JemmetHenret` binding + `HenretConformance` | **Done** (incl. the deadline→503 fix below) |
| 016 | Production lifecycle | + `Serve/Lifecycle.lean` + `Proofs/Lifecycle` + `LifecycleConformance`; `docs/failure-modes.md`; observability; compatibility matrix | **Done** (completed after this audit) |
| 009 | TLS via kroopt | — | Not started (gated on kroopt) |
| 013 | HTTP/2 readiness | `ConnState` left h2-extensible; ALPN hook in `ConnMetadata` | Forward-only; not foreclosed (no v0.1 obligation) |

### Finding 1.A — RFC 016 was partial; now completed
At audit time RFC 016 had observability, the compatibility matrix, and connection-level
graceful close, but lacked server-level graceful shutdown, resource-leak detection, and a
failure-modes document. These were subsequently built: `Serve/Lifecycle.lean` (the bounded
graceful-shutdown machine, wired into the driver's accept/keep-alive/drain points),
`Proofs/Lifecycle` (9 theorems: bounded, leak-free, idempotent, absorbing), the `LeakReport`
audit, `Test/LifecycleConformance` (17/17), and `docs/failure-modes.md`. RFC 016 is now done.

### Finding 1.B — RFC 010/§3.4 gap: malformed input was not answered (FIXED)
The threat model (§3.4) requires every malformed input to map to a deterministic HTTP error
*response*. `serveBuffer` destructured `drain`'s outcome as `(reqs, rest, _e)` and **ignored
the parse error** — a rejected request was silently dropped, no reply sent. The parser
computed the correct status (and `LimitConformance` verified it at the parse level), but the
status never reached the wire. **Action:** added `errorResponse : ParseError → HttpResponse`
(each error → its `Status`, `Connection: close`) and made `serveBuffer` emit it and close on
a malformed request (no resync — RFC 003 danger-zone rule). Five end-to-end serve-error
checks added, plus an exhaustive check that `errorResponse`'s code equals the proven
`ParseError.statusCode`.

### Finding 1.C — RFC 015 gap: handler deadline produced no 503 (FIXED)
`stepHandler` mapped a tick past the deadline to a `.timedOut` phase, but nothing rendered
that phase to a response — so `timeoutResponse` (503) was never emitted. **Action:** added
`HandlerPhase.response` (ready → its response, timedOut → 503, else none) and defined
`writes := response.isSome`. Two checks added: a timeout renders a 503; a cancelled phase
renders nothing.

---

## 2. Dead-code cleanup

Method: extracted every top-level `def`/`abbrev` in the core and cross-referenced usage
(dotted calls included) across core, proofs, and tests. Eight were referenced nowhere; each
was classified rather than blindly deleted.

| Symbol | Verdict | Rationale |
|---|---|---|
| `Bytes.peek?` | **Removed** | Orphan reader primitive; no consumer in code, proofs, or tests, and no planned use. |
| `Iotakt.toIotaktKey` | **Removed** | Reverse `FdKey` translation; the driver holds iotakt `FdKey`s natively, so it is never needed. |
| `Serve.timeoutResponse` | **Now used** | Was orphaned by the RFC 015 gap (1.C); wired via `HandlerPhase.response`. |
| `Status.badRequest` / `payloadTooLarge` / `httpVersionNotSupported` | **Now used** | Wired by `errorResponse` (1.B); turned a partial status table into a fully-exercised one. |
| `Status.notModified` (304) | **Kept** | Part of the coherent public `Status` vocabulary for handler conditional responses; removing one standard code would leave the table arbitrarily incomplete. |
| `Stream.StreamSource.ofList` | **Kept** | Documented RFC 005 handler-streaming pull interface, awaiting driver integration (a planned feature, explicitly noted in the module). |

No other dead defs remain. (A `theorem composes` string flagged by a naive grep is docstring
prose inside a block comment, correctly skipped by the matrix-honesty guard — not code.)

---

## 3. Tests vs requirements and external design

Every requirement MUST and every external-design component maps to a proof, a conformance
suite, or both. No requirement MUST was found without coverage.

| Requirement / design area | Source | Coverage |
|---|---|---|
| `Conn` keystone (byte-level, plaintext-send semantics, heavy-instance IO, unified errors, three instances, `ConnProgress`, no nested driver) | §2.2, §4.3 | `Conformance` 49; `ConnFakeDet` proofs |
| Framing soundness / no smuggling | §2.3.1, §3.2.1, §4.4.3 | `FramingSound`, `FramingSoundStream`; `HttpConformance` 44; interop smuggling vectors 14; fuzz |
| Parser bounds safety | §2.3, §3.2.5, §4.4.1–2 | `ParserBounds`; fuzz (parser, headers, chunked) |
| Response HTTP/1.1 + no splitting | §2.3.2, §3.2.2, §4.4.5 | `ResponseWf`; integration response group; interop injection vectors |
| Routing (method+path, `:param`, 404/405) | §2.3.3, §4.5 | `RouterTotal`; integration routing; interop full-path |
| Keep-alive / pipelining boundaries | §2.3.4, §3.2.7, §4.6 | `KeepAlive`; `ServeConformance`; interop pipelining |
| Chunked both directions + streaming | §2.3.5, §4.4.4, §4.4.5 | `ChunkedBounds`, `StreamBound`; HTTP conformance; fuzz round-trip |
| Limits → status (414/431/413/400/505) | §2.3.6, §3.2.4, §4.4.5 | `LimitStatus` (proven mapping); `LimitConformance` 14; **serve-error responses (new)** |
| Timeouts: ingress + egress slowloris | §3.2.3, RFC 010 | `EgressBound` (proven); `IotaktConformance` egress + ingress read-timeout |
| Egress boundedness (three-tier) | §2.5a, §3.2.3, RFC 010 | `EgressBound` (proven); `IotaktConformance` |
| Driver event semantics | §2.5a, RFC 014 | `EventSemantics`; `EventConformance` 9; `IotaktConformance` driver |
| Handler non-blocking + deadline/cancel | §2.5a, RFC 015 | `HandlerPolicy` proofs; `HandlerConformance` 11; `HenretConformance` 8 |
| Redacted observability (no leak, no log injection) | §3.4, RFC 016 | `ObserveSafe` (proven); `ObserveConformance` 13 |
| Host requirement (RFC 9112 §3.2) | RFC 9110/9112 conformance | enforced in `parseRequest`; interop Host vectors 5 |
| iotakt byte-level binding | §1, §2.1, RFC 008 | `IotaktConformance` 43 over the model loop |
| henret task hand-off seam | §0, RFC 015 | `JemmetHenret` + `HenretConformance` 8 over real `Henret.step` |

The external-design module map (§4.2) matches the tree: `Conn/`, `Http/`, `Route/`, `Serve/`,
`Proofs/`, plus the isolated `Iotakt`/`Henret` bindings and `Observe`. No designed component
is missing; no module exists without a design home.

---

## 4. Codebase vs tests

Tests exercise real code paths (not stand-ins): conformance suites call the actual
`parseRequest`, `decideFraming`, `Router.dispatch`, `serialize`, `serveBuffer`, the real
`PlainIotaktConn` over a model iotakt loop, and the real `Henret.step` scheduler. The new
serve-error tests drive `serveBuffer` end to end, closing the previously-untested branch.

One honest nuance, consistent with the requirements: the **runtime** serve loop executes
handlers **inline** (the declared strict-inline fast path, §0 / RFC 015), with the loop-level
read timeout enforcing the deadline; the **asynchronous** task-handoff path is a *verified
model* (`HandlerPolicy` proofs) *validated against real henret* (`HenretConformance`) for when
it is wired into the runtime. So `HandlerConformance`/`HenretConformance` test the model and
the binding, not a running async executor — which is the correct scope for v0.1. This is
documented, not a mismatch.

---

## 5. Docs vs codebase

The proof/trust/test matrix (RFC 011) is the central doc. Audit found and fixed stale
numbers:

- `IotaktConformance`: 35/35 and 39/39 → **43/43 across 8 scenarios** (the ingress
  read-timeout scenario had been added without updating the matrix).
- `LimitStatus`: `statusCode_*` **×9 → ×10** (the `badHost` pin added during the interop
  phase).
- `IntegrationConformance` **→ 20/20**, `HandlerConformance` **→ 11/11** (this pass).
- `CHANGELOG.md` records the audit fixes; `compatibility.md` pins iotakt 0.13.1 and
  henret 0.15.2 (both vendored Lean-only).

The "94 proven theorems, all axiom-clean" claim was verified against the guard's enumeration
(the 95th raw grep hit is docstring prose, correctly excluded). The matrix's PROVEN/TESTED
rows otherwise match the modules and theorem names in the tree.

---

## Summary of actions taken

1. Closed the serve-path error-response gap (1.B) — `errorResponse` + `serveBuffer` emit and
   close; 6 new integration checks.
2. Closed the handler deadline→503 gap (1.C) — `HandlerPhase.response`; 2 new handler checks.
3. Removed two genuinely-dead defs (`peek?`, `toIotaktKey`); kept two planned/public ones.
4. Reconciled the matrix and CHANGELOG with the code.
5. Recorded RFC 016 as partial with the specific remaining pieces.

## Remaining work (not gaps in "done" RFCs — future milestones)

- RFC 009 (TLS via kroopt) — gated on the kroopt sources.
- The single deployment-only native step: `IotaktLoopOps Iotakt.Loop.EventLoop` over real
  epoll + henret, and the curl/HTTPS E2E.
