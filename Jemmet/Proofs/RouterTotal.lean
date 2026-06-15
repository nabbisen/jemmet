/-
  Jemmet.Proofs.RouterTotal — routing totality and soundness (RFC 006).

  `dispatch` resolves to exactly one outcome for every request (`dispatch_trichotomy`)
  and is a deterministic function. Each outcome is justified by the route table:
  `found` names a real route whose method and pattern both match
  (`dispatch_found_sound`), and `notFound` means genuinely no route pattern matches the
  path (`dispatch_notFound_sound`). `matchPattern` is total and deterministic by
  construction (structural recursion).

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Route.Router

namespace Jemmet.Proofs
open Jemmet

/-- **Totality.** Dispatch yields exactly one of the three outcomes. -/
theorem dispatch_trichotomy (rtr : Router) (req : RequestHead) :
    (∃ h ps, rtr.dispatch req = .found h ps) ∨
    rtr.dispatch req = .notFound ∨
    (∃ allow, rtr.dispatch req = .methodNotAllowed allow) := by
  unfold Router.dispatch
  split
  · exact Or.inl ⟨_, _, rfl⟩
  · split
    · exact Or.inr (Or.inl rfl)
    · exact Or.inr (Or.inr ⟨_, rfl⟩)

/-- `findHandler` only returns a route that is in the list and whose method and
    pattern actually match. -/
theorem findHandler_sound {m : Method} {path : List String} :
    ∀ (rts : List Route) {h : Handler} {ps : Params},
      findHandler m path rts = some (h, ps) →
      ∃ rt, rt ∈ rts ∧ rt.method = m ∧ matchPattern rt.pattern path = some ps ∧ rt.handler = h := by
  intro rts
  induction rts with
  | nil => intro h ps hf; simp [findHandler] at hf
  | cons rt rest ih =>
    intro h ps hf
    unfold findHandler at hf
    split at hf
    · rename_i hmeth
      split at hf
      · rename_i ps' hmp
        simp only [Option.some.injEq, Prod.mk.injEq] at hf
        obtain ⟨hh, hps⟩ := hf
        exact ⟨rt, List.mem_cons_self _ _, hmeth, by rw [hmp, hps], hh⟩
      · obtain ⟨rt', hmem, hm', hmp', hh'⟩ := ih hf
        exact ⟨rt', List.mem_cons_of_mem _ hmem, hm', hmp', hh'⟩
    · obtain ⟨rt', hmem, hm', hmp', hh'⟩ := ih hf
      exact ⟨rt', List.mem_cons_of_mem _ hmem, hm', hmp', hh'⟩

/-- If no method matches a path, `allowedMethods` is empty — i.e. an empty `Allow`
    set means no route pattern matches the path at all. -/
theorem allowedMethods_nil {path : List String} :
    ∀ (rts : List Route), allowedMethods path rts = [] →
      ∀ rt, rt ∈ rts → (matchPattern rt.pattern path).isSome = false := by
  intro rts
  induction rts with
  | nil => intro _ rt hmem; simp at hmem
  | cons rt rest ih =>
    intro hall rt' hmem
    unfold allowedMethods at hall
    split at hall
    · simp at hall
    · rename_i hns
      rcases List.mem_cons.mp hmem with rfl | hmem'
      · simpa using hns
      · exact ih hall rt' hmem'

/-- **Found is sound.** A `found` dispatch names a real route in the table whose method
    matches and whose pattern matches the request path, capturing exactly `ps`. -/
theorem dispatch_found_sound {rtr : Router} {req : RequestHead} {h : Handler} {ps : Params} :
    rtr.dispatch req = .found h ps →
    ∃ rt, rt ∈ rtr.routes ∧ rt.method = req.method ∧
      matchPattern rt.pattern (splitPath req.target.path) = some ps ∧ rt.handler = h := by
  intro hd
  unfold Router.dispatch at hd
  split at hd
  · rename_i hf
    simp only [Dispatch.found.injEq] at hd
    obtain ⟨hh, hps⟩ := hd
    obtain ⟨rt, hmem, hm, hmp, hrh⟩ := findHandler_sound rtr.routes hf
    exact ⟨rt, hmem, hm, by rw [hmp, hps], by rw [hrh, hh]⟩
  · split at hd <;> exact absurd hd (by simp)

/-- **NotFound is sound.** A `notFound` dispatch means genuinely no route pattern
    matches the request path. -/
theorem dispatch_notFound_sound {rtr : Router} {req : RequestHead} :
    rtr.dispatch req = .notFound →
    ∀ rt, rt ∈ rtr.routes → (matchPattern rt.pattern (splitPath req.target.path)).isSome = false := by
  intro hd
  unfold Router.dispatch at hd
  split at hd
  · exact absurd hd (by simp)
  · split at hd
    · rename_i hae
      exact allowedMethods_nil rtr.routes hae
    · exact absurd hd (by simp)

end Jemmet.Proofs
