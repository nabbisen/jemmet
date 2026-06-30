# RFC 014: Driver and henret/iotakt event semantics

## Status
Implemented (M1.5 — driver event semantics + deterministic fake event-trace runner; proven)

## Summary
Makes the driver's interaction with the henret→iotakt event model a **model-level
contract**, not an implementation note: event batch ordering, stale-event
handling, tick-vs-I/O ordering, per-batch step bounds, and the interaction of
close, actor cancellation, timeout, and pending output. Backed by a deterministic
fake event-trace runner.

## Motivation
iotakt is not a socket wrapper; it translates readiness into henret-visible
messages, coalesces readiness, uses explicit ack discipline, and relies on
generation-protected `FdKey`s. If jemmet only models "events come from
`runStepAuto`," real failures remain possible: a stale readiness event after
`closeConnection`; a reused raw fd with a new generation while old state lingers;
a `tick` racing readable/writable in one batch; an owning henret task cancelled
while jemmet holds pending HTTP state; write interest disabled too early after a
partial flush; a handler blocking the driver so henret work and timers stall.
This is the review's #2 priority and the architecture's highest-risk seam.

## Goals
1. Specify the event-batch semantics jemmet relies on and enforces.
2. Define stale-event handling and the close/cancel/timeout/pending-output
   interaction as a total contract.
3. Provide a deterministic fake event-trace runner that can replay adversarial
   sequences.

## Non-Goals
The per-request HTTP state machine (RFC 007); transport specifics (RFC 008/009);
changing iotakt (forbidden — this RFC documents the contract iotakt already
provides per its consumer review, and how jemmet consumes it).

## External Design — the event contract
Within one `runStepAuto` batch (`List LoopEvent`):
1. **Ordering jemmet imposes when dispatching a batch:** process `newConnection`
   first (so a same-batch `dataReady` for it has state), then I/O events
   (`dataReady readable`/`writable`/`eof`/`error`), then `tick` last (so timeouts
   are swept against state already advanced this batch). jemmet does not assume
   iotakt orders the list; jemmet sorts/dispatches by this policy.
2. **Stale events dropped at the jemmet edge.** A `dataReady`/`tick` for an
   `FdKey` not in `conns` (closed or never-seen) is dropped with a counter; iotakt
   already filters stale *generations*, and jemmet additionally drops events for
   keys whose `ConnState` it has torn down. Reused raw fd + new generation ⇒ a new
   `FdKey` ⇒ a fresh `ConnState`; old state is keyed by the old generation and was
   removed on close.
3. **One bounded progress step per connection per batch.** A connection is stepped
   at most once per batch event for it; each step does bounded work (read/parse/
   respond/flush up to a configured budget) then yields, so no connection starves
   others and no step loops unbounded. Fairness: every ready connection in a batch
   is serviced once before any is serviced again.
4. **Close / cancel / timeout / pending-output interaction (total):**
   - jemmet-initiated close: drain bounded pending output (graceful) or drop it
     (abortive), then `Conn.close`, then remove `ConnState`, then drop subsequent
     events for the key.
   - henret task cancellation under a connection (iotakt Gap 006 close cancels the
     task): jemmet treats task disappearance as connection death; `ConnState` is
     removed; pending HTTP state is discarded; no further events are processed for
     the key.
   - timeout (`tick`): maps to a close action per the phase (RFC 010 error policy);
     never leaves a half-open `ConnState`.
   - write interest is disabled only when *owned pending output is empty* (RFC 010
     accounting), never merely because one `flush` returned.
5. **No nested `runStepAuto`.** `Conn` instances may perform non-blocking iotakt
   ops on the current connection but MUST NOT call `runStepAuto`; the driver is the
   sole owner of global polling and dispatch (prevents reentrancy/ordering/deadlock
   bugs).
6. **Handler IO does not block the loop.** Per RFC 015's handler-execution policy.

## Proof / Test Obligations
- A deterministic **fake event-trace runner** replays arbitrary henret/iotakt
  sequences: stale events, duplicate/coalesced readiness, timeout/read/write in one
  batch, close-then-reuse raw fd, partial write + re-arm, pipelined remainder,
  handler timeout/cancellation. (This is the M1.5 checkpoint, §Roadmap.)
- Property tests over randomized event interleavings, `wouldBlock`, repeated
  `interrupted`, 0/1/N partial reads/writes, arbitrary tick insertion, close at
  every phase, and bounded fairness across many connections.
- Where feasible, prove: no event is processed for a removed `FdKey`; every batch
  terminates (bounded work); write interest off ⇒ owned output empty.

## Trust / Assumption Changes
Relies on iotakt's confirmed pull/ack/demux/generation model (ASSUMED).

## Acceptance Criteria
The event contract (1)–(6) is specified and implemented; the fake event-trace
runner exists and passes the adversarial-sequence suite (M1.5); the no-stale,
batch-termination, and write-interest invariants hold (proven or model-checked).

## Alternatives Considered
- *Leave event semantics as prose in RFC 007:* rejected — the review's core point
  is that this glue must be a contract, not an implementation note.

## Open Questions
1. Exact per-connection work budget per step (bytes/records) and the fairness
   queue discipline.
2. Whether the runner is shared with `FakeConn` (RFC 002) or a distinct layer above
   it (likely above: it scripts iotakt *events*, `FakeConn` scripts connection
   *bytes*).
