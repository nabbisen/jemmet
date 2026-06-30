/-
  Test.IotaktConformance — RFC 008 transport-binding conformance.

  A deterministic *model* iotakt loop (`ModelLoop`) drives `PlainIotaktConn` through the
  `Conn` typeclass, so the binding's behaviour is verified in-sandbox without the native
  epoll backend: per-record ack discipline (readable across records), partial-write
  re-arm with the write-interest invariant, two-connection FdKey demultiplexing, and the
  ReadResult/WriteResult/IoErrno → RecvOutcome/SendOutcome/ConnError mapping.
  `ConnProgress.consistent` is asserted after operations (the RFC 002 obligation).
-/
import Jemmet.Iotakt

namespace Test.Iotakt
open Jemmet
open Jemmet.Iotakt

abbrev IKey := Iotakt.Model.FdKey

-- assoc-list helpers keyed by iotakt FdKey (DecidableEq; iotakt FdKey has no BEq)
def lookupK {α} (l : List (IKey × α)) (key : IKey) : Option α :=
  (l.find? (fun p => decide (p.1 = key))).map (·.2)
def setK {α} (l : List (IKey × α)) (key : IKey) (v : α) : List (IKey × α) :=
  (key, v) :: l.filter (fun p => decide (p.1 ≠ key))

/-- A scriptable model of iotakt's loop: per-key recv scripts, per-key send sinks, a
    write quota (to force partial writes), and write-interest / closed sets. -/
structure ModelLoop where
  inbox      : List (IKey × List Iotakt.Model.ReadResult)
  sink       : List (IKey × ByteArray) := []
  writeQuota : Nat := 1000000
  writeArmed : List IKey := []
  closed     : List IKey := []

def modelOps : IotaktLoopOps ModelLoop where
  recvAck ml key _max := do
    match lookupK ml.inbox key with
    | some (r :: rest) => pure ({ ml with inbox := setK ml.inbox key rest }, r)
    | _                => pure (ml, .wouldBlock)
  sendAck ml key ba off len := do
    let m := min ml.writeQuota len
    let chunk := ba.extract off (off + m)
    let cur := (lookupK ml.sink key).getD ByteArray.empty
    pure ({ ml with sink := setK ml.sink key (cur ++ chunk) }, .wrote (USize.ofNat m))
  enableWrite ml key  := pure { ml with writeArmed := key :: ml.writeArmed.filter (fun k => decide (k ≠ key)) }
  disableWrite ml key := pure { ml with writeArmed := ml.writeArmed.filter (fun k => decide (k ≠ key)) }
  closeConn ml key    := pure { ml with closed := key :: ml.closed }

def k0 : IKey := { raw := 7, gen := 0 }
def k1 : IKey := { raw := 9, gen := 0 }

def bytesEq (b : ByteArray) (s : String) : Bool := b.toList == s.toUTF8.toList

abbrev Check := String × Bool

/-! ### Scenario 1 — readable across records (per-record ack discipline) -/
def scenarioAck : IO (List Check) := do
  let ml : ModelLoop := { inbox := [(k0, [.bytes "REQ1".toUTF8, .bytes "REQ2".toUTF8, .eof])] }
  let c := PlainIotaktConn.fresh modelOps ml k0
  let (o1, p1, c) ← Conn.recv c 64
  let (o2, p2, c) ← Conn.recv c 64
  let (o3, p3, _) ← Conn.recv c 64
  let r1 := match o1 with | .bytes b => bytesEq b "REQ1" | _ => false
  let r2 := match o2 with | .bytes b => bytesEq b "REQ2" | _ => false
  let r3 := match o3 with | .eof => true | _ => false
  pure [ ("ack: first record delivered", r1),
         ("ack: second record delivered after ack", r2),
         ("ack: clean EOF maps to RecvOutcome.eof", r3),
         ("ack: progress consistent", p1.consistent && p2.consistent && p3.consistent),
         ("ack: read interest armed while open", p1.needsRead) ]

/-! ### Scenario 2 — partial write + re-arm (write-interest invariant) -/
def scenarioPartial : IO (List Check) := do
  let ml : ModelLoop := { inbox := [], writeQuota := 3 }
  let c := PlainIotaktConn.fresh modelOps ml k0
  let (so, ps, c) ← Conn.send c "ABCDEFG".toUTF8                 -- consume 7 into outBuf
  let consumed7 := match so with | .consumed n => n == 7 | _ => false
  let (f1, pf1, c) ← Conn.flush c                                 -- write 3 → partial
  let (f2, pf2, c) ← Conn.flush c                                 -- write 3 → partial
  let (f3, pf3, c) ← Conn.flush c                                 -- write 1 → flushed
  let part1 := match f1 with | .«partial» => true | _ => false
  let part2 := match f2 with | .«partial» => true | _ => false
  let done  := match f3 with | .flushed => true | _ => false
  let sinkOk := (lookupK c.loop.sink k0).map (bytesEq · "ABCDEFG") |>.getD false
  let armedDuring := pf1.needsWrite && pf2.needsWrite          -- interest held across partials
  let clearedEnd  := !pf3.needsWrite && !(c.loop.writeArmed.any (fun k => decide (k = k0)))
  pure [ ("partial: send consumes full plaintext (owns it)", consumed7),
         ("partial: send arms write interest", ps.needsWrite && ps.ownedOutBytes == 7),
         ("partial: first flush is partial", part1),
         ("partial: second flush is partial", part2),
         ("partial: final flush fully drains", done),
         ("partial: all bytes reach the socket in order", sinkOk),
         ("partial: write interest held across partials", armedDuring),
         ("partial: write interest cleared once drained (invariant)", clearedEnd),
         ("partial: every progress consistent",
           ps.consistent && pf1.consistent && pf2.consistent && pf3.consistent) ]

/-! ### Scenario 3 — two concurrent connections (FdKey demultiplexing) -/
def scenarioDemux : IO (List Check) := do
  let ml : ModelLoop :=
    { inbox := [(k0, [.bytes "AAA".toUTF8]), (k1, [.bytes "BBB".toUTF8])] }
  let c0 := PlainIotaktConn.fresh modelOps ml k0
  let (o0, _, c0) ← Conn.recv c0 64
  -- carry the shared loop forward to the second connection (as the driver would)
  let c1 := PlainIotaktConn.fresh modelOps c0.loop k1
  let (o1, _, c1) ← Conn.recv c1 64
  let (_, _, c0) ← Conn.send { c0 with loop := c1.loop } "X0".toUTF8
  let (_, _, c0) ← Conn.flush c0
  let (_, _, c1) ← Conn.send { c1 with loop := c0.loop } "Y1".toUTF8
  let (_, _, c1) ← Conn.flush c1
  let recv0 := match o0 with | .bytes b => bytesEq b "AAA" | _ => false
  let recv1 := match o1 with | .bytes b => bytesEq b "BBB" | _ => false
  let sink0 := (lookupK c1.loop.sink k0).map (bytesEq · "X0") |>.getD false
  let sink1 := (lookupK c1.loop.sink k1).map (bytesEq · "Y1") |>.getD false
  pure [ ("demux: conn k0 reads only its bytes", recv0),
         ("demux: conn k1 reads only its bytes", recv1),
         ("demux: conn k0 output keyed to k0 sink", sink0),
         ("demux: conn k1 output keyed to k1 sink", sink1),
         ("demux: meta.fd refines the iotakt key", c0.meta.fd == ofIotaktKey k0) ]

/-! ### Scenario 4 — error / EOF mapping and close -/
def scenarioMapping : IO (List Check) := do
  let ml : ModelLoop :=
    { inbox := [(k0, [.error .connectionReset]), (k1, [.error (.other 13)])] }
  let cR := PlainIotaktConn.fresh modelOps ml k0
  let (oR, _, _) ← Conn.recv cR 64
  let cO := PlainIotaktConn.fresh modelOps ml k1
  let (oO, _, _) ← Conn.recv cO 64
  let reset := match oR with | .error .reset => true | _ => false
  let other := match oO with | .error (.transport _) => true | _ => false
  -- close → quiescent, registration dropped
  let cC := PlainIotaktConn.fresh modelOps ml k0
  let (_, _, cC) ← Conn.send cC "pending".toUTF8
  let (pc, cC) ← Conn.close cC .abortive
  let quiescent := pc.consistent && pc.closeState == .closed
                   && !pc.needsRead && !pc.needsWrite && pc.ownedOutBytes == 0
  let dropped := cC.loop.closed.any (fun k => decide (k = k0))
  pure [ ("map: connectionReset → ConnError.reset", reset),
         ("map: other errno → ConnError.transport", other),
         ("close: abortive close is quiescent (consistent)", quiescent),
         ("close: registration dropped via closeConnection", dropped) ]

/-! ### Scenario 5 — end-to-end HTTP served over the iotakt binding -/
def asStr (b : ByteArray) : String := Jemmet.asciiString b
def hasSub (s sub : String) : Bool := (s.splitOn sub).length ≥ 2
def countSub (s sub : String) : Nat := (s.splitOn sub).length - 1
def sinkStr (ml : ModelLoop) (key : IKey) : String :=
  asStr ((lookupK ml.sink key).getD ByteArray.empty)

def hAAA : Handler := fun _ => pure (HttpResponse.text "AAA")
def hBBB : Handler := fun _ => pure (HttpResponse.text "BBB")
def hUser : Handler := fun _ => pure (HttpResponse.text "userpage")
def srvRouter : Router := { routes :=
  [ { method := .get, pattern := [.static "a"],                 handler := hAAA },
    { method := .get, pattern := [.static "b"],                 handler := hBBB },
    { method := .get, pattern := [.static "users", .param "id"], handler := hUser } ] }

def rawReq (path : String) (hdrs : String := "") : ByteArray :=
  (s!"GET {path} HTTP/1.1\r\nHost: t\r\n{hdrs}\r\n").toUTF8

def scenarioServe : IO (List Check) := do
  -- two independent connections, one request each, served on one driver
  let ml2 : ModelLoop := { inbox := [(k0, [.bytes (rawReq "/a"), .eof]),
                                      (k1, [.bytes (rawReq "/b"), .eof])] }
  let σ2 ← runServer modelOps ml2 srvRouter {} [k0, k1]
  let s0 := sinkStr σ2 k0
  let s1 := sinkStr σ2 k1
  -- a pipelined pair on one keep-alive connection (second request closes)
  let mlP : ModelLoop :=
    { inbox := [(k0, [.bytes (rawReq "/a" ++ rawReq "/b" "Connection: close\r\n"), .eof])] }
  let σP ← runServer modelOps mlP srvRouter {} [k0]
  let sp := sinkStr σP k0
  -- a routed param request
  let mlU : ModelLoop := { inbox := [(k0, [.bytes (rawReq "/users/42"), .eof])] }
  let σU ← runServer modelOps mlU srvRouter {} [k0]
  let su := sinkStr σU k0
  pure [ ("serve: GET /a → HTTP/1.1 200 with body AAA", hasSub s0 "HTTP/1.1 200" && hasSub s0 "AAA"),
         ("serve: GET /b → HTTP/1.1 200 with body BBB", hasSub s1 "HTTP/1.1 200" && hasSub s1 "BBB"),
         ("serve: responses demuxed to the right connection", !hasSub s0 "BBB" && !hasSub s1 "AAA"),
         ("serve: pipelined pair → two responses on one conn", countSub sp "HTTP/1.1 200" == 2),
         ("serve: pipelined bodies AAA then BBB", hasSub sp "AAA" && hasSub sp "BBB"),
         ("serve: :param route GET /users/42 → 200 userpage", hasSub su "HTTP/1.1 200" && hasSub su "userpage") ]

/-! ### Scenario 6 — phase-indexed interleaving driver (RFC 014 §3 fairness) -/
def mkDriver (ml : ModelLoop) : ServeDriver ModelLoop :=
  { ops := modelOps, loop := ml, router := srvRouter }

def scenarioDriver : IO (List Check) := do
  let reqA := rawReq "/a"
  let reqB := rawReq "/b"
  -- split reqA so k0 needs two batches to complete (slow peer); k1 completes in one (fast)
  let aHalf1 := reqA.extract 0 (reqA.size - 1)
  let aHalf2 := reqA.extract (reqA.size - 1) reqA.size
  let ml : ModelLoop := { inbox := [ (k0, [.bytes aHalf1, .bytes aHalf2, .eof]),
                                     (k1, [.bytes reqB, .eof]) ] }
  -- batch 1: accept both, both readable — one bounded step each
  let d1 ← (mkDriver ml).dispatchBatch [.accept k0, .accept k1, .readable k0, .readable k1]
  let s0_b1 := sinkStr d1.loop k0      -- empty: k0 still accumulating its request
  let s1_b1 := sinkStr d1.loop k1      -- BBB: k1 served, not blocked behind slow k0
  -- batch 2: k0 completes
  let d2 ← d1.dispatchBatch [.readable k0, .readable k1]
  let s0_b2 := sinkStr d2.loop k0
  let s1_b2 := sinkStr d2.loop k1
  -- coalescing: two readable for one key in a batch ⇒ a single bounded step
  let dC ← (mkDriver { inbox := [(k0, [.bytes reqA, .bytes reqA, .eof])] }).dispatchBatch
             [.accept k0, .readable k0, .readable k0]
  let stepsC := ((dC.findConn k0).map (·.steps)).getD 99
  -- stale: readable for a never-accepted key is dropped with a counter
  let dS ← (mkDriver ml).dispatchBatch [.readable k1]
  -- ordering: accept is processed before a same-batch readable that appears earlier
  let dO ← (mkDriver { inbox := [(k0, [.bytes reqA, .eof])] }).dispatchBatch [.readable k0, .accept k0]
  pure [ ("driver: fast conn served despite slow peer (no starvation)",
            hasSub s1_b1 "BBB" && !hasSub s0_b1 "AAA"),
         ("driver: slow conn completes on a later batch", hasSub s0_b2 "AAA"),
         ("driver: both connections finish (interleaved, not serial)",
            hasSub s0_b2 "AAA" && hasSub s1_b2 "BBB"),
         ("driver: coalesced readiness → one bounded step per batch", stepsC == 1),
         ("driver: event for unknown key dropped (stale counter)", dS.droppedStale == 1),
         ("driver: accept ordered before same-batch readable", hasSub (sinkStr dO.loop k0) "AAA") ]

/-! ### Scenario 7 — egress boundedness under a non-draining reader (RFC 010) -/
def scenarioEgress : IO (List Check) := do
  let reqA := rawReq "/a"
  let flood : List Iotakt.Model.ReadResult :=
    List.replicate 30 (.bytes reqA) ++ [.eof]
  let batches : List (List DriverEvent) := List.replicate 30 [DriverEvent.readable k0]
  -- slow reader: writeQuota 0 ⇒ flush never drains; small egress cap forces backpressure
  let dSlow0 : ServeDriver ModelLoop :=
    { ops := modelOps, loop := { inbox := [(k0, flood)], writeQuota := 0 },
      router := srvRouter, maxOwnedOut := 250 }
  let dSlow ← dSlow0.dispatchBatch [.accept k0]
  let dSlow ← dSlow.run batches
  let outBufSlow := ((dSlow.findConn k0).map (·.outBuf.size)).getD 0
  let stepsSlow := ((dSlow.findConn k0).map (·.steps)).getD 0
  -- draining reader: same flood + cap, but flushes freely ⇒ served fully
  let dFast0 : ServeDriver ModelLoop :=
    { ops := modelOps, loop := { inbox := [(k0, flood)], writeQuota := 100000 },
      router := srvRouter, maxOwnedOut := 250 }
  let dFast ← dFast0.dispatchBatch [.accept k0]
  let dFast ← dFast.run batches
  let sinkFast := ((lookupK dFast.loop.sink k0).map (·.size)).getD 0
  pure [ ("egress: owned output bounded under a non-draining reader (≤ cap + one response)",
            outBufSlow ≤ 250 + 300),
         ("egress: owned output does NOT grow with request count (backpressure caps it)",
            outBufSlow < 1000),
         ("egress: backpressure stops producing once at cap (few steps, not 30)",
            stepsSlow ≤ 4),
         ("egress: a draining reader is served fully (all responses delivered)",
            sinkFast > 1000) ]

/-! ### Scenario 8 — ingress read timeout (slowloris defense, RFC 010) -/

def mkDriverT (ml : ModelLoop) (readTimeout idleTimeout : Nat) : ServeDriver ModelLoop :=
  { ops := modelOps, loop := ml, router := srvRouter, readTimeout, idleTimeout }

def scenarioReadTimeout : IO (List Check) := do
  let complete := rawReq "/a"                                  -- a full request
  let partialReq  := complete.extract 0 (complete.size - 4)        -- head without the final CRLF CRLF
  -- A: a partialReq request that never completes, swept past the read deadline → closed
  let dA0 ← (mkDriverT { inbox := [(k0, [.bytes partialReq])] } 10 1000).dispatchBatch [.accept k0, .readable k0]
  let dA  ← dA0.dispatchBatch [.timeout 50]
  -- B: a completed request leaves nothing buffered → not read-timed-out (the clock reset)
  let dB0 ← (mkDriverT { inbox := [(k0, [.bytes complete])] } 10 1000).dispatchBatch [.accept k0, .readable k0]
  let dB  ← dB0.dispatchBatch [.timeout 50]
  -- C: a partialReq request still within the read deadline survives
  let dC0 ← (mkDriverT { inbox := [(k0, [.bytes partialReq])] } 10 1000).dispatchBatch [.accept k0, .readable k0]
  let dC  ← dC0.dispatchBatch [.timeout 5]
  -- D: an idle keep-alive connection (no partialReq) still idle-times-out on its own basis
  let dD0 ← (mkDriverT { inbox := [(k0, [.bytes complete])] } 10 100).dispatchBatch [.accept k0, .readable k0]
  let dD  ← dD0.dispatchBatch [.timeout 500]
  pure [ ("read-timeout: partial request past deadline is closed (ingress slowloris)",
            !dA.isLive k0 && dA.closedKeys.any (fun k => decide (k = k0))),
         ("read-timeout: completed request is not read-timed-out (clock reset on completion)",
            dB.isLive k0),
         ("read-timeout: partial request within the deadline survives", dC.isLive k0),
         ("read-timeout: idle keep-alive still idle-times-out (separate basis)", !dD.isLive k0) ]

def run : IO (Nat × Nat) := do
  let groups := [ ("readable-across-records (ack)", ← scenarioAck),
                  ("partial-write re-arm", ← scenarioPartial),
                  ("two-connection demux", ← scenarioDemux),
                  ("error/EOF mapping + close", ← scenarioMapping),
                  ("end-to-end serve over iotakt", ← scenarioServe),
                  ("interleaving driver (fairness)", ← scenarioDriver),
                  ("egress boundedness (RFC 010)", ← scenarioEgress),
                  ("ingress read timeout (slowloris)", ← scenarioReadTimeout) ]
  let mut total := 0
  let mut failed := 0
  for (gname, checks) in groups do
    for (name, ok) in checks do
      total := total + 1
      if ok then
        IO.println s!"  ok    iotakt [{gname}] :: {name}"
      else
        failed := failed + 1
        IO.println s!"  FAIL  iotakt [{gname}] :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} iotakt-binding checks passed across {groups.length} scenarios"
  if failed == 0 then
    IO.println "RFC 008 PlainIotaktConn transport-binding conformance: PASS"
  else
    IO.println s!"RFC 008 PlainIotaktConn transport-binding conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Iotakt
