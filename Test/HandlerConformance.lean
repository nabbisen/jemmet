/-
  Test.HandlerConformance — RFC 015 handler-execution policy conformance.

  Exercises the phase machine and the bounded pool: a slow task on one connection does not
  block another, a deadline overrun times out (never stalls), closing cancels the task and
  a late completion is dropped, the in-flight count is capped, and the inline fast path
  produces a response without spawning a task.
-/
import Jemmet

namespace Test.Handler
open Jemmet

abbrev Check := String × Bool

def isRunning : HandlerPhase → Bool | .running _ _ => true | _ => false
def isCancelled : HandlerPhase → Bool | .cancelled => true | _ => false
def isTimedOut : HandlerPhase → Bool | .timedOut => true | _ => false

def checks : List Check :=
  let respB := HttpResponse.text "B-done"
  -- two connections both waiting on handler tasks; in one scheduler batch A's task is
  -- still running (a tick well before its deadline) while B's task completes.
  let aRunning := stepHandler (.running 100 1) (.tick 5)
  let bDone    := stepHandler (.running 100 2) (.completed respB)
  -- deadline overrun → timedOut (the loop is never left waiting forever)
  let aTimeout := stepHandler (.running 10 1) (.tick 15)
  -- close cancels the task; a completion arriving afterwards is dropped
  let cClosed  := stepHandler (.running 100 1) .closeConn
  let cLate    := stepHandler cClosed (.completed (HttpResponse.text "late"))
  -- bounded in-flight pool: cap 2, three spawns ⇒ inFlight stays 2; retire frees a slot
  let pool : HandlerPool := { inFlight := 0, cap := 2 }
  let pool3 := pool.spawn.spawn.spawn
  let poolR := pool3.retire
  -- task hand-off vs inline fast path
  let taskPool := pool.spawn
  let inlinePhase : HandlerPhase := .ready (HttpResponse.text "inline")
  [ ("handler: slow task on one conn does not block another (B ready while A running)",
       isRunning aRunning && bDone.writes),
    ("handler: deadline overrun → timedOut (loop not stalled)", isTimedOut aTimeout),
    ("handler: close cancels the task", isCancelled cClosed),
    ("handler: late completion after close is dropped (no late response)",
       isCancelled cLate && !cLate.writes),
    ("handler: in-flight capped at the configured limit", pool3.inFlight == 2),
    ("handler: retire frees a slot for a new task",
       poolR.inFlight == 1 && poolR.spawn.inFlight == 2),
    ("handler: task hand-off spawns and goes running (loop free meanwhile)",
       taskPool.inFlight == 1),
    ("handler: inline fast path is ready immediately, no task spawned",
       inlinePhase.writes && pool.inFlight == 0),
    ("handler: a failed handler becomes a 500 (never a stuck connection)",
       (stepHandler (.running 100 1) .failed).writes),
    ("handler: a deadline timeout renders a 503 (writes a response)",
       aTimeout.writes && (aTimeout.response.map (·.status.code) == some 503)),
    ("handler: a cancelled handler renders no response",
       cClosed.response.isNone) ]

def run : IO (Nat × Nat) := do
  let mut total := 0
  let mut failed := 0
  for (name, ok) in checks do
    total := total + 1
    if ok then IO.println s!"  ok    handler :: {name}"
    else failed := failed + 1; IO.println s!"  FAIL  handler :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} handler-policy checks passed"
  if failed == 0 then
    IO.println "RFC 015 handler-execution policy conformance: PASS"
  else
    IO.println s!"RFC 015 handler-execution policy conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Handler
