/-
  Jemmet.Proofs.ParserBounds — bounds safety and the parse-step conservation property
  (RFC 004 proof obligations 1 and 2).

  * **ParserBounds.** `byteAt` — the only byte accessor — reads only in-bounds indices
    (`byteAt_some_lt` / `byteAt_none_ge`), and every `Reader` transition preserves the
    invariant `off ≤ size` (`Reader.Wf`). So the parser indexes nothing out of bounds,
    by construction, and is total (a total Lean function over all byte inputs).

  * **ParseStep.** Every reader transition is *monotone* (`off` only advances) and
    *buffer-preserving* (`data` unchanged), so a parsed request consumes a forward,
    bounded, contiguous prefix and the remainder is exactly the suffix `data[off:]` at
    a uniquely determined offset — the parser never drops, duplicates, or reorders
    bytes. `parseRequestHead_parsed` lifts this through the request-line and header
    loop; `parseRequestHead_remainder` states the carried remainder is exactly that
    suffix. This is the parser-side input the raw-stream `FramingSound` theorem
    composes on.

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Http.Request

/-- The reader invariant: the offset never exceeds the buffer size. -/
def Jemmet.Reader.Wf (r : Jemmet.Reader) : Prop := r.off ≤ r.data.size

namespace Jemmet.Proofs
open Jemmet

/-! ### ParserBounds: the only accessor is bounds-checked -/

theorem byteAt_some_lt {b : ByteArray} {i : Nat} {x : UInt8} :
    byteAt b i = some x → i < b.size := by
  unfold byteAt; split <;> simp_all

theorem byteAt_none_ge {b : ByteArray} {i : Nat} :
    byteAt b i = none → b.size ≤ i := by
  unfold byteAt; split <;> simp_all <;> omega

/-! ### The reader well-formedness invariant `off ≤ size` -/

theorem ofBytes_wf (b : ByteArray) : (Reader.ofBytes b).Wf := by
  simp [Reader.Wf, Reader.ofBytes]

theorem advance_wf {r : Reader} (k : Nat) : (r.advance k).Wf := by
  unfold Reader.Wf Reader.advance; exact Nat.min_le_left _ _

/-! ### Primitive transitions: monotone, buffer-preserving, wf-preserving -/

theorem takeN_step {r r' : Reader} {n : Nat} {bs : ByteArray} :
    r.takeN n = some (bs, r') →
    r'.data = r.data ∧ r'.off = r.off + n ∧ r'.off ≤ r'.data.size := by
  intro h
  unfold Reader.takeN at h
  split at h
  · rename_i hle
    simp only [Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨_, hr'⟩ := h
    subst hr'
    exact ⟨rfl, rfl, by simpa using hle⟩
  · simp at h

/-- The scan invariant: starting at any `i ≥ r.off` (with `r` well-formed), a produced
    line advances the offset forward, within bounds, leaving the buffer unchanged. -/
theorem scanLine_step {r : Reader} :
    ∀ (i fuel : Nat) {content : ByteArray} {r' : Reader},
      r.off ≤ i → r.Wf → r.scanLine i fuel = .line content r' →
      r'.data = r.data ∧ r.off ≤ r'.off ∧ r'.off ≤ r.data.size := by
  intro i fuel
  induction fuel generalizing i with
  | zero => intro _ _ _ _ h; simp [Reader.scanLine] at h
  | succ fuel ih =>
    intro content r' hoi hwf h
    unfold Reader.scanLine at h
    repeat' split at h
    -- recurse leaves
    all_goals try exact ih (i + 1) (by omega) hwf h
    -- line-success leaves
    all_goals try (injection h with _ hr'
                   subst hr'
                   exact ⟨rfl, Nat.le_min.mpr ⟨hwf, by omega⟩, Nat.min_le_left _ _⟩)
    -- remaining reject leaves (distinct constructors vs `.line`)
    all_goals simp_all

theorem takeLine_step {r r' : Reader} {content : ByteArray} {maxLen : Nat} :
    r.Wf → r.takeLine maxLen = .line content r' →
    r'.data = r.data ∧ r.off ≤ r'.off ∧ r'.off ≤ r.data.size := by
  intro hwf h
  unfold Reader.takeLine at h
  exact scanLine_step r.off (maxLen + 1) (Nat.le_refl _) hwf h

/-! ### ParseStep: the head parser advances forward, in bounds, buffer-preserving -/

/-- The header loop preserves the buffer and advances the offset forward within
    bounds. Proof: induction on the fuel (header-count budget). -/
theorem parseHeaderLines_parsed {lim : Limits} :
    ∀ (fuel : Nat) (r : Reader) (acc : Headers) (used : Nat)
      {head : RequestHead} {r' : Reader},
      r.Wf → parseHeaderLines r lim acc used fuel = .parsed head r' →
      r'.data = r.data ∧ r.off ≤ r'.off ∧ r'.off ≤ r.data.size := by
  intro fuel
  induction fuel with
  | zero => intro r acc used head r' _ h; simp [parseHeaderLines] at h
  | succ fuel ih =>
    intro r acc used head r' hwf h
    unfold parseHeaderLines at h
    cases htl : r.takeLine lim.maxHeaderLineBytes with
    | needMore => simp only [htl] at h; simp at h
    | reject e => simp only [htl] at h; cases e <;> simp at h
    | line content r1 =>
      simp only [htl] at h
      have hstep := takeLine_step hwf htl
      obtain ⟨hdata1, hmono1, hbound1⟩ := hstep
      have hwf1 : r1.Wf := by show r1.off ≤ r1.data.size; rw [hdata1]; exact hbound1
      by_cases hemp : content.isEmpty
      · rw [if_pos hemp, ParseHeadResult.parsed.injEq] at h
        obtain ⟨_, hr'⟩ := h
        subst hr'
        exact ⟨hdata1, hmono1, hbound1⟩
      · rw [if_neg hemp] at h
        -- Only the recursive (ok) arm yields `.parsed`; close the guard/error arms,
        -- then the single remaining (recursive) goal is handled by the IH.
        repeat' split at h
        all_goals try (exact absurd h (by simp))
        obtain ⟨hd, hm, hbnd⟩ := ih r1 _ _ hwf1 h
        exact ⟨hd.trans hdata1, Nat.le_trans hmono1 hm, by rw [← hdata1]; exact hbnd⟩

/-- **ParseStep (head).** A parsed request head consumes a forward, bounded,
    contiguous prefix of `r0`'s buffer, leaving the buffer unchanged; the remainder is
    the suffix at the uniquely determined offset `rest.off` with `r0.off ≤ rest.off ≤
    size`. Combined with `parseRequestHead` being a function (determinism), the request
    boundary is a function of the input — no two interpretations. -/
theorem parseRequestHead_parsed {r0 : Reader} {lim : Limits}
    {head : RequestHead} {rest : Reader} :
    r0.Wf → parseRequestHead r0 lim = .parsed head rest →
    rest.data = r0.data ∧ r0.off ≤ rest.off ∧ rest.off ≤ r0.data.size := by
  intro hwf h
  unfold parseRequestHead at h
  cases htl : r0.takeLine lim.maxRequestLineBytes with
  | needMore => simp only [htl] at h; simp at h
  | reject e => simp only [htl] at h; cases e <;> simp at h
  | line content r1 =>
    have hstep := takeLine_step hwf htl
    obtain ⟨hdata1, hmono1, hbound1⟩ := hstep
    have hwf1 : r1.Wf := by show r1.off ≤ r1.data.size; rw [hdata1]; exact hbound1
    cases hrl : parseRequestLine content with
    | error e => simp [htl, hrl] at h
    | ok mtv =>
      cases hpl : parseHeaderLines r1 lim Headers.empty 0 (lim.maxHeaderCount + 1) with
      | needMore => simp [htl, hrl, hpl] at h
      | reject e => simp [htl, hrl, hpl] at h
      | parsed head2 r2 =>
        simp only [htl, hrl, hpl, ParseHeadResult.parsed.injEq] at h
        obtain ⟨_, hr2⟩ := h
        subst hr2
        obtain ⟨hd, hm, hbnd⟩ := parseHeaderLines_parsed _ r1 Headers.empty 0 hwf1 hpl
        exact ⟨hd.trans hdata1, Nat.le_trans hmono1 hm, by rw [← hdata1]; exact hbnd⟩

/-- The carried remainder is exactly the input suffix at the parsed boundary offset:
    no bytes are dropped, duplicated, or reordered. -/
theorem parseRequestHead_remainder {r0 : Reader} {lim : Limits}
    {head : RequestHead} {rest : Reader} :
    r0.Wf → parseRequestHead r0 lim = .parsed head rest →
    rest.rest = r0.data.extract rest.off r0.data.size := by
  intro hwf h
  obtain ⟨hdata, _, _⟩ := parseRequestHead_parsed hwf h
  simp [Reader.rest, hdata]

end Jemmet.Proofs
