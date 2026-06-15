/-
  Jemmet.Proofs.EventSemantics — driver event-semantics invariants (RFC 014).

  The model-checked contract: a `dataReady`/`tick` for an `FdKey` the driver has torn
  down (or never saw) is dropped, never stepped — so a stale readiness event after close,
  or a reused raw fd with a stale generation, cannot drive dead state
  (`stepConn_stale`, `removeConn_find_none`, `no_step_after_remove`). `newConnection`
  makes a key live so a same-batch `dataReady` finds state (`addConn_live`). Write
  interest is armed exactly when owned output is non-empty (`needsWrite_iff`, RFC 010).

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Serve.Event

namespace Jemmet.Proofs
open Jemmet

/-- A torn-down key is not found. -/
theorem removeConn_find_none (key : FdKey) (s : DriverState) :
    (removeConn key s).find? key = none := by
  simp only [removeConn, DriverState.find?]
  apply List.find?_eq_none.mpr
  intro e he
  simp only [List.mem_filter, decide_eq_true_eq] at he
  simp only [decide_eq_true_eq]
  exact he.2

/-- After teardown the key is not live. -/
theorem removeConn_not_live (key : FdKey) (s : DriverState) :
    (removeConn key s).isLive key = false := by
  simp only [DriverState.isLive, removeConn_find_none, Option.isSome_none]

/-- A step on an unknown/torn-down key is dropped (stale counter bumped), never stepped. -/
theorem stepConn_stale (key : FdKey) (kind : IoKind) (s : DriverState) (h : s.find? key = none) :
    stepConn key kind s = { s with droppedStale := s.droppedStale + 1 } := by
  simp only [stepConn, h]

/-- **No event is processed for a removed `FdKey`** (RFC 014 proof obligation): after a
    connection is torn down, any further I/O event for its key is dropped, not stepped. -/
theorem no_step_after_remove (key : FdKey) (kind : IoKind) (s : DriverState) :
    stepConn key kind (removeConn key s) =
      { (removeConn key s) with droppedStale := (removeConn key s).droppedStale + 1 } :=
  stepConn_stale key kind (removeConn key s) (removeConn_find_none key s)

/-- `newConnection` makes the key live (so a same-batch `dataReady` has state). -/
theorem addConn_live (key : FdKey) (s : DriverState) :
    (addConn key s).isLive key = true := by
  unfold addConn
  split
  · rename_i h; exact h
  · simp [DriverState.isLive, DriverState.find?]

/-- **Write-interest invariant** (RFC 010): write interest is armed iff owned output is
    non-empty. -/
theorem needsWrite_iff (e : ConnEntry) : e.needsWrite = true ↔ 0 < e.pendingOut := by
  simp [ConnEntry.needsWrite]

end Jemmet.Proofs
