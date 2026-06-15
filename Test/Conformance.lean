/-
  Test.Conformance — the `Conn` conformance suite (RFC 002 test obligation).

  Exercises the `Conn` *interface* (not `FakeConn` internals) and asserts
  `ConnProgress` correctness — `needsRead`/`needsWrite`/owned counts/`closeState` —
  across the contract-relevant situations: would-block, split reads across `recv`
  boundaries (`ownedInBytes`), partial send + retry, flush draining, graceful vs
  abortive close, and EOF/error mapping. After every operation it also asserts
  `ConnProgress.consistent`.

  The check predicates are instance-agnostic: at M2/M3 the same assertions are
  re-pointed at `PlainIotaktConn` (RFC 008) and `TlsConn` (RFC 009). Only the
  scenario *setup* (scripting bytes) is `FakeConn`-specific.
-/
import Jemmet

namespace Test
open Jemmet

/-! ### Small helpers -/

/-- A named boolean check result. -/
abbrev Check := String × Bool

/-- Build a `ByteArray` from a string (UTF-8). -/
@[inline] def bs (s : String) : ByteArray := s.toUTF8

/-- Byte-array equality by contents. -/
@[inline] def baEq (a b : ByteArray) : Bool := a.toList == b.toList

/-! ### Scenarios (generic over the `Conn` interface; set up via `FakeConn`) -/

/-- `recv` on an empty inbox blocks: `wouldBlock`, read interest armed, no progress. -/
def scenWouldBlockRecv : IO (List Check) := do
  let c := FakeConn.fresh
  let (o, p, _) ← Conn.recv c 16
  pure [
    ("recv-wouldBlock/outcome",   (match o with | .wouldBlock => true | _ => false)),
    ("recv-wouldBlock/needsRead", p.needsRead),
    ("recv-wouldBlock/noProgress", !p.progressMade),
    ("recv-wouldBlock/consistent", p.consistent) ]

/-- A delivered chunk larger than the `recv` cap is split: the remainder is buffered
    and surfaced as `ownedInBytes`, then drained by the next `recv`. -/
def scenSplitRecv : IO (List Check) := do
  let c := (FakeConn.fresh).withInbox [.deliver (bs "HELLO")]
  let (o1, p1, c1) ← Conn.recv c 2
  let (o2, p2, c2) ← Conn.recv c1 16
  let (o3, p3, _)  ← Conn.recv c2 16
  pure [
    ("split/first-bytes",  (match o1 with | .bytes b => baEq b (bs "HE") | _ => false)),
    ("split/owned-after-1", p1.ownedInBytes == 3),
    ("split/consistent-1",  p1.consistent),
    ("split/second-bytes", (match o2 with | .bytes b => baEq b (bs "LLO") | _ => false)),
    ("split/owned-after-2", p2.ownedInBytes == 0),
    ("split/consistent-2",  p2.consistent),
    ("split/then-wouldBlock", (match o3 with | .wouldBlock => true | _ => false)),
    ("split/consistent-3",  p3.consistent) ]

/-- `send` accepts only what the connection currently owns room for; the caller
    retries the unconsumed suffix. `ownedOutBytes` tracks the accepted plaintext. -/
def scenPartialSend : IO (List Check) := do
  let c := (FakeConn.fresh).withWriteQuota [2]
  let (o1, p1, c1) ← Conn.send c (bs "ABCDE")
  let (o2, p2, _)  ← Conn.send c1 (bs "CDE")
  pure [
    ("psend/consumed-2", (match o1 with | .consumed n => n == 2 | _ => false)),
    ("psend/owned-2",     p1.ownedOutBytes == 2),
    ("psend/needsWrite-1", p1.needsWrite),
    ("psend/consistent-1", p1.consistent),
    ("psend/consumed-3", (match o2 with | .consumed n => n == 3 | _ => false)),
    ("psend/owned-5",     p2.ownedOutBytes == 5),
    ("psend/consistent-2", p2.consistent) ]

/-- A zero write quota means `send` blocks with nothing accepted. -/
def scenSendBlocked : IO (List Check) := do
  let c := (FakeConn.fresh).withWriteQuota [0]
  let (o, p, _) ← Conn.send c (bs "AB")
  pure [
    ("sblock/wouldBlock",   (match o with | .wouldBlock => true | _ => false)),
    ("sblock/owned-0",      p.ownedOutBytes == 0),
    ("sblock/noNeedWrite", !p.needsWrite),
    ("sblock/consistent",   p.consistent) ]

/-- `flush` drains owned output toward the sink; a quota smaller than the owned size
    yields `partial`, and write interest drops only when owned output reaches zero. -/
def scenFlush : IO (List Check) := do
  let c := (FakeConn.fresh).withWriteQuota [5, 2]
  let (_,  _,  c1) ← Conn.send c (bs "ABCDE")
  let (f1, p1, c2) ← Conn.flush c1
  let (f2, p2, c3) ← Conn.flush c2
  pure [
    ("flush/partial",      (match f1 with | .«partial» => true | _ => false)),
    ("flush/owned-3",       p1.ownedOutBytes == 3),
    ("flush/needsWrite-1",  p1.needsWrite),
    ("flush/consistent-1",  p1.consistent),
    ("flush/flushed",      (match f2 with | .flushed => true | _ => false)),
    ("flush/owned-0",       p2.ownedOutBytes == 0),
    ("flush/noNeedWrite",  !p2.needsWrite),
    ("flush/consistent-2",  p2.consistent),
    ("flush/sink",          baEq c3.sink (bs "ABCDE")) ]

/-- Graceful close with owned output enters `closing` (still draining), then completes
    to `closed` on the flush that empties the owned buffer; the bytes reach the sink. -/
def scenGracefulClose : IO (List Check) := do
  let c := (FakeConn.fresh).withWriteQuota [3]
  let (_,  _,  c1) ← Conn.send c (bs "XYZ")
  let (pc, c2)     ← Conn.close c1 .graceful
  let (f,  pf, c3) ← Conn.flush c2
  pure [
    ("gclose/closing",     pc.closeState == .closing),
    ("gclose/needsWrite",  pc.needsWrite),
    ("gclose/owned-3",     pc.ownedOutBytes == 3),
    ("gclose/consistent",  pc.consistent),
    ("gclose/flushed",    (match f with | .flushed => true | _ => false)),
    ("gclose/closed",      pf.closeState == .closed),
    ("gclose/quiescent",   pf.consistent && !pf.needsRead && !pf.needsWrite && pf.ownedOutBytes == 0),
    ("gclose/sink",        baEq c3.sink (bs "XYZ")) ]

/-- Abortive close drops owned output and closes immediately; nothing reaches the sink. -/
def scenAbortiveClose : IO (List Check) := do
  let c := (FakeConn.fresh).withWriteQuota [3]
  let (_,  _,  c1) ← Conn.send c (bs "XYZ")
  let (pc, c2)     ← Conn.close c1 .abortive
  pure [
    ("aclose/closed",     pc.closeState == .closed),
    ("aclose/owned-0",    pc.ownedOutBytes == 0),
    ("aclose/quiescent",  pc.consistent && !pc.needsRead && !pc.needsWrite),
    ("aclose/sink-empty", baEq c2.sink ByteArray.empty) ]

/-- Clean EOF maps to `RecvOutcome.eof` and disarms read interest. -/
def scenEof : IO (List Check) := do
  let c := (FakeConn.fresh).withInbox [.eof]
  let (o, p, _) ← Conn.recv c 16
  pure [
    ("eof/outcome",    (match o with | .eof => true | _ => false)),
    ("eof/noNeedRead", !p.needsRead),
    ("eof/consistent",  p.consistent) ]

/-- A scripted transport error maps through to `RecvOutcome.error`. -/
def scenError : IO (List Check) := do
  let c := (FakeConn.fresh).withInbox [.error (.transport "boom")]
  let (o, p, _) ← Conn.recv c 16
  pure [
    ("err/outcome",   (match o with | .error e => e == .transport "boom" | _ => false)),
    ("err/consistent", p.consistent) ]

/-- All scenarios, named. -/
def scenarios : List (String × IO (List Check)) := [
  ("recv wouldBlock",   scenWouldBlockRecv),
  ("split recv",        scenSplitRecv),
  ("partial send",      scenPartialSend),
  ("send blocked",      scenSendBlocked),
  ("flush draining",    scenFlush),
  ("graceful close",    scenGracefulClose),
  ("abortive close",    scenAbortiveClose),
  ("eof mapping",       scenEof),
  ("error mapping",     scenError) ]

/-- Run every scenario, print results, and return an exit code (0 = all pass). -/
def runAll : IO UInt32 := do
  let mut total := 0
  let mut failed := 0
  for (name, scen) in scenarios do
    let checks ← scen
    for (cname, ok) in checks do
      total := total + 1
      if ok then
        IO.println s!"  ok    {name} :: {cname}"
      else
        failed := failed + 1
        IO.println s!"  FAIL  {name} :: {cname}"
  IO.println ""
  IO.println s!"{total - failed}/{total} checks passed across {scenarios.length} scenarios"
  if failed == 0 then
    IO.println "RFC 002 Conn conformance: PASS"
    pure 0
  else
    IO.println s!"RFC 002 Conn conformance: FAIL ({failed} failed)"
    pure 1

end Test
