/-
  Jemmet.Proofs.ObserveSafe — the access-log injection defense (RFC 016 / §3.4).

  Proven: the sanitizer strips every control character, so a rendered access line can never
  contain CR or LF — an attacker-controlled path (or any field) cannot forge a second log
  entry. Combined with `AccessRecord`'s safe-only fields (no header values, no body — by
  construction), the log surface is both leak-free and injection-free.

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Observe

namespace Jemmet.Proofs
open Jemmet

/-- `?` is not a control character (the sanitizer's replacement is safe). -/
theorem sanitizeChar_not_ctl (c : Char) : isCtl (sanitizeChar c) = false := by
  unfold sanitizeChar
  by_cases h : isCtl c = true
  · rw [if_pos h]; decide
  · rw [if_neg h]
    cases hh : isCtl c with
    | true  => exact absurd hh h
    | false => rfl

/-- **The sanitizer strips every control character**: no character of a sanitized string is
    a control character. -/
theorem sanitize_no_ctl (s : String) :
    ∀ c ∈ (sanitize s).data, isCtl c = false := by
  intro c hc
  simp only [sanitize, List.mem_map] at hc
  obtain ⟨a, _, rfl⟩ := hc
  exact sanitizeChar_not_ctl a

/-- A control character is never present in a sanitized string. -/
theorem sanitize_excludes_ctl (s : String) (c : Char) (hc : isCtl c = true) :
    c ∉ (sanitize s).data := by
  intro hmem
  have := sanitize_no_ctl s c hmem
  rw [hc] at this
  exact Bool.noConfusion this

/-- **No log injection**: a rendered access line contains neither LF nor CR, so no field can
    forge a second log entry. -/
theorem render_no_newline (r : AccessRecord) :
    '\n' ∉ r.render.data ∧ '\r' ∉ r.render.data := by
  refine ⟨?_, ?_⟩
  · exact sanitize_excludes_ctl _ '\n' (by decide)
  · exact sanitize_excludes_ctl _ '\r' (by decide)

/-- The rendered line as a whole is control-character-free. -/
theorem render_no_ctl (r : AccessRecord) :
    ∀ c ∈ r.render.data, isCtl c = false :=
  sanitize_no_ctl _

end Jemmet.Proofs
