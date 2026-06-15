/-
  Jemmet.Serve.Event — the driver event-semantics model (RFC 014).

  Makes jemmet's consumption of the henret→iotakt event model a model-level contract,
  testable by a deterministic fake event-trace runner without real iotakt. Within one
  `runStepAuto` batch the driver imposes an ordering (newConnection → I/O → tick), drops
  events for `FdKey`s it has torn down or never seen (generation-protected: a reused raw
  fd with a new generation is a *different* `FdKey`), steps each connection at most once
  per batch (coalescing/fairness), and sweeps idle timeouts on `tick`. Write interest is
  armed iff owned output is non-empty (RFC 010 accounting).

  The per-connection HTTP work (RFC 007) is abstracted here to its event-visible effects
  (`stepCount`, owned `pendingOut`); this layer scripts iotakt *events*, while `FakeConn`
  scripts connection *bytes*. Invariants are proven in `Jemmet.Proofs.EventSemantics`.
-/
import Jemmet.Conn.Conn

namespace Jemmet

/-- The kind of an I/O readiness event. -/
inductive IoKind where
  | readable | writable | eof | error
  deriving Repr, DecidableEq, BEq, Inhabited

/-- One event in a `runStepAuto` batch (the henret/iotakt loop's output). -/
inductive LoopEvent where
  | newConnection (key : FdKey)
  | dataReady (key : FdKey) (kind : IoKind)
  | tick (now : Nat)
  deriving Repr, Inhabited

/-- Driver-visible per-connection state (the HTTP state of RFC 007 is abstracted to its
    event-visible effects). -/
structure ConnEntry where
  key        : FdKey
  pendingOut : Nat        -- owned output bytes (RFC 010 egress accounting)
  stepCount  : Nat        -- bounded steps taken (fairness observability)
  lastActive : Nat        -- modeled time of last progress (idle-timeout basis)
  deriving Repr, Inhabited

/-- Write interest is armed exactly when owned output is non-empty (RFC 010). -/
def ConnEntry.needsWrite (e : ConnEntry) : Bool := e.pendingOut > 0

structure DriverConfig where
  idleTimeout : Nat := 30
  deriving Inhabited

/-- The driver's whole-loop state: live connections keyed by `FdKey`, a stale-event
    counter, the torn-down keys (audit), and modeled time. -/
structure DriverState where
  now          : Nat
  conns        : List ConnEntry
  droppedStale : Nat
  closedKeys   : List FdKey
  deriving Inhabited

namespace DriverState

def init : DriverState := { now := 0, conns := [], droppedStale := 0, closedKeys := [] }

/-- Find a connection by *full* `FdKey` (raw **and** generation). -/
def find? (s : DriverState) (key : FdKey) : Option ConnEntry :=
  s.conns.find? (fun e => decide (e.key = key))

def isLive (s : DriverState) (key : FdKey) : Bool := (s.find? key).isSome

end DriverState

/-- Tear down a connection: remove its state and record the key (so later events for it
    are dropped as stale). -/
def removeConn (key : FdKey) (s : DriverState) : DriverState :=
  { s with conns := s.conns.filter (fun e => decide (e.key ≠ key)),
           closedKeys := key :: s.closedKeys }

/-- `newConnection`: add a fresh entry if the key isn't already live. -/
def addConn (key : FdKey) (s : DriverState) : DriverState :=
  if s.isLive key then s
  else { s with conns := { key, pendingOut := 0, stepCount := 0, lastActive := s.now } :: s.conns }

/-- One bounded progress step on a *live* connection; an event for a torn-down/unknown
    key is dropped (counter++), never stepped. `eof`/`error` tear the connection down. -/
def stepConn (key : FdKey) (kind : IoKind) (s : DriverState) : DriverState :=
  match s.find? key with
  | none   => { s with droppedStale := s.droppedStale + 1 }
  | some e =>
    let bump (e' : ConnEntry) : DriverState :=
      { s with conns := s.conns.map (fun x => if x.key = key then e' else x) }
    match kind with
    | .readable =>
      bump { e with stepCount := e.stepCount + 1, pendingOut := e.pendingOut + 1, lastActive := s.now }
    | .writable =>
      bump { e with stepCount := e.stepCount + 1, pendingOut := e.pendingOut - 1, lastActive := s.now }
    | .eof | .error => removeConn key s

/-- Sweep idle connections closed on a `tick` (timeout → close, never a half-open
    state). -/
def sweepTimeouts (cfg : DriverConfig) (now : Nat) (s : DriverState) : DriverState :=
  let s := { s with now := now }
  let live := s.conns.filter (fun e => now < e.lastActive + cfg.idleTimeout)
  let dead := s.conns.filter (fun e => !(now < e.lastActive + cfg.idleTimeout))
  { s with conns := live, closedKeys := dead.map (·.key) ++ s.closedKeys }

/-! ### Batch dispatch (the ordering + coalescing contract) -/

def LoopEvent.isNew  : LoopEvent → Bool | .newConnection _ => true | _ => false
def LoopEvent.isIo   : LoopEvent → Bool | .dataReady _ _    => true | _ => false
def LoopEvent.isTick : LoopEvent → Bool | .tick _           => true | _ => false

/-- Process one I/O event, stepping each key at most once per batch (readiness
    coalescing / fairness): a key already stepped this batch is skipped. -/
def processIo (ev : LoopEvent) (acc : List FdKey × DriverState) : List FdKey × DriverState :=
  match ev with
  | .dataReady key kind =>
    if acc.1.contains key then acc
    else (key :: acc.1, stepConn key kind acc.2)
  | _ => acc

/-- Dispatch one `runStepAuto` batch under the ordering contract: all `newConnection`
    first (so a same-batch `dataReady` has state), then I/O (coalesced, one step per
    key), then `tick` last (timeouts swept against state already advanced this batch). -/
def dispatchBatch (cfg : DriverConfig) (batch : List LoopEvent) (s : DriverState) : DriverState :=
  let s1 := (batch.filter LoopEvent.isNew).foldl
              (fun st ev => match ev with | .newConnection k => addConn k st | _ => st) s
  let s2 := ((batch.filter LoopEvent.isIo).foldl (fun acc ev => processIo ev acc) ([], s1)).2
  let s3 := (batch.filter LoopEvent.isTick).foldl
              (fun st ev => match ev with | .tick now => sweepTimeouts cfg now st | _ => st) s2
  s3

/-- The deterministic fake event-trace runner: fold the driver over a scripted sequence
    of batches. Pure and total — the substance of the M1.5 checkpoint. -/
def runTrace (cfg : DriverConfig) (trace : List (List LoopEvent)) (s : DriverState) : DriverState :=
  trace.foldl (fun st batch => dispatchBatch cfg batch st) s

end Jemmet
