/-
  Test.LifecycleConformance — production lifecycle (RFC 016).

  The graceful-shutdown state machine and the resource-leak audit, plus the driver wiring
  (`requestShutdown`, the accept gate, the bounded-drain force-close in `sweepTimeouts`).
-/
import Jemmet
import Jemmet.Iotakt
import Test.IotaktConformance

namespace Test.Lifecycle
open Jemmet
open Jemmet.Iotakt

abbrev Check := String × Bool

def mk0 : FdKey := ⟨0, 0⟩
def mk1 : FdKey := ⟨1, 0⟩
def mk2 : FdKey := ⟨2, 0⟩

/-! ### The lifecycle state machine (the proven contract, exercised) -/

def modelChecks : List Check :=
  [ ("accept while running adds the connection",
       (stepLifecycle {} (.accept mk0)).live.length == 1),
    ("accept while draining is refused (live unchanged)",
       (stepLifecycle { phase := .draining 10 } (.accept mk0)).live.length == 0),
    ("shutdown while running begins the drain",
       (stepLifecycle {} (.shutdown 10)).phase == .draining 10),
    ("shutdown is idempotent once draining",
       (stepLifecycle { phase := .draining 10 } (.shutdown 99)).phase == .draining 10),
    ("drain is force-closed at the deadline (phase stopped, no live conns)",
       let s : ServerState := { phase := .draining 10, live := [mk0, mk1] }
       (stepLifecycle s (.tick 10)).phase == .stopped && (stepLifecycle s (.tick 10)).live.isEmpty),
    ("drain stops cleanly once empty before the deadline",
       (stepLifecycle { phase := .draining 10 } (.tick 5)).phase == .stopped),
    ("stopped absorbs every later event",
       let s : ServerState := { phase := .stopped }
       (stepLifecycle s (.accept mk0)).phase == .stopped
         && (stepLifecycle s (.tick 99)).phase == .stopped
         && (stepLifecycle s (.shutdown 1)).phase == .stopped),
    ("once shutdown, a later accept never grows the live set",
       let final := ([LifecycleEvent.accept mk0, .accept mk1, .shutdown 10, .accept mk2]).foldl stepLifecycle {}
       final.live.length == 2 && final.phase == .draining 10),
    ("leak audit: a forced stop reports clean (no leaked resources)",
       (stepLifecycle { phase := .draining 10, live := [mk0] } (.tick 10)).audit.clean == true),
    ("leak audit: a still-live draining server reports a leak",
       (({ phase := .draining 10, live := [mk0] } : ServerState).leaked) == true) ]

/-! ### Driver wiring (`requestShutdown`, accept gate, bounded drain) -/

abbrev IK := Iotakt.Model.FdKey
def ik0 : IK := ⟨0, 0⟩
def ik1 : IK := ⟨1, 0⟩

def baseDriver : ServeDriver Test.Iotakt.ModelLoop := Test.Iotakt.mkDriver { inbox := [] }

/-- A draining driver with two live connections at deadline 10. -/
def drainingDriver : ServeDriver Test.Iotakt.ModelLoop :=
  let d := { baseDriver with phase := .draining 10, drainDeadline := 10 }
  let d := d.setConn ik0 { key := ik0, meta := (PlainIotaktConn.fresh d.ops d.loop ik0).meta }
  d.setConn ik1 { key := ik1, meta := (PlainIotaktConn.fresh d.ops d.loop ik1).meta }

def driverChecks : List Check :=
  let afterShutdown := baseDriver.requestShutdown 10
  let idempotent    := afterShutdown.requestShutdown 99
  let forced        := drainingDriver.sweepTimeouts 20      -- now 20 ≥ deadline 10 → force close
  let cleanDrain    := ({ baseDriver with phase := .draining 10 } : ServeDriver _).sweepTimeouts 5
  [ ("requestShutdown moves a running driver to draining with a deadline",
       afterShutdown.phase == .draining 10),
    ("requestShutdown is idempotent (a second signal keeps the first deadline)",
       idempotent.phase == .draining 10),
    ("draining driver no longer accepts new connections (phase gates accept)",
       afterShutdown.phase.acceptsNew == false),
    ("draining driver does not start a new keep-alive request",
       afterShutdown.phase.admitsKeepAlive == false),
    ("bounded drain force-closes the remainder at the deadline",
       forced.conns.isEmpty && forced.phase == .stopped && forced.closedKeys.length == 2),
    ("a drain with no live connections stops cleanly",
       cleanDrain.phase == .stopped),
    ("a running driver still accepts (default phase unchanged)",
       baseDriver.phase.acceptsNew == true) ]

def run : IO (Nat × Nat) := do
  let all := modelChecks ++ driverChecks
  let mut failed := 0
  for (name, ok) in all do
    if ok then IO.println s!"  ok    lifecycle :: {name}"
    else failed := failed + 1; IO.println s!"  FAIL  lifecycle :: {name}"
  IO.println ""
  IO.println s!"{all.length - failed}/{all.length} production-lifecycle checks passed"
  if failed == 0 then
    IO.println "RFC 016 graceful-shutdown + leak-audit conformance: PASS"
  else
    IO.println s!"RFC 016 graceful-shutdown + leak-audit conformance: FAIL ({failed} failed)"
  pure (failed, all.length)

end Test.Lifecycle
