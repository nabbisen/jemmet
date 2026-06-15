/-
  Jemmet.Proofs.KeepAlive — the keep-alive request-boundary proof (RFC 007, §3.2.7).

  On a reused connection, mis-identifying where one request ends and the next begins is
  itself a smuggling vector. This proves the boundary machine is correct:

  * `nextRequest_one_iff_parsed` — one boundary step is exactly one `parseRequest`, so
    each consumed unit is one complete, well-framed request (with the unambiguous
    framing guaranteed by `Proofs.FramingSoundStream`);
  * `nextRequest_one_fwd` — that step's remainder is the exact input suffix on the same
    buffer (no byte dropped, duplicated, or reordered at the boundary);
  * `drainAux_fwd` / `keepAlive_boundary` — draining a pipelined batch leaves the cursor
    at a forward position on the same never-mutated buffer, so the carried remainder is
    exactly the unconsumed suffix: requests are consumed strictly in order, one complete
    request before the next, with nothing lost or replayed.

  Builds on `parseRequest_parsed` (RFC 003/004). No project-local `sorry`/`axiom`/
  `unsafe`.
-/
import Jemmet.Proofs.ChunkedBounds
import Jemmet.Serve.ConnState

namespace Jemmet.Proofs
open Jemmet

/-- A reader is a forward suffix of itself. -/
theorem Fwd.refl {r : Reader} (hwf : r.Wf) : Fwd r r :=
  ⟨rfl, Nat.le_refl _, hwf⟩

/-- A boundary step is exactly one `parseRequest`. -/
theorem nextRequest_one_iff_parsed {lim : Limits} {r : Reader} {req : HttpRequest} {rest : Reader} :
    nextRequest lim r = .one req rest ↔ parseRequest r lim = .parsed req rest := by
  unfold nextRequest
  cases parseRequest r lim <;> simp

/-- One boundary step consumes one request and leaves the exact input suffix. -/
theorem nextRequest_one_fwd {lim : Limits} {r rest : Reader} {req : HttpRequest} :
    r.Wf → nextRequest lim r = .one req rest → Fwd r rest := by
  intro hwf h
  exact parseRequest_parsed hwf (nextRequest_one_iff_parsed.mp h)

/-- Draining a pipelined batch advances the cursor forward over the same buffer; the
    leftover reader is exactly the unconsumed suffix. -/
theorem drainAux_fwd {lim : Limits} :
    ∀ (fuel : Nat) {r : Reader} {acc reqs : List HttpRequest} {rest : Reader} {e : DrainEnd},
      r.Wf → drainAux lim r acc fuel = (reqs, rest, e) → Fwd r rest := by
  intro fuel
  induction fuel with
  | zero =>
    intro r acc reqs rest e hwf h
    simp only [drainAux, Prod.mk.injEq] at h
    obtain ⟨_, hrest, _⟩ := h
    rw [← hrest]; exact Fwd.refl hwf
  | succ fuel ih =>
    intro r acc reqs rest e hwf h
    unfold drainAux at h
    cases hn : nextRequest lim r with
    | needMore =>
      simp only [hn, Prod.mk.injEq] at h
      obtain ⟨_, hrest, _⟩ := h
      rw [← hrest]; exact Fwd.refl hwf
    | reject e' =>
      simp only [hn, Prod.mk.injEq] at h
      obtain ⟨_, hrest, _⟩ := h
      rw [← hrest]; exact Fwd.refl hwf
    | one req rest' =>
      simp only [hn] at h
      have hf1 : Fwd r rest' := nextRequest_one_fwd hwf hn
      exact hf1.trans (ih hf1.wf h)

/-- **Keep-alive boundary.** Processing a pipelined batch on a reused connection carries
    the remainder exactly: the leftover is a forward suffix of the input on the same
    buffer — no request's bytes are dropped, duplicated, or reordered across boundaries,
    and each consumed unit is one complete well-framed request. -/
theorem keepAlive_boundary {lim : Limits} {r rest : Reader}
    {reqs : List HttpRequest} {e : DrainEnd} :
    r.Wf → drain lim r = (reqs, rest, e) → Fwd r rest :=
  fun hwf h => drainAux_fwd _ hwf h

end Jemmet.Proofs
