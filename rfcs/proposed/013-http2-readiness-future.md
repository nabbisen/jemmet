# RFC 013: HTTP/2 readiness and future protocols

## Status
Proposed (forward-looking; no v0.1 obligations beyond "do not foreclose")

## Summary
Records what v0.1 must avoid foreclosing so HTTP/2 (and other future protocols) can
be added later without reshaping the `Conn` abstraction or the serve loop, plus the
forward parking lot.

## Motivation
h2 changes the connection model (multiplexed streams over one connection) but
shares everything below HTTP semantics. As iotakt stayed kqueue-aware before
shipping kqueue, jemmet should stay h2-aware before shipping h1 — cheaply, by not
baking in single-request-per-connection assumptions.

## Goals
1. State the non-foreclosure constraints for h2.
2. Identify the ALPN selection hook.
3. Hold the forward parking lot (compression, client mode).

## Non-Goals
Implementing h2/h3/WebSocket/compression/client mode in v0.1.

## External Design (constraints, not implementation)
1. `Conn` (RFC 002) is byte-level and protocol-agnostic — already h2-compatible
   (h2 is framing above the byte stream).
2. `ConnState`/serve loop (RFC 007) must be structured so a stream-multiplexed
   state can replace the single-request state **without** reshaping the loop or
   `Conn`. Avoid hard-coding "one request at a time per connection" in shared code.
3. ALPN is the selection hook: `Conn.metadata.alpn = "h2"` (negotiated by kroopt)
   selects an h2 connection handler; `"http/1.1"` or none selects the h1 path.
4. Parking lot: content compression (with mandatory decompression-bomb output
   limits), outbound/client mode, performance work — each a future RFC, none a v0.1
   blocker.

## Proof / Test Obligations
None in v0.1; future h2 work carries its own framing/flow-control obligations.

## Trust / Assumption Changes
None.

## Acceptance Criteria
v0.1 design reviewed against constraints (1)–(3); no v0.1 decision forecloses h2;
the parking lot is recorded.

## Alternatives Considered
- *Ignore h2 entirely until needed:* risky — some structural choices (single-request
  state in shared code) are expensive to undo later; cheap to avoid now.

## Open Questions
1. Whether h2 becomes a sibling module or an alternate serve loop sharing `Conn`.
