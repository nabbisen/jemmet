/-
  Jemmet.Proofs.FramingSoundStream — the raw-stream FramingSound capstone (RFC 003).

  RFC 003's headline obligation, assembled over the *whole* request pipeline
  (bytes → head parse → framing decision → body consumption → remainder), from the
  components proven elsewhere:

    * single-message framing uniqueness / no-ambiguous-accept (`Proofs.FramingSound`),
    * head `ParseStep` bounds (`Proofs.ParserBounds`),
    * body-path `Fwd` bounds (`Proofs.ChunkedBounds`).

  For any input, `parseRequest` returns exactly one of `needMore` / `reject` /
  `parsed req rest` (`parseRequest_trichotomy`); the parse is a deterministic function,
  so there is never a second `(req, rest)` interpretation (`parseRequest_deterministic`);
  a parsed request's body framing is the unique, *accepted* decision from its own
  headers — ambiguous framing (CL+TE, conflicting CL, bad TE) never parses, it rejects
  (`parseRequest_parsed_unique_framing`); and the carried remainder is the exact suffix
  of the original buffer, the cursor only ever advancing forward over a buffer that is
  never copied or rewritten, so no byte is dropped, duplicated, or reordered
  (`parseRequest_parsed`/`framing_sound_stream`).

  Together: no two conformant parties can disagree about request boundaries — the
  no-smuggling / no-desync property — now over the raw byte stream, not just normalized
  `Headers`. No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Proofs.ChunkedBounds
import Jemmet.Proofs.FramingSound

namespace Jemmet.Proofs
open Jemmet

/-- **Totality.** Every input yields exactly one outcome. -/
theorem parseRequest_trichotomy (r0 : Reader) (lim : Limits) :
    (∃ req rest, parseRequest r0 lim = .parsed req rest) ∨
    parseRequest r0 lim = .needMore ∨
    (∃ e, parseRequest r0 lim = .reject e) := by
  cases h : parseRequest r0 lim with
  | needMore       => exact Or.inr (Or.inl rfl)
  | reject e       => exact Or.inr (Or.inr ⟨e, rfl⟩)
  | parsed req rest => exact Or.inl ⟨req, rest, rfl⟩

/-- **Determinism / no second interpretation.** A given input parses to a unique
    `(req, rest)`; two conformant parties using this parser cannot disagree. -/
theorem parseRequest_deterministic {r0 : Reader} {lim : Limits}
    {req₁ rest₁ req₂ rest₂} :
    parseRequest r0 lim = .parsed req₁ rest₁ →
    parseRequest r0 lim = .parsed req₂ rest₂ →
    req₁ = req₂ ∧ rest₁ = rest₂ := by
  intro h1 h2
  rw [h1] at h2
  injection h2 with hr hrest
  exact ⟨hr, hrest⟩

/-- **No ambiguous boundary.** A parsed request's framing is exactly the unique,
    accepted `decideFraming` decision over its own headers — so ambiguous framing
    (both CL and TE, conflicting CL, non-final/non-`chunked` TE) is never parsed with a
    guessed body; it is rejected. -/
theorem parseRequest_parsed_unique_framing {r0 rest : Reader} {lim : Limits} {req : HttpRequest} :
    parseRequest r0 lim = .parsed req rest →
    decideFraming req.headers = .ok req.framing := by
  intro h
  unfold parseRequest at h
  cases hph : parseRequestHead r0 lim with
  | needMore => simp only [hph] at h; simp at h
  | reject e => simp only [hph] at h; simp at h
  | parsed head r1 =>
    simp only [hph] at h
    cases hdf : decideFraming head.headers with
    | error e => simp only [hdf] at h; simp at h
    | ok fr =>
      simp only [hdf] at h
      cases fr with
      | none =>
        injection h with hreq _; subst hreq; exact hdf
      | contentLength n =>
        cases htn : r1.takeN n with
        | none => simp only [htn] at h; split at h <;> simp_all
        | some p =>
          obtain ⟨body, r2⟩ := p
          simp only [htn] at h
          split at h
          · simp_all
          · injection h with hreq _; subst hreq; exact hdf
      | chunked =>
        cases hdc : decodeChunked r1 lim ByteArray.empty (lim.maxBodyBytes + 2) with
        | needMore => simp only [hdc] at h; simp at h
        | reject e => simp only [hdc] at h; simp at h
        | done body r2 =>
          simp only [hdc] at h
          injection h with hreq _; subst hreq; exact hdf

/-- **The raw-stream FramingSound theorem.** For any input, `parseRequest` either needs
    more bytes, rejects deterministically, or consumes exactly one request whose framing
    is the unique accepted decision and whose remainder is the exact input suffix on the
    same (never-mutated) buffer — no drop, duplication, or reordering. With
    `parseRequest_deterministic`, that consumed parse is the unique one. -/
theorem framing_sound_stream {r0 : Reader} {lim : Limits} (hwf : r0.Wf) :
    (parseRequest r0 lim = .needMore) ∨
    (∃ e, parseRequest r0 lim = .reject e) ∨
    (∃ req rest, parseRequest r0 lim = .parsed req rest ∧
      decideFraming req.headers = .ok req.framing ∧
      rest.data = r0.data ∧ r0.off ≤ rest.off ∧ rest.off ≤ r0.data.size) := by
  cases h : parseRequest r0 lim with
  | needMore => exact Or.inl rfl
  | reject e => exact Or.inr (Or.inl ⟨e, rfl⟩)
  | parsed req rest =>
    exact Or.inr (Or.inr ⟨req, rest, rfl,
      parseRequest_parsed_unique_framing h, parseRequest_parsed hwf h⟩)

/-- At the entry point the input reader is well-formed, so the stream theorem applies
    unconditionally to a freshly-wrapped byte buffer. -/
theorem framing_sound_stream_ofBytes (b : ByteArray) (lim : Limits) :
    (parseRequest (Reader.ofBytes b) lim = .needMore) ∨
    (∃ e, parseRequest (Reader.ofBytes b) lim = .reject e) ∨
    (∃ req rest, parseRequest (Reader.ofBytes b) lim = .parsed req rest ∧
      decideFraming req.headers = .ok req.framing ∧
      rest.data = (Reader.ofBytes b).data ∧
      (Reader.ofBytes b).off ≤ rest.off ∧ rest.off ≤ (Reader.ofBytes b).data.size) :=
  framing_sound_stream (ofBytes_wf b)

end Jemmet.Proofs
