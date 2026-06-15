# RFC 008: PlainIotaktConn (iotakt byte-level binding)

## Status
Proposed

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
