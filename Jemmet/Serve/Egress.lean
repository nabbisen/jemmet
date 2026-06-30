/-
  Jemmet.Serve.Egress — the egress-boundedness accounting model (RFC 010).

  A slow reader (or a peer that refuses to drain a response) must not force unbounded
  user-space buffering — the egress-slowloris threat. RFC 010 makes this a **mandatory
  v0.1 safety property**: total owned pending output is the three-tier sum
  `jemmetQueued + connOwnedPlaintext + tlsOwnedCiphertext` and is held within a configured
  cap for every live connection. For a plaintext (M2) connection the ciphertext tier is 0
  and the account reduces to the connection's owned output.

  Backpressure is the mechanism: the driver admits new output for a connection only while
  its owned output is strictly below the cap (`egressAdmits`). `Jemmet.Proofs.EgressBound`
  proves that under this discipline owned output stays within `cap + maxStepOutput`
  forever, regardless of how many requests the peer sends.
-/
namespace Jemmet

/-- The three-tier egress account (RFC 010): user-space pending output decomposed into
    jemmet-queued plaintext, connection-owned plaintext, and TLS-owned ciphertext. -/
structure EgressAccount where
  jemmetQueued       : Nat
  connOwnedPlaintext : Nat
  tlsOwnedCiphertext : Nat
  deriving Repr, DecidableEq, Inhabited

/-- Total user-space pending output for a connection. -/
def EgressAccount.total (e : EgressAccount) : Nat :=
  e.jemmetQueued + e.connOwnedPlaintext + e.tlsOwnedCiphertext

/-- The egress bound holds when total owned output is within the cap. -/
def EgressAccount.withinBound (e : EgressAccount) (cap : Nat) : Bool := e.total ≤ cap

/-- The plaintext (M2) account from a connection's owned output (no jemmet queue, no TLS
    ciphertext): the whole owned tier is the connection's `outBuf`. -/
def plaintextAccount (ownedOut : Nat) : EgressAccount :=
  { jemmetQueued := 0, connOwnedPlaintext := ownedOut, tlsOwnedCiphertext := 0 }

/-- Backpressure: admit new output for a connection only while owned output is strictly
    below the cap. When owned ≥ cap, the driver stops reading/producing and only drains. -/
def egressAdmits (cap owned : Nat) : Bool := owned < cap

/-- One step's effect on owned output under backpressure: an admitted step adds the
    step's output; a backpressured step (owned at/over cap) leaves it unchanged (only a
    flush, which never grows it). This is the pure model of `ServeDriver.stepReadable`'s
    egress behaviour. -/
def stepOwned (cap owned added : Nat) : Nat :=
  if egressAdmits cap owned then owned + added else owned

end Jemmet
