# RFC 008: PlainIotaktConn (iotakt byte-level binding)

## Status
Implemented (M2 — PlainIotaktConn over the iotakt byte-level binding)

## Summary
The `Conn` instance over iotakt for plaintext connections: maps `recv`/`send`/
`flush`/`close` onto iotakt `recvAck`/`sendAck`/`enableWrite`/`disableWrite`/
`closeConnection`, translates `FdKey`, and maps iotakt result cases into the
`Conn` outcomes — exactly per the confirmed iotakt consumer binding spec.

## Motivation
This is the thin `Conn` instance and jemmet's first real iotakt wiring. The iotakt
consumer review confirmed the contract and supplied the binding spec; this RFC
implements it, observing the ack-discipline and the result-case mappings the review
flagged.

## Goals
1. Implement `Conn` over an iotakt `EventLoop` + `FdKey`.
2. Use `recvAck`/`sendAck` (never bare reads) so coalesced readiness is acked.
3. Translate `FdKey` (iotakt `{raw:Int, gen:Nat}` ↔ jemmet/`Conn` identity).
4. Map iotakt `ReadResult`/`WriteResult` into `RecvOutcome`/`SendOutcome`/
   `FlushOutcome`, including `interrupted`→retry and `closed`→error.

## Non-Goals
TLS (RFC 009); the loop (RFC 007); changing iotakt (forbidden, RFC 001).

## External Design
```text
recv κ n  → EventLoop.recvAck key n   ⇒ ReadResult →
              bytes b → consumed-into-state; wouldBlock → wouldBlock;
              eof → eof; interrupted → retry; error e → ConnError
send κ b  → EventLoop.sendAck key b offset len ⇒ WriteResult →
              wrote n → SendOutcome.consumed n.toNat (keep suffix at offset+n);
              wouldBlock → wouldBlock; interrupted → retry;
              closed → ConnError.reset; error e → ConnError
flush κ   → drain owned suffix via sendAck (advancing offset); enableWrite while
            suffix remains; disableWrite when drained
close κ m → EventLoop.closeConnection key   (deregister + close fd once + cancel
            owning Henret task if recorded; jemmet never touches the raw fd)
```
`FdKey` translation guards the `Int`/`Nat`↔`UInt64` conversion (kernel fds are
small non-negative); identity is for demux/logging only.

## Proof Obligations
None new (passes RFC 002's `Conn` conformance suite).

## Test Obligations
Against **real iotakt** (the three deltas the consumer review called out):
1. a connection that stays readable across multiple records (proves ack/coalescing
   wiring);
2. a forced partial write (proves suffix/`offset` + `enableWrite` re-arm);
3. two concurrent connections interleaving on one `runStepAuto` loop (proves
   demux).
Plus the `Conn` conformance suite.

## Trust / Assumption Changes
Binds to iotakt's confirmed consumer surface (ASSUMED).

## Acceptance Criteria
`PlainIotaktConn` passes the conformance suite and the three real-iotakt tests; a
plaintext HTTP/1.1 request via curl is served end-to-end (with RFC 007).

## Alternatives Considered
- *Bare `Io.recv`/`Io.send` without ack:* rejected — coalescer would suppress the
  next readiness (consumer review O6); use `recvAck`/`sendAck`.

## Open Questions
1. Whether to hold the `EventLoop` by reference or thread it through the loop's
   state (interacts with RFC 007's loop ownership).

## Implementation note (M2, delivered)
`Jemmet/Iotakt.lean` implements `PlainIotaktConn σ` as the `Conn` instance over iotakt's
**real Lean-only model types** (`Iotakt.Model.FdKey`/`IoEvent`/`IoErrno`/`ReadResult`/
`WriteResult`), vendored under `vendor/iotakt-0.13.1` and built standalone (no henret, no
native C). `FdKey` refinement is the identity on fields (`ofIotaktKey`/`toIotaktKey`),
since iotakt's `{raw : Int, gen : Nat}` matches jemmet's stand-in exactly.

**Open Question 1 resolved: thread the loop through state.** The native `EventLoop`
(recvAck/sendAck/enableWrite/disableWrite/closeConnection) needs the C epoll backend +
henret, so it is not buildable in the verification sandbox. The binding takes those ops
behind `IotaktLoopOps σ` — a record of the exact EventLoop operations over real model
types — and threads `σ` **functionally** through the connection (`recv`/`send`/`flush`/
`close` return the updated `σ` inside `κ`), matching iotakt's functional EventLoop
(`recvAck : EventLoop → … → IO (EventLoop × ReadResult)`). This is the right answer to
OQ1: the loop is threaded, not held by reference, so it composes with RFC 007 loop
ownership and stays deterministic against a model loop.

**Mappings.** `ReadResult.bytes/wouldBlock/eof/interrupted/error` →
`RecvOutcome.bytes/wouldBlock/eof/(wouldBlock — EINTR retry)/error`; `WriteResult.wrote/
wouldBlock/interrupted/closed/error` → `SendOutcome.consumed/wouldBlock/(wouldBlock)/
(error .reset)/error`; `IoErrno` → `ConnError` (reset/broken-pipe/not-connected →
`.reset`, others → `.transport`). Clean EOF is `RecvOutcome.eof`, never an error.

**Write-interest invariant by construction (RFC 010 / RFC 014 §4).** `send` takes
ownership of plaintext into the connection's `outBuf` and arms iotakt write interest;
`flush` drains via `sendAck`, keeps the unsent suffix on a partial write, and clears
write interest only when `outBuf` empties. So `ConnProgress.needsWrite ↔ ownedOutBytes >
0` holds after every op — the property proven in `EventSemantics` and asserted by the
conformance suite.

**Verified in-sandbox** by `Test/IotaktConformance.lean` over a deterministic `ModelLoop`
(23 checks): readable-across-records via per-record ack, partial-write re-arm (quota 3
over a 7-byte response, all bytes in order, interest held then cleared), two-connection
FdKey demux, and the errno/EOF/close mappings — every op's `ConnProgress` consistent.

**Deployment adapter (native E2E).** In an environment with the C toolchain + henret,
`IotaktLoopOps Iotakt.Loop.EventLoop` is a direct wrapper:
```text
recvAck      lp k n         := EventLoop.recvAck lp k n          -- (returns the raw-byte ReadResult)
sendAck      lp k ba off len:= EventLoop.sendAck lp k ba off len
enableWrite  lp k           := EventLoop.enableWrite lp k
disableWrite lp k           := EventLoop.disableWrite lp k
closeConn    lp k           := EventLoop.closeConnection lp k
```
With that instance and `EventLoop.runStepAuto` driving the RFC 014 dispatch, the curl
end-to-end acceptance criterion runs unchanged on the same `Conn`/serve-loop code paths
exercised here. Building the native backend (gcc + Linux epoll + henret v0.15.2) is the
deployment step; the Lean logic above is platform-neutral and proven/tested here.
