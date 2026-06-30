# RFC 010: Errors, limits, timeouts, and write-backpressure

## Status
Implemented (M2 — limits/timeouts/backpressure/error-policy for the plaintext edge; egress proven. Deferred: the TLS ciphertext egress tier → RFC 009)

## Summary
The deterministic malformed-input→status mapping, the resource-limit matrix, read
timeouts, and — now **mandatory, not optional** — a **user-space egress
boundedness invariant** with three-tier accounting, plus a phase-indexed total
error policy. Promoted earlier because backpressure and timeouts shape `Conn`,
`ConnState`, and response streaming.

## Motivation
Availability is an explicit asset. The review shows `maxPendingOut` cannot be
enforced only at jemmet's response queue: bytes accumulate in (1) jemmet's
serialized output, (2) plaintext accepted by `Conn` but not flushed, and (3)
kroopt-owned ciphertext — all user-space. A large response, many slow clients, or
TLS expansion under partial writes can otherwise bypass the bound.

## Goals
1. Deterministic malformed-input→status mapping (total).
2. Safe-by-default, configurable limit matrix.
3. Read timeouts (header/body/idle) **and** write-side backpressure + slow-client
   write timeout.
4. A **mandatory** user-space egress boundedness invariant across the three tiers.
5. A phase-indexed total error policy `(phase, error) → action`.

## Non-Goals
Volumetric/network DoS; compression bombs (compression out of scope v0.1).

## External Design
```lean
structure Limits where
  maxRequestLine := 8192    -- → 414/400
  maxHeaderCount := 100     -- → 431
  maxHeaderBytes := 16384   -- → 431
  maxBodyBytes   := 1048576 -- → 413 (iotakt tooLarge)
  maxChunkBytes  := 65536   -- → 400
  maxConnections := 1024    -- iotakt connection cap (load-shed)
  maxUserSpacePendingOut := 262144   -- the egress bound (all three tiers)
  maxInFlightHandlers := 256          -- RFC 015 handoff cap
structure Timeouts where header := 10000 ; body := 30000 ; idle := 60000 ; write := 30000  -- ms
```
**Egress accounting invariant (mandatory v0.1 safety property):**
```text
for every live connection:
  jemmetQueuedPlaintext + connOwnedPlaintext + tlsOwnedCiphertext
      <= maxUserSpacePendingOut
```
(`tlsOwnedCiphertext = 0` for plaintext; for TLS it comes from kroopt via
`ConnProgress.ownedOutBytes`, RFC 009.) When the bound would be exceeded, jemmet
stops producing output for that connection until `flush` drains it; the write timer
guards a peer that never drains. **Responses are not fully serialized before
backpressure applies** — large/generated bodies use the chunked/streaming
`ResponseBody` (RFC 005), produced under the bound (resolves RFC 005's streaming
open question before M2).
**Phase-indexed error policy** (total): `(ConnState.phase, ConnError|FramingError|
timeout) → action ∈ {sendStatusAndClose, closeGracefully, closeAbortively,
dropStaleEvent, logAndContinue}`. Status mapping: malformed line/headers → 400;
oversize line/URI → 414; too many/large headers → 431; oversize body → 413;
unsupported version → 505; framing conflict → 400; handler timeout/failure → 504/500
(RFC 015).

## Proof Obligations
**`EgressBounded` (required):** the three-tier sum never exceeds
`maxUserSpacePendingOut` for any live connection (proven over `ConnState`, or
model-checked + property-stress-tested if full proof is too heavy). Ingress is
similarly bounded: `inputBuffer ≤ maxRequestLine + maxHeaderBytes + maxBodyBytes +
framing overhead`. The error policy is total.

## Test Obligations
Each limit triggers its status; header/body/idle/write timeouts fire; slow reader
bounded + timed out; slow writer (drip) timed out; a large-response handler stays
within the egress bound; the error policy table exercised at every phase.

## Trust / Assumption Changes
Uses iotakt connection cap + idle handling; the TLS tier depends on kroopt's
owned-ciphertext accounting (RFC 009 coordination).

## Acceptance Criteria
Limit matrix + status mapping + phase error policy implemented (safe defaults);
**`EgressBounded` proven or model-checked**; all timeouts enforce; streaming
responses stay within the bound.

## Alternatives Considered
- *Optional boundedness (v1):* rejected per review — for an edge, availability
  boundedness is a required safety property.
- *Bound only jemmet's queue:* rejected — misses `Conn`-owned and TLS-owned bytes.

## Open Questions
1. Per-route vs global limits (start global).
2. Units once h2 arrives (bytes vs records).
