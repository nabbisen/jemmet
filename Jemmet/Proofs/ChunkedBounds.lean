/-
  Jemmet.Proofs.ChunkedBounds — bounds safety of chunked decoding and full-request
  body assembly (RFC 003 / RFC 004).

  Extends the `ParseStep` story from the head to the whole request. The body
  decoder advances the `Reader` only forward, never past the end, and preserves the
  buffer (`r'.data = r.data`); the carried remainder after a full request is exactly
  a suffix of the input — so the parser never drops, duplicates, or reorders bytes,
  even through the chunked body. Determinism is automatic (every function is total).

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Proofs.ParserBounds
import Jemmet.Http.Chunked

namespace Jemmet.Proofs
open Jemmet

/-- A forward, buffer-preserving, in-bounds reader step (the `ParseStep` shape). -/
def Fwd (r r' : Reader) : Prop :=
  r'.data = r.data ∧ r.off ≤ r'.off ∧ r'.off ≤ r.data.size

theorem Fwd.trans {r r1 r2 : Reader} (h1 : Fwd r r1) (h2 : Fwd r1 r2) : Fwd r r2 :=
  ⟨h2.1.trans h1.1, Nat.le_trans h1.2.1 h2.2.1, by rw [← h1.1]; exact h2.2.2⟩

theorem Fwd.wf {r r' : Reader} (h : Fwd r r') : r'.Wf := by
  show r'.off ≤ r'.data.size; rw [h.1]; exact h.2.2

/-! ### Step wrappers as `Fwd` -/

theorem takeLine_fwd {r r' : Reader} {c : ByteArray} {m : Nat}
    (hwf : r.Wf) (h : r.takeLine m = .line c r') : Fwd r r' :=
  takeLine_step hwf h

theorem takeN_fwd {r r' : Reader} {n : Nat} {bs : ByteArray}
    (h : r.takeN n = some (bs, r')) : Fwd r r' :=
  let ⟨hd, hoff, hb⟩ := takeN_step h
  ⟨hd, by omega, by rw [hd] at hb; exact hb⟩

theorem takeCRLF_fwd {r r' : Reader} (h : r.takeCRLF = .ok r') : Fwd r r' := by
  unfold Reader.takeCRLF at h
  cases htn : r.takeN 2 with
  | none => simp_all
  | some p =>
    obtain ⟨bs, r2⟩ := p
    have hfwd : Fwd r r2 := takeN_fwd htn
    simp only [htn] at h
    repeat' split at h
    all_goals first
      | (injection h with hh; subst hh; exact hfwd)
      | simp_all

/-! ### Trailer and chunk decoding are forward and bounded -/

theorem consumeTrailers_fwd {lim : Limits} :
    ∀ (fuel : Nat) {r r' : Reader}, r.Wf →
      consumeTrailers r lim fuel = .done r' → Fwd r r' := by
  intro fuel
  induction fuel with
  | zero => intro r r' _ h; simp [consumeTrailers] at h
  | succ fuel ih =>
    intro r r' hwf h
    unfold consumeTrailers at h
    cases htl : r.takeLine lim.maxChunkLineBytes with
    | needMore => simp only [htl] at h; simp at h
    | reject e => simp only [htl] at h; cases e <;> simp at h
    | line content r1 =>
      have hf1 : Fwd r r1 := takeLine_fwd hwf htl
      simp only [htl] at h
      split at h
      · injection h with hh; subst hh; exact hf1
      · exact hf1.trans (ih hf1.wf h)

theorem decodeChunked_fwd {lim : Limits} :
    ∀ (fuel : Nat) {r r' : Reader} {acc body : ByteArray}, r.Wf →
      decodeChunked r lim acc fuel = .done body r' → Fwd r r' := by
  intro fuel
  induction fuel with
  | zero => intro r r' acc body _ h; simp [decodeChunked] at h
  | succ fuel ih =>
    intro r r' acc body hwf h
    unfold decodeChunked at h
    cases htl : r.takeLine lim.maxChunkLineBytes with
    | needMore => simp only [htl] at h; simp at h
    | reject e => simp only [htl] at h; cases e <;> simp at h
    | line sizeLine r1 =>
      have hf1 : Fwd r r1 := takeLine_fwd hwf htl
      simp only [htl] at h
      cases hcs : parseChunkSize sizeLine with
      | none => simp only [hcs] at h; simp at h
      | some sz =>
        simp only [hcs] at h
        split at h
        · cases hct : consumeTrailers r1 lim (lim.maxHeaderCount + 1) with
          | needMore => simp only [hct] at h; simp at h
          | reject e => simp only [hct] at h; simp at h
          | done r2 =>
            simp only [hct, ChunkResult.done.injEq] at h
            obtain ⟨_, hr2⟩ := h; subst hr2
            exact hf1.trans (consumeTrailers_fwd _ hf1.wf hct)
        · split at h
          · simp at h
          · cases htn : r1.takeN sz with
            | none => simp only [htn] at h; simp at h
            | some p =>
              obtain ⟨data, r2⟩ := p
              have hf2 : Fwd r1 r2 := takeN_fwd htn
              simp only [htn] at h
              cases hcr : r2.takeCRLF with
              | needMore => simp only [hcr] at h; simp at h
              | reject => simp only [hcr] at h; simp at h
              | ok r3 =>
                have hf3 : Fwd r2 r3 := takeCRLF_fwd hcr
                have hf123 : Fwd r r3 := (hf1.trans hf2).trans hf3
                simp only [hcr] at h
                exact hf123.trans (ih hf123.wf h)

/-! ### Full-request parse: head + body is forward and bounded -/

/-- A fully-parsed request consumes a forward, bounded prefix; the carried remainder
    is exactly a suffix of the input (no byte dropped, duplicated, or reordered). -/
theorem parseRequest_parsed {r0 r' : Reader} {lim : Limits} {req : HttpRequest} :
    r0.Wf → parseRequest r0 lim = .parsed req r' → Fwd r0 r' := by
  intro hwf h
  unfold parseRequest at h
  cases hph : parseRequestHead r0 lim with
  | needMore => simp only [hph] at h; simp at h
  | reject e => simp only [hph] at h; simp at h
  | parsed head r1 =>
    have hf1 : Fwd r0 r1 := parseRequestHead_parsed hwf hph
    simp only [hph] at h
    cases hdf : decideFraming head.headers with
    | error e => simp only [hdf] at h; simp at h
    | ok fr =>
      simp only [hdf] at h
      cases fr with
      | none =>
        simp only [RequestResult.parsed.injEq] at h
        obtain ⟨_, hr1⟩ := h; subst hr1; exact hf1
      | contentLength n =>
        cases htn : r1.takeN n with
        | none => simp only [htn] at h; split at h <;> simp_all
        | some p =>
          obtain ⟨body, r2⟩ := p
          have hf2 : Fwd r1 r2 := takeN_fwd htn
          simp only [htn] at h
          split at h
          · simp_all
          · injection h with _ hr2; subst hr2; exact hf1.trans hf2
      | chunked =>
        cases hdc : decodeChunked r1 lim ByteArray.empty (lim.maxBodyBytes + 2) with
        | needMore => simp only [hdc] at h; simp at h
        | reject e => simp only [hdc] at h; simp at h
        | done body r2 =>
          simp only [hdc, RequestResult.parsed.injEq] at h
          obtain ⟨_, hr2⟩ := h; subst hr2
          exact hf1.trans (decodeChunked_fwd _ hf1.wf hdc)

end Jemmet.Proofs
