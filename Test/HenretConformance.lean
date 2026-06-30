/-
  Test.HenretConformance — RFC 015 handler-handoff validated over the real henret runtime.

  jemmet's handler policy is proven over an abstract `HandlerPhase` model. This drives the
  actual henret scheduler (`Henret.step` over `RuntimeState`) through the handler lifecycles
  and checks each resulting task state maps to the jemmet write-decision the policy expects:
  a completed handler writes its response, a cancelled handler writes nothing (no late
  response after close), a failed handler writes a 500, an in-flight handler writes nothing
  yet. It also exercises henret's terminal-state permanence (a late op on a terminal task is
  rejected and the state is unchanged) and the sleep/tick timer the deadline path relies on.

  This turns RFC 015's ASSUMED henret task API into a validated binding: the default
  task-handoff path is confirmed viable against real henret, not the strict-inline fallback.
-/
import Jemmet.Henret

namespace Test.Henret
open Jemmet
open _root_.Henret
open Jemmet.Henret

abbrev Check := String × Bool

/-- Run a sequence of runtime ops from the initial state; return the final state and the
    last step result. -/
def runOps (ops : List RuntimeOp) : RuntimeState × StepResult :=
  ops.foldl (fun acc op => step acc.1 op) (RuntimeState.init, StepResult.ok)

/-- Final lifecycle state of task 0 (the first spawned task). -/
def st (ops : List RuntimeOp) : Option TaskState := (runOps ops).1.taskState 0
/-- The last step result of a sequence. -/
def res (ops : List RuntimeOp) : StepResult := (runOps ops).2

def checks : List Check :=
  [ ("complete → henret 'completed' → jemmet writes a response",
        st [.spawn 0, .schedule, .complete 0] == some .completed
        && writesResponse .completed == true),
    ("cancel → henret 'cancelled' → no response (no late response after close)",
        st [.spawn 0, .schedule, .cancel 0] == some .cancelled
        && writesResponse .cancelled == false),
    ("fail → henret 'failed' → jemmet writes a 500",
        st [.spawn 0, .schedule, .fail 0] == some .failed
        && writesResponse .failed == true),
    ("in-flight (running) handler writes nothing yet — loop stays free",
        st [.spawn 0, .schedule] == some .running
        && writesResponse .running == false),
    ("terminal: a late complete after cancel is rejected; task stays cancelled",
        res [.spawn 0, .schedule, .cancel 0, .complete 0] == .invalid
        && st  [.spawn 0, .schedule, .cancel 0, .complete 0] == some .cancelled),
    ("terminal: a late cancel after complete is rejected; task stays completed",
        res [.spawn 0, .schedule, .complete 0, .cancel 0] == .invalid
        && st  [.spawn 0, .schedule, .complete 0, .cancel 0] == some .completed),
    ("deadline timer: sleep parks the handler; a later tick wakes it (ready)",
        st [.spawn 0, .schedule, .sleep 0 5] == some .sleeping
        && st [.spawn 0, .schedule, .sleep 0 5, .tick 10] == some .ready),
    ("spawn/schedule return real henret results (spawned 0, scheduled 0)",
        res [.spawn 0] == .spawned 0 && res [.spawn 0, .schedule] == .scheduled 0) ]

def run : IO (Nat × Nat) := do
  let mut total := 0
  let mut failed := 0
  for (name, ok) in checks do
    total := total + 1
    if ok then IO.println s!"  ok    henret :: {name}"
    else failed := failed + 1; IO.println s!"  FAIL  henret :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} henret handler-handoff binding checks passed"
  if failed == 0 then
    IO.println "RFC 015 handler-handoff over real henret runtime: PASS"
  else
    IO.println s!"RFC 015 handler-handoff over real henret runtime: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Henret
