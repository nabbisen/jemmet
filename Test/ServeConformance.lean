/-
  Test.ServeConformance — RFC 007 serve-loop driver over the `Conn` abstraction, driven
  deterministically through `FakeConn` (no sockets): pipelined keep-alive, the
  Connection-header policy, routing through the driver, and a request split across reads
  reassembled via the carried remainder.
-/
import Jemmet

namespace Test.Serve
open Jemmet

abbrev Check := String × Bool

def asStr (b : ByteArray) : String := Jemmet.asciiString b
def hasSub (s sub : String) : Bool := (s.splitOn sub).length ≥ 2
def countSub (s sub : String) : Nat := (s.splitOn sub).length - 1

def dummyH : Handler := fun _ => pure (HttpResponse.text "hi")
def router : Router := { routes := [ { method := .get, pattern := [.static "hello"], handler := dummyH } ] }

/-- Drive a fresh FakeConn with a scripted inbox and return what the peer would see. -/
def runSink (steps : List RecvStep) : IO String := do
  let c := FakeConn.fresh.withInbox steps
  let c' ← serveConn router {} c
  pure (asStr c'.sink)

def b (s : String) : ByteArray := s.toUTF8

def run : IO (Nat × Nat) := do
  let sPipe ← runSink
    [ .deliver (b "GET /hello HTTP/1.1\r\nHost: x\r\n\r\nGET /hello HTTP/1.1\r\nHost: x\r\n\r\n"), .eof ]
  let sClose ← runSink
    [ .deliver (b "GET /hello HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"), .eof ]
  let s404 ← runSink
    [ .deliver (b "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n"), .eof ]
  let sSplit ← runSink
    [ .deliver (b "GET /hel"), .wouldBlock, .deliver (b "lo HTTP/1.1\r\nHost: x\r\n\r\n"), .eof ]
  let s10 ← runSink
    [ .deliver (b "GET /hello HTTP/1.0\r\nHost: x\r\n\r\n"), .eof ]

  let checks : List Check :=
    [ ("pipelined: two in-order 200 responses",  countSub sPipe "HTTP/1.1 200 OK" == 2),
      ("pipelined: keep-alive Connection emitted", hasSub sPipe "connection: keep-alive"),
      ("Connection: close honored",                hasSub sClose "connection: close"),
      ("404 routed through the driver",            hasSub s404 "HTTP/1.1 404"),
      ("request split across reads reassembles",   (countSub sSplit "HTTP/1.1 200 OK" == 1)),
      ("HTTP/1.0 defaults to close",               hasSub s10 "connection: close") ]

  let mut total := 0
  let mut failed := 0
  for (name, ok) in checks do
    total := total + 1
    if ok then
      IO.println s!"  ok    serve :: {name}"
    else
      failed := failed + 1
      IO.println s!"  FAIL  serve :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} serve-loop checks passed"
  if failed == 0 then
    IO.println "RFC 007 serve-loop (keep-alive/pipelining/close) conformance: PASS"
  else
    IO.println s!"RFC 007 serve-loop conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Serve
