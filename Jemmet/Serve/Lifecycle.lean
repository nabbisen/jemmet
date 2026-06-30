/-
  Jemmet.Serve.Lifecycle — server production lifecycle (RFC 016).

  The graceful-shutdown state machine and the resource-leak audit, as a transport-independent
  verified model (the analog of `Serve.Event` / `Serve.HandlerPolicy`). The driver consults
  the phase predicates (`acceptsNew`, `admitsKeepAlive`) at its accept and keep-alive gates;
  the proofs (`Proofs/Lifecycle`) establish the shutdown guarantees:

  * once shutdown begins, no new connection is accepted and no reused connection starts a new
    request (the live set never grows);
  * the drain is *bounded* — past the deadline the remainder is force-closed and the server
    reaches `stopped` with no live connections (no leak);
  * `stopped` is absorbing.
-/
import Jemmet.Conn.Conn

namespace Jemmet

/-- Server lifecycle phase. -/
inductive LifecyclePhase where
  | running                     -- accepting new connections normally
  | draining (deadline : Nat)   -- shutdown requested: no new accepts; finish in-flight; force-close at `deadline`
  | stopped                     -- fully shut down
  deriving Repr, DecidableEq, BEq, Inhabited

namespace LifecyclePhase

/-- A new connection is accepted only while running. -/
def acceptsNew : LifecyclePhase → Bool
  | .running => true
  | _        => false

/-- A reused (keep-alive) connection reads another request only while running; during a drain
    each connection completes its current request and then closes — no new request is started
    on a reused connection, so the drain actually makes progress toward zero. -/
def admitsKeepAlive : LifecyclePhase → Bool
  | .running => true
  | _        => false

end LifecyclePhase

/-- Server lifecycle state: the phase, the live connection keys (the connection table's
    domain), and the owned-output / in-flight accounting that the leak audit checks. -/
structure ServerState where
  phase    : LifecyclePhase := .running
  live     : List FdKey      := []
  ownedOut : Nat             := 0
  inFlight : Nat             := 0
  deriving Repr, Inhabited

/-- Lifecycle events: a connection arrives or finishes, shutdown is requested (with a drain
    deadline), or the clock advances. -/
inductive LifecycleEvent where
  | accept    (key : FdKey)
  | closeConn (key : FdKey)
  | shutdown  (deadline : Nat)
  | tick      (now : Nat)
  deriving Repr

@[inline] def keyEq (a b : FdKey) : Bool := decide (a = b)

/-- One lifecycle transition. Total by construction. -/
def stepLifecycle (s : ServerState) : LifecycleEvent → ServerState
  | .accept key =>
      if s.phase.acceptsNew then { s with live := key :: s.live } else s
  | .closeConn key =>
      { s with live := s.live.filter (fun k => ! keyEq k key) }
  | .shutdown dl =>
      match s.phase with
      | .running => { s with phase := .draining dl }
      | _        => s                                   -- idempotent: a second signal changes nothing
  | .tick now =>
      match s.phase with
      | .draining dl =>
          if s.live.isEmpty then { s with phase := .stopped }            -- drained cleanly
          else if dl ≤ now then { s with phase := .stopped, live := [] }  -- bounded: force-close remainder
          else s
      | _ => s

/-! ### Resource-leak audit -/

/-- The resources tracked for a server: connections, owned output bytes, in-flight handler
    tasks. After a clean stop all three must be zero. -/
structure LeakReport where
  liveConns : Nat
  ownedOut  : Nat
  inFlight  : Nat
  deriving Repr, DecidableEq, BEq, Inhabited

def ServerState.audit (s : ServerState) : LeakReport :=
  { liveConns := s.live.length, ownedOut := s.ownedOut, inFlight := s.inFlight }

/-- No resource is left dangling. -/
def LeakReport.clean (r : LeakReport) : Bool :=
  r.liveConns == 0 && r.ownedOut == 0 && r.inFlight == 0

/-- A leak: some tracked resource was not released. -/
def ServerState.leaked (s : ServerState) : Bool := ! s.audit.clean

end Jemmet
