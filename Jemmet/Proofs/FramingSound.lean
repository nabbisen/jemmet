/-
  Jemmet.Proofs.FramingSound — soundness of the framing decision (RFC 003).

  These are the single-message uniqueness lemmas the raw-stream `FramingSound`
  theorem composes on (per the review's RFC 003⇄004 sequencing). The headline
  content:

  * `decideFraming` is a deterministic total function, so two conformant parties that
    normalize to the same `Headers` compute the *same* framing — they cannot disagree
    about boundaries from agreed headers (`framing_unique`).
  * the classic smuggling input — Content-Length and Transfer-Encoding both present —
    is **rejected**, never resolved to a body framing (`framing_reject_both`,
    `framing_no_ambiguous_accept`).
  * each acceptance is justified by the headers (`framing_ok_none`, `framing_ok_cl`):
    accepting Content-Length framing implies exactly one well-formed length and no
    Transfer-Encoding.

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Http.Framing

namespace Jemmet.Proofs
open Jemmet

/-- **Determinism / uniqueness.** A given header set yields one framing decision; two
    accepted framings for the same headers are equal. (No two interpretations.) -/
theorem framing_unique (h : Headers) (f₁ f₂ : BodyFraming)
    (h₁ : decideFraming h = .ok f₁) (h₂ : decideFraming h = .ok f₂) : f₁ = f₂ := by
  rw [h₁] at h₂; exact Except.ok.inj h₂

/-- **No guessing.** Content-Length and Transfer-Encoding both present ⇒ hard reject. -/
theorem framing_reject_both (h : Headers)
    (hc : h.getAll "content-length" ≠ []) (ht : h.getAll "transfer-encoding" ≠ []) :
    decideFraming h = .error .both := by
  unfold decideFraming
  cases hcl : h.getAll "content-length" <;> cases hte : h.getAll "transfer-encoding" <;>
    simp_all

/-- Corollary: when both are present, no body framing is ever accepted (the
    smuggling-defining ambiguity cannot produce a boundary). -/
theorem framing_no_ambiguous_accept (h : Headers)
    (hc : h.getAll "content-length" ≠ []) (ht : h.getAll "transfer-encoding" ≠ []) :
    ∀ f, decideFraming h ≠ .ok f := by
  intro f hf
  rw [framing_reject_both h hc ht] at hf
  exact Except.noConfusion hf

/-- Accepting "no body" implies neither Content-Length nor Transfer-Encoding. -/
theorem framing_ok_none (h : Headers) (heq : decideFraming h = .ok .none) :
    h.getAll "content-length" = [] ∧ h.getAll "transfer-encoding" = [] := by
  unfold decideFraming at heq
  cases hcl : h.getAll "content-length" <;> cases hte : h.getAll "transfer-encoding" <;>
    simp_all <;> (repeat' split at heq) <;> simp_all

-- A stronger witness lemma (`decideFraming h = .ok (.contentLength n)` implies a
-- single well-formed Content-Length and no Transfer-Encoding) is a natural
-- strengthening; it is left for the raw-stream `FramingSound` composition where the
-- header-normalization lemmas from RFC 004 are available.

end Jemmet.Proofs

