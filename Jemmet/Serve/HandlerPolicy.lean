/-
  Jemmet.Serve.HandlerPolicy — handler execution policy (RFC 015).

  A handler must never block the driver loop. The default is **task hand-off**: dispatch
  spawns the handler in a henret task and the connection enters `WaitingForHandler`
  (`running deadline task`); the loop proceeds to other connections and later polls the
  task. A declared **fast path** may run inline. The policy is a small phase machine plus
  a bounded in-flight pool; `Jemmet.Proofs.HandlerPolicy` proves its safety invariants.

  The henret task API (spawn/poll/cancel) is reachable through iotakt in deployment; here
  the phase machine is the pure contract, exercised by a model scheduler (the analog of
  `IotaktLoopOps` for the transport). If the task API is unavailable, v0.1 falls back to
  strict-inline handlers with the same loop-enforced deadline — the `timedOut` transition
  is identical either way.
-/
import Jemmet.Http

namespace Jemmet

abbrev TaskId := Nat

/-- The connection's handler-execution phase (refines the serve phase between dispatch and
    writing). `running` is RFC 015's `WaitingForHandler`. -/
inductive HandlerPhase where
  | running (deadline : Nat) (task : TaskId)   -- task in flight; loop is free meanwhile
  | ready (resp : HttpResponse)                -- task produced a response to write
  | timedOut                                   -- deadline elapsed before completion
  | cancelled                                  -- connection torn down under the task
  deriving Inhabited

/-- Events that advance a waiting handler (task poll results, time, teardown). -/
inductive HandlerEvent where
  | completed (resp : HttpResponse)
  | failed
  | tick (now : Nat)
  | closeConn

/-- A handler whose deadline elapsed: 503 with `Connection: close`. -/
def timeoutResponse : HttpResponse :=
  { status := { code := 503, reason := "Service Unavailable" }, headers := Headers.empty,
    body := .empty, keepAlive := false }

/-- A handler that errored: 500 with `Connection: close`. -/
def failResponse : HttpResponse :=
  { status := { code := 500, reason := "Internal Server Error" }, headers := Headers.empty,
    body := .empty, keepAlive := false }

/-- The handler phase transition. Total by construction; terminal phases (`timedOut`,
    `cancelled`) absorb all further events, so a task that completes *after* the
    connection closed is dropped (no late response after close), and a deadline that fires
    cannot be undone. -/
def stepHandler : HandlerPhase → HandlerEvent → HandlerPhase
  | .running _ _,  .completed r => .ready r
  | .running _ _,  .failed      => .ready failResponse
  | .running dl t, .tick now    => if now ≥ dl then .timedOut else .running dl t
  | .running _ _,  .closeConn   => .cancelled
  | .ready _,      .closeConn   => .cancelled         -- closed before write → drop response
  | .ready r,      _            => .ready r
  | .timedOut,     _            => .timedOut
  | .cancelled,    _            => .cancelled

/-- The response a handler phase should write, if any: a completed handler's own response,
    or a 503 for a deadline timeout. A cancelled or in-flight phase writes nothing (the
    connection closed under the task, or the task is still running). -/
def HandlerPhase.response : HandlerPhase → Option HttpResponse
  | .ready r  => some r
  | .timedOut => some timeoutResponse
  | _         => none

/-- Whether a handler phase still has a response to write. -/
def HandlerPhase.writes (p : HandlerPhase) : Bool := p.response.isSome

/-! ### Bounded in-flight pool (RFC 015 concurrency cap) -/

/-- The handler task pool: in-flight count against a fixed cap. -/
structure HandlerPool where
  inFlight : Nat
  cap      : Nat
  deriving Repr, DecidableEq, Inhabited

/-- Admit a new task only below the cap. -/
def HandlerPool.canAdmit (p : HandlerPool) : Bool := p.inFlight < p.cap

/-- Spawn a task if admitted (else unchanged — caller runs inline or sheds). -/
def HandlerPool.spawn (p : HandlerPool) : HandlerPool :=
  if p.canAdmit then { p with inFlight := p.inFlight + 1 } else p

/-- Retire a completed/cancelled task. -/
def HandlerPool.retire (p : HandlerPool) : HandlerPool :=
  { p with inFlight := p.inFlight - 1 }

/-- A pool operation (for the invariant proof). -/
inductive PoolOp where
  | spawn | retire

def HandlerPool.applyOp (p : HandlerPool) : PoolOp → HandlerPool
  | .spawn  => p.spawn
  | .retire => p.retire

end Jemmet
