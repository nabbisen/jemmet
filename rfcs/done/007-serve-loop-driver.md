# RFC 007: Serve loop and connection driver

## Status
Implemented (M2 — serve loop / driver; keep-alive boundary proven)

## Summary
The driver-owned event loop that pulls iotakt events via `runStepAuto`,
demultiplexes by `FdKey`, and drives each connection's read→frame→route→respond→
keep-alive state machine through the `Conn` abstraction. Shared infrastructure for
plaintext and TLS connections.

## Motivation
This is where iotakt's pull-based, ack-disciplined, multiplexed event model
(confirmed in the iotakt consumer review) meets jemmet's per-request logic. It must
be correct for many connections on one loop, must honor the ack-discipline, and
must keep the keep-alive request boundary sound (a smuggling surface).

## Goals
1. Own the `runStepAuto` loop; dispatch `newConnection`/`dataReady`/`tick`.
2. Demultiplex by `FdKey`; keep per-connection state.
3. Drive each connection via `Conn` (uniform for plaintext and TLS).
4. A proven keep-alive request-boundary state machine.
5. Sweep timeouts on `tick` (slowloris defense); cooperate with backpressure
   (RFC 010).

## Non-Goals
Transport specifics (RFC 008/009); parsing/framing/routing/response (RFC 003–006);
HTTP/2 multiplexing (kept non-precluded; RFC 013); the event-batch contract
(RFC 014); handler execution policy (RFC 015) — this RFC consumes both.

## Phase-indexed ConnState (added per review)
`ConnState` is phase-indexed so error handling and proofs are total over phases:
```text
ReadingHead → ReadingBody → Dispatching
  → WaitingForHandler (deadline, handlerTaskId)   -- RFC 015
  → WritingResponse → (KeepAlive ↺ | Closing) → Closed
```
Per-phase behavior, the event-batch ordering, stale-event drop, and the
close/cancel/timeout/pending-output interaction are defined in RFC 014; the
`(phase, error) → action` policy is defined in RFC 010.

## External Design
```text
loop ← EventLoop.create cfg ; add listeners
repeat:
  (loop, events) ← loop.runStepAuto
  for ev in events:
    | newConnection key _ → conns[key] := ConnState.fresh (mkConn key)   -- Plain|Tls by listener
    | dataReady key e     → conns[key] := step conns[key] e
    | tick now            → sweepTimeouts now
```
Per-connection `step` (one bounded progress step, then yield):
```text
readable : Conn.recv → feed parser; on a fully-framed request:
            dispatch → handler → response → serialize → Conn.send/flush
writable : Conn.flush; when drained, disableWrite; advance keep-alive
eof/error: mid-request ⇒ truncated (close); else graceful close
keepAlive: after a response fully flushes, reset per-request state, carry pipelined
           remainder, arm idle timeout, await next request
```
- **Ack-discipline:** `Conn.recv`/`send` use iotakt `recvAck`/`sendAck` inside the
  instance; the loop never bypasses the ack.
- **Uniform TLS:** for a `TlsConn`, `Conn.recv` drives kroopt then yields
  plaintext; the loop is unchanged.
- **h2-non-precluding:** `ConnState` is structured so a stream-multiplexed state can
  later replace the single-request state without reshaping the loop.

## Proof Obligations
`KeepAlive`: the per-connection state machine consumes exactly one well-framed
request (per RFC 003) before considering the next, carrying any pipelined remainder
without loss or overlap — the boundary half of the no-smuggling property. Per
review, the proof MUST cover the **malformed and partial** states, not only the
happy path: mid-request EOF; timeout during head/body; malformed head after a
pipelined valid request; rejected first request with trailing bytes; response-flush
failure; close during pending output; carried remainder after chunked decode. The
phase transition relation is total (every `(phase, event)` has a defined action via
RFC 010); a malformed request after a partial response has begun is
**unrepresentable** by construction.

## Test Obligations
Multi-connection interleave on one loop; pipelined requests; keep-alive reuse;
mid-request EOF → truncated; over `FakeConn` (M1) then `PlainIotaktConn` (M2).

## Trust / Assumption Changes
Relies on iotakt's pull/ack/demux model (ASSUMED, confirmed in the consumer
review).

## Acceptance Criteria
Loop + per-connection state machine implemented; `KeepAlive` proven; multi-conn and
pipelining tests pass over `FakeConn` and real iotakt; timeouts sweep on `tick`.

## Alternatives Considered
- *Callback registration with iotakt:* not how iotakt works — it is pull-based via
  `runStepAuto` (consumer review O3).
- *One connection per loop:* rejected — one loop multiplexes all connections.

## Open Questions
1. Exact `ConnState` shape that stays h2-extensible (RFC 013).
2. Fairness across connections within one `runStepAuto` batch (bounded work per
   connection per step).
