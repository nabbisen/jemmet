/-
  Test.EventConformance — the RFC 014 adversarial event-trace suite (the M1.5
  checkpoint). The deterministic fake event-trace runner (`runTrace`) replays hostile
  henret/iotakt sequences and we assert the event-semantics contract: stale events
  dropped, readiness coalesced, batch ordering (newConnection → I/O → tick), close-then-
  reuse-fd via generation, partial-write re-arm, and idle-timeout close.
-/
import Jemmet

namespace Test.Event
open Jemmet

abbrev Check := String × Bool

def cfg : DriverConfig := {}
def runT (trace : List (List LoopEvent)) : DriverState := runTrace cfg trace DriverState.init

def k0 : FdKey := { raw := 5, gen := 0 }
def k1 : FdKey := { raw := 5, gen := 1 }    -- reused raw fd, new generation

def stepOf (s : DriverState) (key : FdKey) : Nat := ((s.find? key).map (·.stepCount)).getD 0
def pendOf (s : DriverState) (key : FdKey) : Nat := ((s.find? key).map (·.pendingOut)).getD 0
def nwOf   (s : DriverState) (key : FdKey) : Bool := ((s.find? key).map (·.needsWrite)).getD false

-- adversarial traces
def sStale      := runT [[.dataReady k0 .readable]]
def sCoalesce   := runT [[.newConnection k0], [.dataReady k0 .readable, .dataReady k0 .readable]]
def sBatch      := runT [[.newConnection k0], [.dataReady k0 .readable, .dataReady k0 .writable, .tick 5]]
def sReuse      := runT [[.newConnection k0], [.dataReady k0 .eof], [.newConnection k1]]
def sReuseStale := runT [[.newConnection k0], [.dataReady k0 .eof], [.newConnection k1], [.dataReady k0 .readable]]
def sDrain      := runT [[.newConnection k0], [.dataReady k0 .readable], [.dataReady k0 .writable]]
def sTimeout    := runT [[.newConnection k0], [.tick 100]]
def sOrder      := runT [[.dataReady k0 .readable, .newConnection k0]]
def sPipe       := runT [[.newConnection k0], [.dataReady k0 .readable], [.dataReady k0 .readable]]

def checks : List Check :=
  [ ("stale dataReady dropped (counter), no conn created",
      sStale.droppedStale == 1 && !sStale.isLive k0),
    ("coalesced readiness in a batch → exactly one step",
      stepOf sCoalesce k0 == 1),
    ("ordering: I/O coalesced before tick, conn survives",
      stepOf sBatch k0 == 1 && pendOf sBatch k0 == 1 && sBatch.isLive k0),
    ("close then reuse raw fd: old generation dead, new live",
      !sReuse.isLive k0 && sReuse.isLive k1),
    ("stale event for reused-fd old generation dropped",
      sReuseStale.droppedStale == 1 && sReuseStale.isLive k1),
    ("partial write re-arm: drained ⇒ write interest off",
      pendOf sDrain k0 == 0 && nwOf sDrain k0 == false),
    ("idle timeout on tick → connection closed",
      !sTimeout.isLive k0),
    ("batch ordering: newConnection before same-batch dataReady",
      sOrder.isLive k0 && stepOf sOrder k0 == 1),
    ("pipelined steps across batches both advance",
      stepOf sPipe k0 == 2) ]

def run : IO (Nat × Nat) := do
  let mut total := 0
  let mut failed := 0
  for (name, ok) in checks do
    total := total + 1
    if ok then
      IO.println s!"  ok    event :: {name}"
    else
      failed := failed + 1
      IO.println s!"  FAIL  event :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} event-semantics checks passed"
  if failed == 0 then
    IO.println "RFC 014 driver event-semantics (M1.5 checkpoint) conformance: PASS"
  else
    IO.println s!"RFC 014 driver event-semantics conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Event
