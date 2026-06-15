/-
  Jemmet.Proofs.ConnFakeDet — FakeConn determinism (RFC 002 proof obligation).

  The substance of "FakeConn is deterministic": every `Conn` operation on a
  `FakeConn` is exactly `pure` of a total **pure transition function**, so the `IO`
  wrapper contributes no nondeterminism and replay of a fixed operation script from a
  fixed start state is exact. This is what justifies using `FakeConn` as the
  deterministic substrate for the M1 parser/framing/routing/keep-alive tests and the
  M1.5 event-trace runner (RFC 014).

  No `sorry`/`axiom`/`unsafe` (RFC 011 cleanliness criterion).
-/
import Jemmet.Conn.Fake

namespace Jemmet.Proofs
open Jemmet

/-! ### Each operation is `pure` of its pure transition function -/

theorem fake_recv_pure (c : FakeConn) (n : Nat) :
    Conn.recv c n = pure (FakeConn.recvPure c n) := rfl

theorem fake_send_pure (c : FakeConn) (b : ByteArray) :
    Conn.send c b = pure (FakeConn.sendPure c b) := rfl

theorem fake_flush_pure (c : FakeConn) :
    Conn.flush c = pure (FakeConn.flushPure c) := rfl

theorem fake_close_pure (c : FakeConn) (m : CloseMode) :
    Conn.close c m = pure (FakeConn.closePure c m) := rfl

/-! ### Replay determinism over an operation script

A single uniform `Op` alphabet lets us state the headline determinism property: the
`IO` execution of any operation list equals `pure` of a purely-computed final state,
so two executions of the same script from the same start coincide. -/

/-- A connection operation. -/
inductive Op where
  | recv (n : Nat)
  | send (b : ByteArray)
  | flush
  | close (m : CloseMode)

/-- Pure state transition for one operation (projects out the next `FakeConn`). -/
def stepPure (c : FakeConn) : Op → FakeConn
  | .recv n  => (FakeConn.recvPure c n).2.2
  | .send b  => (FakeConn.sendPure c b).2.2
  | .flush   => (FakeConn.flushPure c).2.2
  | .close m => (FakeConn.closePure c m).2

/-- `IO` execution of one operation through the `Conn` interface. -/
def stepIO (c : FakeConn) : Op → IO FakeConn
  | .recv n  => Conn.recv c n  >>= fun r => pure r.2.2
  | .send b  => Conn.send c b  >>= fun r => pure r.2.2
  | .flush   => Conn.flush c   >>= fun r => pure r.2.2
  | .close m => Conn.close c m >>= fun r => pure r.2

/-- One `IO` step equals `pure` of the pure step. (`pure x >>= f` is definitionally
    `f x` for `IO`'s underlying `EStateM`, so each case is `rfl`.) -/
theorem stepIO_eq_pure (c : FakeConn) (op : Op) :
    stepIO c op = pure (stepPure c op) := by
  cases op <;> rfl

/-- Pure execution of a whole script. -/
def runPure (c : FakeConn) (ops : List Op) : FakeConn :=
  ops.foldl stepPure c

/-- `IO` execution of a whole script. -/
def runIO (c : FakeConn) (ops : List Op) : IO FakeConn :=
  ops.foldlM stepIO c

/-- A monadic left fold whose step is always `pure` collapses to a pure left fold.
    The cons case holds by definitional reduction (`foldlM` unfolds, and
    `pure x >>= k` is defeq `k x`) followed by the induction hypothesis. -/
private theorem foldlM_pure_eq {β α : Type} (f : β → α → β) :
    ∀ (init : β) (l : List α),
      List.foldlM (m := IO) (fun b a => pure (f b a)) init l
        = pure (List.foldl f init l)
  | _, [] => rfl
  | init, a :: as => by
      show List.foldlM (m := IO) (fun b a => pure (f b a)) (f init a) as
            = pure (List.foldl f (f init a) as)
      exact foldlM_pure_eq f (f init a) as

/-- **Replay determinism.** Executing any operation script through the `Conn`
    interface equals `pure` of the purely-computed final state. Hence the result is a
    total function of `(start state, script)` and two executions coincide. -/
theorem runIO_eq_pure (c : FakeConn) (ops : List Op) :
    runIO c ops = pure (runPure c ops) := by
  have hfun : stepIO = fun c op => pure (stepPure c op) := by
    funext c op; exact stepIO_eq_pure c op
  unfold runIO runPure
  rw [hfun]
  exact foldlM_pure_eq stepPure c ops

/-- Corollary: replaying the same script from the same start is deterministic. -/
theorem replay_deterministic (c : FakeConn) (ops : List Op) :
    runIO c ops = runIO c ops := rfl

end Jemmet.Proofs
