/-
  Test.LimitConformance — the RFC 010 limit/status matrix.

  Each configured limit is exercised at its boundary: an over-limit input must be rejected
  with the documented status, and an at/under-limit input must parse. This is the
  exhaustive companion to the proven `LimitStatus` mapping — it checks the limits actually
  fire (and only fire) where they should, with the right code.
-/
import Jemmet

namespace Test.Limit
open Jemmet

abbrev Check := String × Bool
def b (s : String) : ByteArray := s.toUTF8

/-- The status code a request rejects with, if it rejects. -/
def rejectStatus (input : ByteArray) (lim : Limits) : Option Nat :=
  match parseRequest (Reader.ofBytes input) lim with
  | .reject e => some e.statusCode
  | _         => none

/-- Whether a request parses to completion. -/
def parses (input : ByteArray) (lim : Limits) : Bool :=
  match parseRequest (Reader.ofBytes input) lim with
  | .parsed _ _ => true
  | _           => false

def checks : List Check :=
  [ -- request-line length → 414 URI Too Long
    ("request-line over limit → 414",
       rejectStatus (b "GET /aaaaaaaaaaaaaaaaaaaaaaaa HTTP/1.1\r\nHost: x\r\n\r\n") {maxRequestLineBytes := 16} == some 414),
    ("request-line within limit parses",
       parses (b "GET / HTTP/1.1\r\nHost: x\r\n\r\n") {}),
    -- header line length → 431
    ("header line over limit → 431",
       rejectStatus (b "GET / HTTP/1.1\r\nX-Long: vvvvvvvvvvvv\r\n\r\n") {maxHeaderLineBytes := 8} == some 431),
    -- header count → 431
    ("header count over limit → 431",
       rejectStatus (b "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n") {maxHeaderCount := 2} == some 431),
    ("header count at limit parses",
       parses (b "GET / HTTP/1.1\r\nHost: x\r\nA: 1\r\nB: 2\r\n\r\n") {maxHeaderCount := 3}),
    -- header total bytes → 431
    ("header total bytes over limit → 431",
       rejectStatus (b "GET / HTTP/1.1\r\nAAAA: 1111\r\nBBBB: 2222\r\n\r\n") {maxHeaderBytes := 20} == some 431),
    -- body size (Content-Length) → 413
    ("Content-Length over body limit → 413",
       rejectStatus (b "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n") {maxBodyBytes := 8} == some 413),
    ("Content-Length within body limit parses",
       parses (b "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc") {maxBodyBytes := 8}),
    -- chunked body size → 413
    ("chunked body over body limit → 413",
       rejectStatus (b "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n8\r\n12345678\r\n0\r\n\r\n") {maxBodyBytes := 4} == some 413),
    -- chunk-size line length → 400 Bad Request (badChunk)
    ("chunk-size line over limit → 400",
       rejectStatus (b "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n100000\r\nx\r\n0\r\n\r\n") {maxChunkLineBytes := 3} == some 400),
    -- bad version → 505
    ("unsupported HTTP version → 505",
       rejectStatus (b "GET / HTTP/2.0\r\nHost: x\r\n\r\n") {} == some 505),
    -- framing conflicts → 400 (smuggling refusals)
    ("Content-Length + Transfer-Encoding → 400",
       rejectStatus (b "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n") {} == some 400),
    ("duplicate Content-Length → 400",
       rejectStatus (b "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n") {} == some 400),
    -- every rejection lands in the 4xx/5xx error range
    ("every limit rejection is a 4xx/5xx code",
       [ rejectStatus (b "GET /aaaaaaaaaaaaaaaaaaaa HTTP/1.1\r\n\r\n") {maxRequestLineBytes := 16},
         rejectStatus (b "POST / HTTP/1.1\r\nContent-Length: 99\r\n\r\n") {maxBodyBytes := 4},
         rejectStatus (b "GET / HTTP/2.0\r\n\r\n") {} ].all
         (fun o => match o with | some c => 400 ≤ c && c ≤ 505 | none => false)) ]

def run : IO (Nat × Nat) := do
  let mut total := 0
  let mut failed := 0
  for (name, ok) in checks do
    total := total + 1
    if ok then IO.println s!"  ok    limit :: {name}"
    else failed := failed + 1; IO.println s!"  FAIL  limit :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} limit/status matrix checks passed"
  if failed == 0 then
    IO.println "RFC 010 limit/status matrix conformance: PASS"
  else
    IO.println s!"RFC 010 limit/status matrix conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Limit
