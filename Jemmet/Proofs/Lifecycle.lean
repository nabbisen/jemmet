/-
  Jemmet.Proofs.Lifecycle — the production-lifecycle guarantees (RFC 016).

  Graceful shutdown is sound and bounded: once shutdown begins the live set never grows
  (no new accepts, no new keep-alive requests), the drain terminates by the deadline
  (force-closing the remainder), the server reaches `stopped` with zero live connections
  (no connection leak), and `stopped` absorbs all further events.
-/
import Jemmet.Serve.Lifecycle

namespace Jemmet.Proofs
open Jemmet

/-- While running, an accept adds the connection to the live set. -/
theorem accept_running {s : ServerState} {key : FdKey} (h : s.phase = .running) :
    (stepLifecycle s (.accept key)).live = key :: s.live := by
  simp [stepLifecycle, h, LifecyclePhase.acceptsNew]

/-- Once not running (draining or stopped), an accept is refused — the live set is unchanged. -/
theorem accept_refused_not_running {s : ServerState} {key : FdKey} (h : s.phase ≠ .running) :
    (stepLifecycle s (.accept key)).live = s.live := by
  have hb : s.phase.acceptsNew = false := by
    cases hp : s.phase with
    | running => exact absurd hp h
    | draining d => rfl
    | stopped => rfl
  simp [stepLifecycle, hb]

/-- A shutdown signal while running begins the drain with the given deadline. -/
theorem shutdown_begins_drain {s : ServerState} {dl : Nat} (h : s.phase = .running) :
    (stepLifecycle s (.shutdown dl)).phase = .draining dl := by
  simp [stepLifecycle, h]

/-- Shutdown is idempotent: a second signal once already draining/stopped changes nothing. -/
theorem shutdown_idempotent {s : ServerState} {dl : Nat} (h : s.phase ≠ .running) :
    (stepLifecycle s (.shutdown dl)).phase = s.phase := by
  cases hp : s.phase with
  | running => exact absurd hp h
  | draining d => simp [stepLifecycle, hp]
  | stopped => simp [stepLifecycle, hp]

/-- The drain is bounded: past the deadline the remaining connections are force-closed and
    the server reaches `stopped` with an empty live set. -/
theorem drain_deadline_forces_stop {s : ServerState} {dl now : Nat}
    (hp : s.phase = .draining dl) (hd : dl ≤ now) :
    (stepLifecycle s (.tick now)).phase = .stopped ∧ (stepLifecycle s (.tick now)).live = [] := by
  simp only [stepLifecycle, hp]
  cases hl : s.live with
  | nil => simp [hl]
  | cons a t => simp [hl, hd]

/-- A drained-clean tick (no live connections left) also stops the server. -/
theorem drain_empty_stops {s : ServerState} {dl now : Nat}
    (hp : s.phase = .draining dl) (he : s.live = []) :
    (stepLifecycle s (.tick now)).phase = .stopped := by
  simp only [stepLifecycle, hp]
  simp [he]

/-- `stopped` is absorbing: from a stopped server, every event keeps the phase stopped. -/
theorem stopped_absorbing {s : ServerState} (h : s.phase = .stopped) (e : LifecycleEvent) :
    (stepLifecycle s e).phase = .stopped := by
  cases e with
  | accept key =>
    have hb : s.phase.acceptsNew = false := by simp only [h, LifecyclePhase.acceptsNew]
    simp only [stepLifecycle, hb, if_false]; exact h
  | closeConn key => simp [stepLifecycle, h]
  | shutdown dl => simp [stepLifecycle, h]
  | tick now => simp [stepLifecycle, h]

/-- Once shutdown has begun, no event grows the live set — the drain is monotone toward zero
    (accepts refused, closes shrink, a force-close clears). -/
theorem no_growth_after_shutdown {s : ServerState} (h : s.phase ≠ .running) (e : LifecycleEvent) :
    (stepLifecycle s e).live.length ≤ s.live.length := by
  cases e with
  | accept key => simp [accept_refused_not_running h]
  | closeConn key =>
    simp only [stepLifecycle]
    exact List.length_filter_le _ _
  | shutdown dl =>
    have : (stepLifecycle s (.shutdown dl)).live = s.live := by
      cases hp : s.phase with
      | running => exact absurd hp h
      | draining d => simp [stepLifecycle, hp]
      | stopped => simp [stepLifecycle, hp]
    simp [this]
  | tick now =>
    cases hp : s.phase with
    | running => exact absurd hp h
    | stopped => simp [stepLifecycle, hp]
    | draining d =>
      simp only [stepLifecycle, hp]
      by_cases he : s.live.isEmpty
      · simp [he]
      · by_cases hd : d ≤ now
        · simp [he, hd]
        · simp [he, hd]

/-- No connection leak: when the drain is forced to stop at the deadline, the leak audit
    reports zero live connections. -/
theorem no_leak_after_forced_stop {s : ServerState} {dl now : Nat}
    (hp : s.phase = .draining dl) (hd : dl ≤ now) :
    (stepLifecycle s (.tick now)).audit.liveConns = 0 := by
  have h := (drain_deadline_forces_stop hp hd).2
  simp [ServerState.audit, h]

end Jemmet.Proofs
