/-
  Jemmet.Conn.Conn — the connection abstraction (keystone).

  Implements RFC 002 (`rfcs/done/002-connection-abstraction.md`):
  one byte-level interface, plaintext both directions, that PlainIotaktConn (M2),
  TlsConn (M3) and FakeConn (M1) all implement, so the HTTP code path is identical
  for plaintext and TLS. Every operation returns a `ConnProgress` so the driver
  (RFC 007/014) arms the right iotakt interests and bounds owned memory from fact,
  not inference. Instances MUST NOT nest the driver loop (no `runStepAuto`).

  This module is pure data + the typeclass: no IO effects of its own beyond the
  `IO`-shaped method types required for the heavy (TLS) instance. No external
  dependencies (the proven/trusted core stays minimal — RFC 011).
-/

namespace Jemmet

/--
A connection identity key.

RFC 002 types this as `Iotakt.Model.FdKey`. iotakt is an ASSUMED dependency that is
not vendored until M2 (RFC 008), so the keystone defines a structural stand-in with
the same shape iotakt uses — a raw fd plus a generation counter — that the iotakt
binding (RFC 008) refines to the real type. jemmet only ever uses this for
demultiplexing and logging; it never touches the raw fd directly.
-/
structure FdKey where
  raw : Int
  gen : Nat
  deriving Repr, DecidableEq, BEq, Inhabited, Hashable

/-- A peer address (for logging/metadata only). -/
structure PeerAddr where
  host : String
  port : UInt16
  deriving Repr, DecidableEq, BEq, Inhabited

/--
Connection metadata surfaced to the driver and (a redacted subset of) handlers.
`secure`/`alpn` are populated by the TLS instance (RFC 009); for plaintext,
`secure = false` and `alpn = none`.
-/
structure ConnMetadata where
  fd     : FdKey
  secure : Bool
  alpn   : Option String
  peer   : Option PeerAddr
  deriving Repr, DecidableEq, BEq, Inhabited

/--
The unified connection-error view. iotakt `IoErrno`, kroopt `TransportError` / TLS
alerts, and peer-EOF all collapse into this so jemmet handles "the connection died"
identically regardless of layer (Requirements §2.2.4).

`truncated` (EOF/close before a complete unit — e.g. mid-request, or peer-EOF before
a TLS `close_notify`) is deliberately distinct from a clean `peerClosed`.
-/
inductive ConnError where
  /-- Clean EOF: the peer closed cleanly at a unit boundary. -/
  | peerClosed
  /-- EOF/close before a complete unit (mid-request; pre-`close_notify`). -/
  | truncated
  /-- Transport reset (iotakt) or fatal TLS alert (kroopt). -/
  | reset
  /-- Other transport failure; `detail` is already redacted. -/
  | transport (detail : String)
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Where a connection sits in its teardown lifecycle. -/
inductive CloseState where
  /-- Live; reads/writes permitted. (`open` is a Lean keyword, hence the escaping;
      the constructor is `CloseState.open`, the RFC 002 name.) -/
  | «open»
  /-- Graceful close requested; draining owned output, no new requests read. -/
  | closing
  /-- Fully closed; quiescent and terminal. -/
  | closed
  /-- Abortive teardown in progress (heavy instances may need a flush to finish). -/
  | aborting
  deriving Repr, DecidableEq, BEq, Inhabited

/--
Returned by every `Conn` operation. This is the v1→v2 hardening from the senior
review: the driver must *see* what changed and what is owned, because TLS can read
while HTTP thinks it is writing, write handshake bytes before any request exists,
make transport progress without yet producing plaintext, and own ciphertext buffers
invisible to jemmet.

* `progressMade`  — did the transport advance at all this op?
* `needsRead`     — arm iotakt read interest.
* `needsWrite`    — arm iotakt write interest.
* `ownedInBytes`  — inbound bytes buffered by the connection, not yet delivered as
                    plaintext (feeds the ingress bound, RFC 010).
* `ownedOutBytes` — plaintext + (for TLS) ciphertext owned by the connection, not yet
                    on the socket (feeds the egress bound, RFC 010).
* `closeState`    — drives teardown.
-/
structure ConnProgress where
  progressMade  : Bool
  needsRead     : Bool
  needsWrite    : Bool
  ownedInBytes  : Nat
  ownedOutBytes : Nat
  closeState    : CloseState
  deriving Repr, DecidableEq, BEq, Inhabited

/--
A driver-facing consistency predicate over `ConnProgress`, encoding two invariants
the driver and the egress accounting (RFC 010 / RFC 014 §4) rely on:

* **write-interest accounting** — `needsWrite` is armed iff there is owned output to
  push: `needsWrite ↔ ownedOutBytes > 0`. (Write interest is disabled only when owned
  pending output is empty, never merely because one `flush` returned.)
* **closed is quiescent** — a `closed` connection arms no interests and owns nothing.

Instances are expected to return only consistent progress; the RFC 002 conformance
suite asserts this after every operation (a TESTED obligation), and `FakeConn`
satisfies it by construction.
-/
def ConnProgress.consistent (p : ConnProgress) : Bool :=
  (p.needsWrite == decide (p.ownedOutBytes > 0)) &&
  (match p.closeState with
   | .closed => !p.needsRead && !p.needsWrite && p.ownedOutBytes == 0 && p.ownedInBytes == 0
   | _       => true)

/-- Outcome of `recv`: plaintext bytes, no-data-yet, clean EOF, or an error. -/
inductive RecvOutcome where
  | bytes (b : ByteArray)
  | wouldBlock
  | eof
  | error (e : ConnError)
  deriving Inhabited

/--
Outcome of `send`. `consumed n` means the connection has taken ownership of `n`
**plaintext** bytes (not socket bytes) and will encrypt-and-flush or fail; the caller
retries the unconsumed plaintext suffix. `wouldBlock` means zero consumed. This
mirrors kroopt's `TlsConn` write contract exactly, so `PlainIotaktConn` implements it
trivially.
-/
inductive SendOutcome where
  | consumed (n : Nat)
  | wouldBlock
  | error (e : ConnError)
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Outcome of `flush`: fully drained, partially drained, blocked, or errored. -/
inductive FlushOutcome where
  | flushed
  /-- Partially drained; owned output remains. (`partial` is a Lean keyword.) -/
  | «partial»
  | wouldBlock
  | error (e : ConnError)
  deriving Repr, DecidableEq, BEq, Inhabited

/-- How to close: drain owned output first (`graceful`) or drop it (`abortive`). -/
inductive CloseMode where
  | graceful
  | abortive
  deriving Repr, DecidableEq, BEq, Inhabited

/--
The connection abstraction. One interface; three instances (`PlainIotaktConn`,
`TlsConn`, `FakeConn`).

The state `κ` is threaded functionally (each op returns the updated connection),
which is what makes `FakeConn` replay deterministic. Methods are `IO` because the
heavy (TLS) instance drives kroopt's progress — decrypt/encrypt plus iotakt I/O —
inside them; the plaintext instance is then a thin wrapper.

Contracts (enforced by instances; checked by the conformance suite):
* `recv` yields plaintext bytes regardless of transport; `send`/`flush` accept
  plaintext and the instance handles framing/encryption/socket.
* every op returns a `ConnProgress` that the driver uses to arm interests and bound
  memory — never inferred.
* instances may do non-blocking iotakt ops on *their own* fd but MUST NOT call
  `runStepAuto`; the driver alone owns global polling (RFC 014 §5).
-/
class Conn (κ : Type) where
  metadata : κ → ConnMetadata
  recv     : κ → Nat       → IO (RecvOutcome  × ConnProgress × κ)
  send     : κ → ByteArray → IO (SendOutcome  × ConnProgress × κ)
  flush    : κ             → IO (FlushOutcome × ConnProgress × κ)
  close    : κ → CloseMode → IO (ConnProgress × κ)

end Jemmet
