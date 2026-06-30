# RFC 016: Production lifecycle — shutdown, leak detection, observability, failure modes

## Status
Implemented (M4 scope for the plaintext edge — graceful shutdown + leak audit proven; failure-modes doc. Deferred: TLS re-validation at 0.6.0)

## Summary
Defines the operational lifecycle gates a v0.1 edge server must meet: graceful
shutdown, resource-leak detection, redacted observability, the compatibility
matrix, and documented failure modes.

## Motivation
The review notes these are production gates, not nice-to-haves, for an
internet-facing server whose stated asset includes availability. Graceful
restart/shutdown matters far more than hot-swapping (which stays out of scope).

## Goals
1. Graceful shutdown with a bounded drain.
2. Resource-leak detection in tests.
3. Redacted, useful observability.
4. A published compatibility matrix and documented failure modes.

## Non-Goals
Hot code swapping (out of scope v0.1); metrics-backend integration; clustering.

## External Design
- **Graceful shutdown:** stop accepting (deregister listeners), stop reading new
  requests, drain *bounded* pending responses, close idle connections, cancel
  in-flight handler tasks past a deadline, abort the remainder, then `EventLoop`
  shutdown/destroy. Uses iotakt's graceful-shutdown + connection-cap facilities.
- **Leak detection (tests):** after close/shutdown, assert no live `ConnState`, no
  stale `FdKey` map entries, no pending timers, no orphaned handler tasks, and that
  owned pending-output accounting returns to zero.
- **Observability:** counters for accepts, rejects (per reason: 400/413/431/…),
  timeouts (per phase), backpressure events, handler timeouts/failures, and active
  connections; logs are **redacted** — no secrets, no full attacker-controlled
  blobs (truncate/escape), SNI/cert failures logged without sensitive material.
- **Compatibility matrix:** `docs/compatibility.md` records the validated
  jemmet/iotakt/kroopt triple **and the exact tested Linux backend** (kernel/epoll
  assumptions).
- **Failure-mode documentation:** what happens under load shedding, per-phase
  timeout, TLS failure, and handler failure — each a defined, tested outcome.

## Proof / Test Obligations
- Graceful-shutdown test: in-flight requests drain within deadline; new accepts
  refused; abort after deadline.
- Leak-detection assertions in the close/shutdown test suite.
- Observability: counters increment correctly; a redaction test asserts no
  secret/blob leakage in logs.

## Trust / Assumption Changes
Uses iotakt graceful-shutdown / connection-cap (ASSUMED).

## Acceptance Criteria
Graceful shutdown implemented and tested; leak assertions pass; counters +
redaction verified; compatibility matrix and failure-mode docs published.

## Alternatives Considered
- *Hard stop only:* rejected — drops in-flight requests; graceful drain is
  required for an edge.
- *Hot-swap in v0.1:* deferred — no concrete deployment need; graceful restart is
  the priority.

## Open Questions
1. Default shutdown drain deadline.
2. Whether counters are exposed via a control endpoint or only logged in v0.1.
