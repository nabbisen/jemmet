# RFC 002: The connection abstraction (keystone)

## Status
Implemented (M1 — Conn keystone + FakeConn; determinism proof + conformance)

## Summary
Defines the `Conn` interface — `recv`/`send`/`flush`/`close`/`metadata` — that all
transports implement, **plus an explicit `ConnProgress`/interest-delta result** so
the driver always knows what a connection needs and owns, and a **no-nested-
runStepAuto** rule. One HTTP code path for plaintext and TLS.

## Motivation
The keystone: get it right and "TLS vs plaintext" is a wiring choice. The v1
interface hid too much progress logic behind `recv/send/flush` (review Concern 2):
TLS may read while HTTP thinks it is writing, write handshake bytes before any
request exists, produce no plaintext yet still make transport progress, and own
ciphertext buffers invisible to jemmet. The driver must see *what changed* and
*what is owned*, and must remain the sole owner of polling.

## Goals
1. One interface, byte-level, plaintext both directions.
2. `send` semantics in **plaintext bytes consumed**, with explicit `flush`.
3. Effect model (`IO`) shaped for the **heavy** (TLS) instance.
4. Unified error/close model across iotakt, kroopt, EOF.
5. **Every operation returns a `ConnProgress`** so the driver can arm the right
   interests and account for owned memory.
6. Instances MUST NOT nest the driver loop.
7. Three instances: `PlainIotaktConn`, `TlsConn`, `FakeConn`.

## Non-Goals
HTTP semantics; TLS/I/O specifics inside instances; exposing iotakt/kroopt types to
handlers.

## External Design
```lean
structure ConnMetadata where
  fd : Iotakt.Model.FdKey ; secure : Bool ; alpn : Option String ; peer : Option PeerAddr

inductive ConnError | peerClosed | truncated | reset | transport (detail : String)
inductive CloseState | open | closing | closed | aborting

structure ConnProgress where        -- returned by every Conn op
  progressMade  : Bool              -- did the transport advance at all?
  needsRead     : Bool              -- arm iotakt read interest
  needsWrite    : Bool              -- arm iotakt write interest
  ownedInBytes  : Nat               -- buffered inbound not yet delivered as plaintext
  ownedOutBytes : Nat               -- plaintext+ciphertext owned, not yet on the socket
  closeState    : CloseState

inductive RecvOutcome  | bytes (b : ByteArray) | wouldBlock | eof | error (e : ConnError)
inductive SendOutcome  | consumed (n : Nat)    | wouldBlock | error (e : ConnError)
inductive FlushOutcome | flushed | partial | wouldBlock | error (e : ConnError)
inductive CloseMode    | graceful | abortive

class Conn (κ : Type) where
  metadata : κ → ConnMetadata
  recv     : κ → Nat       → IO (RecvOutcome  × ConnProgress × κ)
  send     : κ → ByteArray → IO (SendOutcome  × ConnProgress × κ)
  flush    : κ            → IO (FlushOutcome × ConnProgress × κ)
  close    : κ → CloseMode → IO (ConnProgress × κ)
```
Contracts:
- **`ConnProgress` drives the loop.** The driver arms iotakt read/write interest
  from `needsRead`/`needsWrite` (not from guessing); `ownedOutBytes`/`ownedInBytes`
  feed the egress/ingress accounting bound (RFC 010); `closeState` drives teardown.
  This makes TLS's "read-while-writing", "progress-without-plaintext", and owned
  ciphertext visible.
- **`recv`/`send`/`flush`** as in v1 (plaintext bytes; `consumed n` = plaintext
  owned; `wouldBlock` = zero), now each also returning `ConnProgress`.
- **No nested driver.** Instances may do non-blocking iotakt ops on *their* fd but
  MUST NOT call `runStepAuto`; the driver alone owns global polling (RFC 014 §5).
- **Unified errors/close** as v1.

### Instances
`PlainIotaktConn` (thin; `ownedOutBytes` = unflushed suffix; RFC 008);
`TlsConn` (heavy; drives kroopt; `ownedOutBytes` includes kroopt-owned ciphertext —
requires kroopt to expose owned-buffer accounting, RFC 009 / coordination with the
kroopt team); `FakeConn` (deterministic; scripted bytes + write schedule + scripted
`ConnProgress`).

## Proof Obligations
`FakeConn` determinism. (Boundedness uses `ownedOutBytes` in RFC 010/011.)

## Test Obligations
The `Conn` conformance suite, now asserting `ConnProgress` correctness
(needsRead/needsWrite/owned counts/closeState) across wouldBlock, partial send,
graceful/abortive close, and error mapping; run against all three instances.

## Trust / Assumption Changes
None beyond RFC 001; the TLS `ownedOutBytes` accounting is a (small, additive)
need on kroopt to be coordinated (RFC 009).

## Acceptance Criteria
Interface incl. `ConnProgress` accepted; no-nested-runStepAuto rule stated;
`FakeConn` deterministic with scripted progress; conformance suite covers progress.

## Alternatives Considered
- *Hide all progress behind recv/send/flush (v1):* rejected per review — the driver
  cannot arm interests or bound memory without it.
- *Separate plaintext/TLS paths:* rejected — duplicates HTTP logic.

## Open Questions
1. Typeclass vs structure-of-closures.
2. Whether `ConnProgress` is returned or queried separately (returned: atomic with
   the op).
