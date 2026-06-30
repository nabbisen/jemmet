/-
  Jemmet.Proofs.HandlerPolicy — handler-execution safety invariants (RFC 015).

  Proven: completion yields a writable response; the deadline fires exactly when elapsed
  and not before; closing a waiting/ready connection cancels it; terminal phases
  (`timedOut`, `cancelled`) absorb every later event — so **a task completing after close
  produces no late response** and a fired deadline cannot be undone; and the in-flight
  task count never exceeds the cap over any sequence of spawns/retires.

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Serve.HandlerPolicy

namespace Jemmet.Proofs
open Jemmet

/-- Task completion makes the response writable. -/
theorem completed_ready (dl t : Nat) (r : HttpResponse) :
    stepHandler (.running dl t) (.completed r) = .ready r := rfl

/-- A handler error becomes a 500 response (never a stuck connection). -/
theorem failed_ready (dl t : Nat) :
    stepHandler (.running dl t) .failed = .ready failResponse := rfl

/-- The deadline fires exactly when elapsed. -/
theorem deadline_fires (dl t now : Nat) (h : now ≥ dl) :
    stepHandler (.running dl t) (.tick now) = .timedOut := by
  simp only [stepHandler, h, if_true]

/-- Before the deadline, the handler keeps waiting (no spurious timeout). -/
theorem before_deadline (dl t now : Nat) (h : now < dl) :
    stepHandler (.running dl t) (.tick now) = .running dl t := by
  simp only [stepHandler]
  rw [if_neg (by omega)]

/-- Closing a waiting connection cancels its task. -/
theorem cancel_on_close (dl t : Nat) :
    stepHandler (.running dl t) .closeConn = .cancelled := rfl

/-- Closing a connection whose response is ready (but unwritten) drops the response. -/
theorem ready_close_drops (r : HttpResponse) :
    stepHandler (.ready r) .closeConn = .cancelled := rfl

/-- `cancelled` absorbs every event. -/
theorem cancelled_absorbs (e : HandlerEvent) : stepHandler .cancelled e = .cancelled := by
  cases e <;> rfl

/-- **No late response after close**: a task that completes after the connection was
    cancelled produces no response — the completion is dropped. -/
theorem no_late_response (r : HttpResponse) :
    stepHandler .cancelled (.completed r) = .cancelled := rfl

/-- A `timedOut` connection absorbs every event (the deadline cannot be undone). -/
theorem timedOut_absorbs (e : HandlerEvent) : stepHandler .timedOut e = .timedOut := by
  cases e <;> rfl

/-- A cancelled connection never writes a response. -/
theorem cancelled_no_write : HandlerPhase.cancelled.writes = false := rfl

/-! ### Bounded in-flight pool -/

/-- One pool op preserves `inFlight ≤ cap` (spawn only adds below the cap; retire never
    grows; cap is unchanged). -/
theorem applyOp_bounded (p : HandlerPool) (op : PoolOp) (h : p.inFlight ≤ p.cap) :
    (p.applyOp op).inFlight ≤ (p.applyOp op).cap := by
  cases op with
  | spawn =>
    unfold HandlerPool.applyOp HandlerPool.spawn HandlerPool.canAdmit
    by_cases hc : p.inFlight < p.cap
    · rw [if_pos (decide_eq_true_eq.mpr hc)]
      show p.inFlight + 1 ≤ p.cap
      omega
    · rw [if_neg (by simp only [decide_eq_true_eq]; exact hc)]
      exact h
  | retire =>
    unfold HandlerPool.applyOp HandlerPool.retire
    show p.inFlight - 1 ≤ p.cap
    omega

/-- **Bounded concurrency (RFC 015)**: over any sequence of spawn/retire operations the
    in-flight task count never exceeds the cap. -/
theorem pool_invariant (ops : List PoolOp) (p0 : HandlerPool) (h0 : p0.inFlight ≤ p0.cap) :
    (ops.foldl HandlerPool.applyOp p0).inFlight ≤ (ops.foldl HandlerPool.applyOp p0).cap := by
  induction ops generalizing p0 with
  | nil => exact h0
  | cons op rest ih => exact ih (p0.applyOp op) (applyOp_bounded p0 op h0)

end Jemmet.Proofs
