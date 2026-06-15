/-
  Jemmet.Proofs.ResponseWf — response well-formedness (RFC 005).

  The security-critical part of serialization is that handler-supplied data cannot
  inject header or status structure (response splitting):

  * `validateHandlerHeaders_clean` — every handler header jemmet emits is CR/LF/CTL-
    free (the others are rejected, not emitted). This is the anti-injection guarantee.
  * `serialize_ok_handlers_validated` — a successful serialize implies the handler
    headers passed validation.
  * `framingHeaders_le_one` / `framingHeaders_disallowed` — the framing header is
    Content-Length xor chunked (never both), and absent entirely for a bodyless status
    (1xx/204/304), so jemmet never emits an ambiguous or double-framed response.

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Http.Response

namespace Jemmet.Proofs
open Jemmet

/-- **Anti-injection.** Every validated handler header has a CR/LF/CTL-free name and
    value; anything else is rejected, never returned. -/
theorem validateHandlerHeaders_clean :
    ∀ (l : List (String × String)) {vs : List (String × String)},
      validateHandlerHeaders l = .ok vs →
      ∀ x ∈ vs, headerSafe x.1 = true ∧ headerSafe x.2 = true := by
  intro l
  induction l with
  | nil =>
    intro vs hv x hx
    simp only [validateHandlerHeaders, Except.ok.injEq] at hv
    subst hv; simp at hx
  | cons nv rest ih =>
    obtain ⟨n, v⟩ := nv
    intro vs hv x hx
    unfold validateHandlerHeaders at hv
    split at hv
    · exact ih hv x hx
    · split at hv
      · rename_i hsafe
        split at hv
        · rename_i vs' hrec
          simp only [Except.ok.injEq] at hv
          subst hv
          rcases List.mem_cons.mp hx with rfl | hx'
          · rw [Bool.and_eq_true] at hsafe; exact hsafe
          · exact ih hrec x hx'
        · simp at hv
      · simp at hv

/-- A successful `finalHeaders` implies the handler headers passed validation. -/
theorem finalHeaders_ok_validated {ctx : SerializeCtx} {resp : HttpResponse}
    {p : List (String × String) × Bool} :
    finalHeaders ctx resp = .ok p →
    ∃ vs, validateHandlerHeaders resp.headers.entries = .ok vs := by
  intro hfh
  cases hvh : validateHandlerHeaders resp.headers.entries with
  | ok vs => exact ⟨vs, rfl⟩
  | error e =>
    exfalso
    simp only [finalHeaders, hvh] at hfh
    repeat' split at hfh
    all_goals simp_all

/-- A successful serialize implies the handler headers were validated CR/LF/CTL-free
    (so handler data cannot have injected header/status structure). -/
theorem serialize_ok_handlers_validated {ctx : SerializeCtx} {resp : HttpResponse} {out : ByteArray} :
    serialize ctx resp = .ok out →
    ∃ vs, validateHandlerHeaders resp.headers.entries = .ok vs ∧
      ∀ x ∈ vs, headerSafe x.1 = true ∧ headerSafe x.2 = true := by
  intro hsout
  cases hfh : finalHeaders ctx resp with
  | error e => exfalso; unfold serialize at hsout; rw [hfh] at hsout; simp at hsout
  | ok p =>
    obtain ⟨vs, hvh⟩ := finalHeaders_ok_validated hfh
    exact ⟨vs, hvh, validateHandlerHeaders_clean _ hvh⟩

/-- The framing header set has at most one element (Content-Length xor chunked,
    never both). -/
theorem framingHeaders_le_one (allowed : Bool) (body : ResponseBody) :
    (framingHeaders allowed body).length ≤ 1 := by
  unfold framingHeaders
  split
  · cases body <;> simp
  · simp

/-- A bodyless status (1xx/204/304 → `allowed = false`) emits no framing header. -/
theorem framingHeaders_disallowed (body : ResponseBody) :
    framingHeaders false body = [] := by
  simp [framingHeaders]

end Jemmet.Proofs
