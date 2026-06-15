# RFC 015: Handler execution policy

## Status
Proposed (must be accepted before M2)

## Summary
Defines how `Handler := RequestCtx → IO HttpResponse` executes relative to the
single driver loop, so a slow/blocking/waiting handler cannot stall timeout
sweeping, flushing, acking, TLS progress, other connections, or shutdown. Adopts a
**henret task-handoff** model with a phase-indexed connection state including
`WaitingForHandler`.

## Motivation
The process model is single-process, single-loop, no background threads. If
handlers run inline in the loop, any blocking or long-running handler stalls
everything (review Concern 5). jemmet already owns the henret runtime (via iotakt's
`EventLoop`), so handler work can be handed to a bounded henret task and the
connection resumed when the response is ready — without a thread pool.

## Goals
1. Guarantee that handler execution cannot block the driver loop.
2. Make the connection state machine phase-indexed with an explicit
   handler-waiting phase.
3. Support handler deadlines and cancellation.

## Non-Goals
The application's handler logic; a general async framework; changing iotakt/henret
(must use their confirmed surfaces — see Open Questions).

## External Design
Connection phases (RFC 007 `ConnState` is phase-indexed):
```text
ReadingHead → ReadingBody → Dispatching
  → WaitingForHandler (deadline, handlerTaskId)
  → WritingResponse → (KeepAlive ↺ | Closing) → Closed
```
Policy (recommended): **henret task handoff (with a strict-inline fast path).**
- On `Dispatching`, the driver submits the handler as a bounded henret task and
  moves the connection to `WaitingForHandler` with a deadline; the loop continues
  servicing other connections, flushing, acking, and sweeping timeouts.
- When the handler task completes, its `HttpResponse` is delivered back (via the
  henret mailbox / a completion the driver observes on a later batch); the
  connection moves to `WritingResponse`.
- A handler that exceeds its deadline is cancelled; the connection emits an error
  response (e.g. 503/504 per policy) or closes per RFC 010.
- A *declared* fast/nonblocking handler may run inline as an optimization, but the
  default path is handoff so no handler can stall the loop.
- Bounded concurrency: a cap on in-flight handler tasks; over the cap, new requests
  are queued or shed (RFC 010).

## Proof / Test Obligations
- `ConnState` phase transitions are total (every (phase, event) has a defined
  action; RFC 010 error policy).
- Tests: slow handler does not stall other connections or timeout sweeping; handler
  deadline fires and cancels; response-after-close is unrepresentable (a cancelled/
  closed connection never accepts a late handler response); handler task failure
  maps to a 5xx; in-flight cap sheds correctly.

## Trust / Assumption Changes
Uses the henret task API exposed through iotakt's `EventLoop` (ASSUMED).

## Acceptance Criteria
A handler-execution policy is chosen and implemented (default: task handoff);
`WaitingForHandler` exists with deadline+cancellation; the no-stall and
no-late-response tests pass; the in-flight cap enforces.

## Alternatives Considered
- *Strict inline nonblocking handlers only (option 1):* simplest, but pushes all
  slow work onto the application and gives no deadline/cancellation safety; kept as
  the declared fast path, not the default.
- *OS thread pool:* rejected — violates the single-thread, no-background-thread
  process model; henret tasks are the idiomatic substitute.

## Open Questions
1. **Coordination with iotakt/henret:** confirm the henret task API reachable
   through iotakt's `EventLoop` supports (a) spawning a handler task, (b) observing
   its completion on a later driver batch, and (c) cancelling it on deadline —
   **without** requiring an iotakt change. If a (small, additive) iotakt/henret
   surface is needed, raise it with the iotakt team as a consumer need (mirroring
   how kroopt surfaced its needs); until confirmed, v0.1 may ship the strict-inline
   model (option 1) with deadlines enforced by the loop, and upgrade to handoff
   when the surface is confirmed.
2. Status code for handler timeout (503 vs 504) and for handler failure (500).
