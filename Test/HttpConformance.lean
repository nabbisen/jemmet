/-
  Test.HttpConformance — RFC 004 (parser/limits/injection) and RFC 003 (framing
  soundness / smuggling-vector corpus) test obligations.

  The corpus asserts the security-relevant behavior directly: classic smuggling
  vectors (CL.TE, TE.CL, duplicate Content-Length, obfuscated length) are rejected by
  the framing decision; line-discipline / header-injection / obs-fold / whitespace-
  before-colon are rejected by the parser; limits map to the right status; and
  incomplete input yields `needMore` (split reads) with the pipelined remainder
  carried exactly.
-/
import Jemmet

namespace Test.Http
open Jemmet

abbrev Check := String × Bool

/-- Parse a request head from a string (UTF-8). -/
def parseStr (s : String) (lim : Limits := {}) : ParseHeadResult :=
  parseRequestHead (Reader.ofBytes s.toUTF8) lim

/-- Parse a request head from raw bytes (for control-byte injection cases). -/
def parseBytes (b : ByteArray) (lim : Limits := {}) : ParseHeadResult :=
  parseRequestHead (Reader.ofBytes b) lim

def isReject (status : Nat) : ParseHeadResult → Bool
  | .reject e => e.statusCode == status
  | _         => false

def isNeedMore : ParseHeadResult → Bool
  | .needMore => true
  | _         => false

def framingOf : ParseHeadResult → Option (Except FramingError BodyFraming)
  | .parsed head _ => some (decideFraming head.headers)
  | _              => none

/-- Head parses AND its framing resolves to `f`. -/
def isFraming (f : BodyFraming) (r : ParseHeadResult) : Bool :=
  match framingOf r with | some (.ok f') => f' == f | _ => false

/-- Head parses AND its framing is rejected with error `e` (a smuggling refusal). -/
def isFramingErr (e : FramingError) (r : ParseHeadResult) : Bool :=
  match framingOf r with | some (.error e') => e' == e | _ => false

@[inline] def baEq (a b : ByteArray) : Bool := a.toList == b.toList

/-! ### Group 1 — valid requests parse with correct framing -/

def grpValid : List Check :=
  [ ("GET no-body → framing none",
      isFraming .none (parseStr "GET / HTTP/1.1\r\nHost: x\r\n\r\n")),
    ("POST Content-Length → framing CL 5",
      isFraming (.contentLength 5) (parseStr "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n")),
    ("POST chunked → framing chunked",
      isFraming .chunked (parseStr "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")),
    ("HTTP/1.0 accepted",
      (match parseStr "GET / HTTP/1.0\r\n\r\n" with | .parsed _ _ => true | _ => false)),
    ("case-insensitive header name",
      isFraming (.contentLength 7) (parseStr "POST / HTTP/1.1\r\ncOnTeNt-LeNgTh: 7\r\n\r\n")) ]

/-! ### Group 2 — smuggling corpus: framing refuses to guess -/

def grpSmuggling : List Check :=
  [ ("CL.TE both present → reject (.both)",
      isFramingErr .both (parseStr "POST / HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n")),
    ("TE.CL both present → reject (.both)",
      isFramingErr .both (parseStr "POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n")),
    ("duplicate Content-Length → reject (.multipleCL)",
      isFramingErr .multipleCL (parseStr "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n")),
    ("duplicate identical CL → still reject",
      isFramingErr .multipleCL (parseStr "POST / HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n")),
    ("non-numeric CL → reject (.badCL)",
      isFramingErr .badCL (parseStr "POST / HTTP/1.1\r\nContent-Length: 5x\r\n\r\n")),
    ("internal-space CL → reject (.badCL)",
      isFramingErr .badCL (parseStr "POST / HTTP/1.1\r\nContent-Length: 5 6\r\n\r\n")),
    ("TE gzip (not chunked) → reject (.badTE)",
      isFramingErr .badTE (parseStr "POST / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n")),
    ("TE chunked-not-last → reject (.badTE)",
      isFramingErr .badTE (parseStr "POST / HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n")) ]

/-! ### Group 3 — line discipline / injection / obfuscation rejected at parse -/

def grpParseReject : List Check :=
  [ ("bare LF in request line → 400",
      isReject 400 (parseStr "GET / HTTP/1.1\nHost: x\r\n\r\n")),
    ("bare LF in header → 400",
      isReject 400 (parseStr "GET / HTTP/1.1\r\nHost: x\n\r\n")),
    ("obs-fold (leading WS header) → 400",
      isReject 400 (parseStr "GET / HTTP/1.1\r\nHost: x\r\n cont\r\n\r\n")),
    ("whitespace before colon → 400",
      isReject 400 (parseStr "GET / HTTP/1.1\r\nHost : x\r\n\r\n")),
    ("control byte in value → 400",
      isReject 400 (parseBytes ("GET / HTTP/1.1\r\nX: a".toUTF8 ++ ⟨#[1]⟩ ++ "b\r\n\r\n".toUTF8))),
    ("bad version → 505",
      isReject 505 (parseStr "GET / HTTP/2.0\r\n\r\n")),
    ("two-field request line → 400",
      isReject 400 (parseStr "GET /\r\n\r\n")),
    ("empty method → 400",
      isReject 400 (parseStr " / HTTP/1.1\r\n\r\n")) ]

/-! ### Group 4 — limits map to the right status -/

def grpLimits : List Check :=
  [ ("request line over limit → 414",
      isReject 414 (parseStr "GET /aaaaaaaaaaaaaaaaaaaa HTTP/1.1\r\n\r\n" { maxRequestLineBytes := 10 })),
    ("too many headers → 431",
      isReject 431 (parseStr "GET / HTTP/1.1\r\nA: 1\r\nB: 2\r\n\r\n" { maxHeaderCount := 1 })),
    ("header section bytes over limit → 431",
      isReject 431 (parseStr "GET / HTTP/1.1\r\nHeader: value\r\n\r\n" { maxHeaderBytes := 5 })),
    ("header line over limit → 431",
      isReject 431 (parseStr "GET / HTTP/1.1\r\nHost: xxxxxxxxxx\r\n\r\n" { maxHeaderLineBytes := 3 })) ]

/-! ### Group 5 — split reads (needMore) and pipelined remainder -/

def grpIncremental : List Check :=
  [ ("incomplete request line → needMore",
      isNeedMore (parseStr "GET / HTT")),
    ("headers without final CRLF → needMore",
      isNeedMore (parseStr "GET / HTTP/1.1\r\nHost: x\r\n")),
    ("completed input parses",
      (match parseStr "GET / HTTP/1.1\r\nHost: x\r\n\r\n" with | .parsed _ _ => true | _ => false)),
    ("pipelined remainder carried exactly",
      (match parseStr "GET / HTTP/1.1\r\n\r\nNEXT" with
       | .parsed _ rest => baEq rest.rest "NEXT".toUTF8
       | _ => false)) ]

/-! ### Runner -/

/-! ### Group 6 — chunked decoding + full-request body assembly (RFC 003) -/

def parseFull (s : String) (lim : Limits := {}) : RequestResult :=
  parseRequest (Reader.ofBytes s.toUTF8) lim

def parseFullB (b : ByteArray) (lim : Limits := {}) : RequestResult :=
  parseRequest (Reader.ofBytes b) lim

def fullBodyEq (payload : String) : RequestResult → Bool
  | .parsed req _ => baEq req.body payload.toUTF8
  | _             => false

def fullReject (status : Nat) : RequestResult → Bool
  | .reject e => e.statusCode == status
  | _         => false

def fullNeedMore : RequestResult → Bool
  | .needMore => true
  | _         => false

def fullRemainder (expected : String) : RequestResult → Bool
  | .parsed _ rest => baEq rest.rest expected.toUTF8
  | _              => false

def chunkedHead : String := "POST /p HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
def clHead (n : Nat) : String := s!"POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: {n}\r\n\r\n"

def grpChunked : List Check :=
  [ ("chunked encode→decode round-trips",
      (match parseFullB ("POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".toUTF8
                          ++ encodeChunked "hello world".toUTF8) with
       | .parsed req _ => baEq req.body "hello world".toUTF8 | _ => false)),
    ("chunked multi-chunk assembles in order",
      fullBodyEq "hello world" (parseFull (chunkedHead ++ "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"))),
    ("chunked with trailer accepted",
      fullBodyEq "hello" (parseFull (chunkedHead ++ "5\r\nhello\r\n0\r\nX-Check: 1\r\n\r\n"))),
    ("chunked bad hex size → 400",
      fullReject 400 (parseFull (chunkedHead ++ "zz\r\nhello\r\n0\r\n\r\n"))),
    ("chunked missing CRLF after data → 400",
      fullReject 400 (parseFull (chunkedHead ++ "5\r\nhelloXX0\r\n\r\n"))),
    ("chunked incomplete → needMore",
      fullNeedMore (parseFull (chunkedHead ++ "5\r\nhel"))),
    ("chunked over body cap → 413",
      fullReject 413 (parseFull (chunkedHead ++ "5\r\nhello\r\n0\r\n\r\n") { maxBodyBytes := 4 })),
    ("chunked size line too long → 400",
      fullReject 400 (parseFull (chunkedHead ++ "5\r\nhello\r\n0\r\n\r\n") { maxChunkLineBytes := 0 })),
    ("Content-Length body assembled exactly",
      fullBodyEq "hello" (parseFull (clHead 5 ++ "hello"))),
    ("Content-Length short → needMore",
      fullNeedMore (parseFull (clHead 5 ++ "hel"))),
    ("Content-Length over body cap → 413",
      fullReject 413 (parseFull (clHead 5 ++ "hello") { maxBodyBytes := 4 })),
    ("no-body request → empty body",
      fullBodyEq "" (parseFull "GET / HTTP/1.1\r\nHost: x\r\n\r\n")),
    ("pipelined remainder after CL body carried exactly",
      fullRemainder "GET /next HTTP/1.1\r\n\r\n"
        (parseFull (clHead 5 ++ "helloGET /next HTTP/1.1\r\n\r\n"))),
    ("pipelined remainder after chunked body carried exactly",
      fullRemainder "GET /next HTTP/1.1\r\n\r\n"
        (parseFull (chunkedHead ++ "5\r\nhello\r\n0\r\n\r\nGET /next HTTP/1.1\r\n\r\n"))),
    ("CL.TE both present → rejected (no body smuggling)",
      fullReject 400 (parseFull "POST /p HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\nhello")) ]

def groups : List (String × List Check) :=
  [ ("valid framing",  grpValid),
    ("smuggling",      grpSmuggling),
    ("parse reject",   grpParseReject),
    ("limits",         grpLimits),
    ("incremental",    grpIncremental),
    ("chunked+body",   grpChunked) ]

/-- Run every HTTP check; print results; return (failed, total). -/
def run : IO (Nat × Nat) := do
  let mut total := 0
  let mut failed := 0
  for (name, checks) in groups do
    for (cname, ok) in checks do
      total := total + 1
      if ok then
        IO.println s!"  ok    {name} :: {cname}"
      else
        failed := failed + 1
        IO.println s!"  FAIL  {name} :: {cname}"
  IO.println ""
  IO.println s!"{total - failed}/{total} HTTP checks passed across {groups.length} groups"
  if failed == 0 then
    IO.println "RFC 003/004 parser + smuggling conformance: PASS"
  else
    IO.println s!"RFC 003/004 parser + smuggling conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Http
