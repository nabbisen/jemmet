# RFC 009: TlsConn (kroopt binding) — gated

## Status
Proposed (revised per senior review v1→v2; gated on kroopt)

## Summary
The `Conn` instance over kroopt: `recv`/`send`/`flush` drive kroopt progress and
return `ConnProgress` (incl. kroopt-owned ciphertext in `ownedOutBytes`);
`metadata` surfaces ALPN/`secure`. Gated until kroopt's `IotaktTransport` is
validated over real iotakt, **and** the M3 gate now requires a TLS **progress
matrix**, not just happy-path HTTPS.

## Motivation
HTTPS is jemmet's reason to be the edge. RFC 002's `ConnProgress` makes TLS's
non-obvious progress (read-while-writing, progress-without-plaintext, owned
ciphertext) visible to the driver. The review requires the gate to exercise the
real TLS progress and backpressure paths, where subtle failures live.

## Goals
1. Implement `Conn` over kroopt, returning `ConnProgress`.
2. Surface owned ciphertext in `ownedOutBytes` for the egress bound (RFC 010).
3. Surface ALPN/`secure` in `metadata`.
4. Route close through kroopt (`close_notify`) then iotakt.

## Non-Goals
TLS logic (kroopt's); changing kroopt/iotakt beyond a coordinated additive
accounting hook; same-port sniffing (separate TLS listeners, v0.1).

## External Design
`recv`/`send`/`flush` drive kroopt and return `ConnProgress` reflecting kroopt's
need-read/need-write and owned buffers; the HTTP path above is byte-identical to
plaintext. Close: kroopt seals `close_notify`, flush, then iotakt
`closeConnection`.

**Coordination with kroopt (named honestly):** the egress bound (RFC 010) needs
`ownedOutBytes` to include kroopt's pending ciphertext, so kroopt must expose its
owned-buffer byte count (and read/write-need) through its `TlsConn` surface. This
is a (small, additive) consumer need on kroopt — raise it with the kroopt team the
way kroopt raised its needs to iotakt. If unavailable, the TLS egress bound is
*testable* but not *checkable* until exposed.

## Proof / Test Obligations
None new (passes RFC 002 conformance incl. `ConnProgress`). **M3 TLS progress
matrix (required for the gate):**
- handshake needs write before read; needs read before write;
- application write blocked by TLS ciphertext backlog (egress backpressure);
- peer sends `close_notify` mid-request;
- TCP EOF without `close_notify` (⇒ `truncated`, a failure);
- ALPN missing / `http/1.1` / (future) `h2`;
- slow TLS client that completes handshake but does not drain the response
  (write timeout fires);
- graceful shutdown with pending `close_notify`.
Plus HTTPS E2E (curl/browser) and byte-identity with the M2 HTTP path.

## Trust / Assumption Changes
Adds kroopt as ASSUMED; adds the `ownedOutBytes` accounting hook as a coordinated
kroopt need.

## Acceptance Criteria
**Gate:** kroopt `IotaktTransport` validated over real iotakt **and** the TLS
progress matrix passes. Then: `TlsConn` passes conformance; HTTPS E2E succeeds;
egress accounting includes kroopt ciphertext; plaintext+TLS listeners coexist.

## Alternatives Considered
- *Happy-path HTTPS as the only gate (v1):* rejected per review — the progress and
  backpressure paths are where TLS integration fails subtly.
- *Same-port sniffing:* deferred — separate listeners keep the security context
  unambiguous.

## Open Questions
1. Exact kroopt `TlsConn`/`ServerConfig` surface and the owned-bytes accounting
   hook (coordinate with kroopt).
2. h2 ALPN selection (RFC 013).
