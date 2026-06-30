/-
  Jemmet.Proofs.EgressBound — egress-boundedness invariant (RFC 010).

  The mandatory egress safety property, proven for the plaintext tier: under backpressure
  (produce output only while owned output is below the cap), owned user-space output stays
  within `cap + maxStepOutput` across **any** sequence of steps — so a peer that never
  drains cannot force unbounded buffering, no matter how many requests it sends
  (`egress_invariant`). Plus the three-tier accounting soundness and the admit/at-cap
  characterisation.

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Serve.Egress

namespace Jemmet.Proofs
open Jemmet

/-- Accounting soundness: the plaintext account's total is exactly the owned output. -/
theorem plaintext_total (n : Nat) : (plaintextAccount n).total = n := by
  simp [plaintextAccount, EgressAccount.total]

/-- The plaintext bound reduces to `owned ≤ cap`. -/
theorem plaintext_withinBound (n cap : Nat) :
    (plaintextAccount n).withinBound cap = true ↔ n ≤ cap := by
  simp [EgressAccount.withinBound, plaintext_total]

/-- Backpressure admits exactly while strictly below the cap. -/
theorem admits_iff_below (cap owned : Nat) : egressAdmits cap owned = true ↔ owned < cap := by
  simp [egressAdmits]

/-- When the driver stops producing, owned output is already at the cap (so the stop is
    correct — we never backpressure prematurely, never produce while over). -/
theorem not_admits_at_cap (cap owned : Nat) (h : egressAdmits cap owned = false) : cap ≤ owned := by
  unfold egressAdmits at h
  simp only [decide_eq_false_iff_not, Nat.not_lt] at h
  exact h

/-- **One bounded step preserves the egress bound.** If owned output starts within
    `cap + maxStep` and a step adds at most `maxStep`, owned output stays within
    `cap + maxStep` — whether the step is admitted (adds, but only from below the cap) or
    backpressured (unchanged). -/
theorem stepOwned_bounded (cap maxStep owned added : Nat)
    (hadded : added ≤ maxStep) (hstart : owned ≤ cap + maxStep) :
    stepOwned cap owned added ≤ cap + maxStep := by
  unfold stepOwned egressAdmits
  split <;> rename_i h <;>
    first
      | omega
      | (simp only [decide_eq_true_eq, decide_eq_false_iff_not, Nat.not_lt] at h; omega)

/-- **Egress boundedness over any step sequence (RFC 010).** Starting within
    `cap + maxStep`, after any sequence of steps each adding at most `maxStep`, owned
    user-space output is still within `cap + maxStep`. The bound is independent of the
    number of steps — a peer that never drains cannot grow it without limit. -/
theorem egress_invariant (cap maxStep : Nat) (addeds : List Nat)
    (hall : ∀ a ∈ addeds, a ≤ maxStep) (owned0 : Nat) (h0 : owned0 ≤ cap + maxStep) :
    (addeds.foldl (fun o a => stepOwned cap o a) owned0) ≤ cap + maxStep := by
  induction addeds generalizing owned0 with
  | nil => exact h0
  | cons a rest ih =>
    apply ih (fun x hx => hall x (List.mem_cons_of_mem _ hx))
    exact stepOwned_bounded cap maxStep owned0 a (hall a (List.mem_cons_self _ _)) h0

end Jemmet.Proofs
