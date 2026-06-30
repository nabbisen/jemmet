/-
  Jemmet.Henret — the RFC 015 handler-handoff binding over the real henret runtime.

  jemmet's handler policy (RFC 015) hands handler work to a henret task so a slow handler
  cannot stall the serve loop, with a phase-indexed `WaitingForHandler` carrying a deadline
  and cancellation. The requirements flag this as cross-project coordination: the handoff
  "needs the henret task API reachable … to support spawn/observe/cancel." This module binds
  jemmet's abstract `HandlerPhase` to henret's concrete `TaskState`, so the abstract handler
  policy (proven in `Jemmet.Proofs.HandlerPolicy`) is validated against henret's actual,
  separately-verified task lifecycle — whose `completed`/`cancelled` states henret proves
  terminal, which is exactly jemmet's "no late response after close" obligation.

  Isolated in its own library so only this binding depends on henret; the jemmet core and
  its proofs stay dependency-free.
-/
import Jemmet.Serve.HandlerPolicy
import Henret.Scheduler.Model

namespace Jemmet.Henret
open Jemmet
open _root_.Henret

/-- Map a henret task lifecycle state to the jemmet handler phase it represents. The
    handler's own response is supplied for the `completed` case. -/
def handlerPhaseOf (resp : HttpResponse) (s : TaskState) : HandlerPhase :=
  match s with
  | .completed => .ready resp           -- handler finished → its response is ready to write
  | .failed    => .ready failResponse   -- abnormal termination → a 500 is written
  | .cancelled => .cancelled            -- torn down under the task → no response written
  | _          => .running 0 0          -- new/ready/running/yielded/sleeping/waiting: in flight

/-- Whether a handler in the given henret state should write a response to the peer. Depends
    only on the lifecycle state, not the response value. -/
def writesResponse (s : TaskState) : Bool := (handlerPhaseOf failResponse s).writes

/-- A cancelled handler never writes — the jemmet "no response after close" decision, stated
    over henret's lifecycle. (henret proves `cancelled` is terminal, so once here it stays.) -/
theorem cancelled_no_write (r : HttpResponse) : (handlerPhaseOf r .cancelled).writes = false :=
  rfl

/-- A completed handler writes exactly its response. -/
theorem completed_writes (r : HttpResponse) : (handlerPhaseOf r .completed).writes = true :=
  rfl

/-- An in-flight (non-terminal) handler writes nothing yet — the loop stays free. -/
theorem inflight_no_write (r : HttpResponse) (s : TaskState) (h : s.isTerminal = false) :
    (handlerPhaseOf r s).writes = false := by
  cases s <;> simp_all [handlerPhaseOf, HandlerPhase.writes, HandlerPhase.response, TaskState.isTerminal]

end Jemmet.Henret
