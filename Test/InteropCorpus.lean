/-
  Test.InteropCorpus — external HTTP/1.1 interop / conformance corpus.

  A curated, named set of adversarial and real-world request vectors run through the full
  parse → frame → route → respond path, each with a spec-justified expected outcome (RFC
  9110/9112 + jemmet's threat model). The corpus is the h2spec-style conformance suite for
  HTTP/1.1: every smuggling/splitting class, the line-discipline rules, method/version/target
  forms, the RFC 9112 §3.2 Host requirement, valid framing that must parse, routing
  outcomes, and pipelining.

  Where jemmet is deliberately stricter than the RFC's minimum, the vector notes it: a
  compound Transfer-Encoding (e.g. `gzip, chunked`) is rejected because jemmet implements no
  content-codings, and every duplicate/conflicting Content-Length is rejected (not coalesced)
  as a no-smuggling measure.
-/
import Jemmet

namespace Test.Interop
open Jemmet

inductive Expect where
  | parses                    -- valid: parses to a request
  | rejects (status : Nat)    -- hard rejection with this status
  | needsMore                 -- incomplete: more bytes needed
  deriving DecidableEq, Repr

def b (s : String) : ByteArray := s.toUTF8

/-- Run a raw request through `parseRequest` and compare to the expected outcome. -/
def check (raw : String) (e : Expect) (lim : Limits := {}) : Bool :=
  match parseRequest (Reader.ofBytes (b raw)) lim, e with
  | .parsed _ _, .parses    => true
  | .needMore,   .needsMore => true
  | .reject pe,  .rejects s => pe.statusCode == s
  | _,           _          => false

abbrev V := String × String × Expect   -- (name, raw request, expected)

/-! ### Request smuggling / desync (§3.2.1) — the headline threat; all reject 400 -/
def smuggling : List V :=
  [ ("CL+TE present together → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n", .rejects 400),
    ("TE+CL (reverse order) → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 5\r\n\r\n", .rejects 400),
    ("duplicate Content-Length, differing values → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n", .rejects 400),
    ("duplicate Content-Length, equal values → reject (conservative)",
       "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n", .rejects 400),
    ("Content-Length as a list '5, 5' → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5, 5\r\n\r\n", .rejects 400),
    ("Content-Length non-numeric '5x' → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5x\r\n\r\n", .rejects 400),
    ("Content-Length with internal space '5 6' → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5 6\r\n\r\n", .rejects 400),
    ("Transfer-Encoding identity (non-chunked) → reject (no guessing)",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: identity\r\n\r\n", .rejects 400),
    ("Transfer-Encoding gzip (unsupported coding) → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n", .rejects 400),
    ("Transfer-Encoding 'chunked, gzip' (chunked not last) → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, gzip\r\n\r\n", .rejects 400),
    ("Transfer-Encoding 'gzip, chunked' (compound; no content-codings) → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n", .rejects 400),
    ("duplicate Transfer-Encoding headers → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", .rejects 400),
    ("chunked bad hex size 'zz' → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nzz\r\nhello\r\n0\r\n\r\n", .rejects 400),
    ("chunked missing CRLF after data → reject",
       "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n5\r\nhelloXX0\r\n\r\n", .rejects 400) ]

/-! ### Header injection / response splitting (§3.2.2) — reject 400 -/
def injection : List V :=
  [ ("bare CR in header value → reject",
       "GET / HTTP/1.1\r\nHost: x\r\nX-H: a\rb\r\n\r\n", .rejects 400),
    ("whitespace before colon 'Host : x' → reject",
       "GET / HTTP/1.1\r\nHost : x\r\n\r\n", .rejects 400),
    ("obs-fold (deprecated line folding) → reject",
       "GET / HTTP/1.1\r\nHost: x\r\nX-H: a\r\n folded\r\n\r\n", .rejects 400) ]

/-! ### Line discipline — strict CRLF; reject bare LF/CR -/
def lineDiscipline : List V :=
  [ ("bare-LF line endings (no CR) → reject",
       "GET / HTTP/1.1\nHost: x\n\n", .rejects 400),
    ("empty request line (bare CRLF) → reject",
       "\r\n", .rejects 400),
    ("empty input → needMore",
       "", .needsMore),
    ("header line without final blank line → needMore",
       "GET /ping HTTP/1.1\r\nHost: x\r\n", .needsMore) ]

/-! ### Method / version / target forms -/
def methodVersion : List V :=
  [ ("unknown method 'BREW' → parses (routed later)",
       "BREW /coffee HTTP/1.1\r\nHost: x\r\n\r\n", .parses),
    ("lowercase method 'get' (case-sensitive) → parses as unknown",
       "get / HTTP/1.1\r\nHost: x\r\n\r\n", .parses),
    ("HTTP/0.9 → 505",
       "GET / HTTP/0.9\r\nHost: x\r\n\r\n", .rejects 505),
    ("HTTP/2.0 over 1.1 syntax → 505",
       "GET / HTTP/2.0\r\nHost: x\r\n\r\n", .rejects 505),
    ("HTTP/1.2 (unknown minor) → 505",
       "GET / HTTP/1.2\r\nHost: x\r\n\r\n", .rejects 505),
    ("two-token request line (no version) → reject",
       "GET /\r\nHost: x\r\n\r\n", .rejects 400),
    ("four-token request line → reject",
       "GET / HTTP/1.1 extra\r\nHost: x\r\n\r\n", .rejects 400),
    ("empty target (double space) → reject",
       "GET  HTTP/1.1\r\nHost: x\r\n\r\n", .rejects 400),
    ("asterisk-form 'OPTIONS *' → parses",
       "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n", .parses),
    ("absolute-form target → parses",
       "GET http://example.com/p HTTP/1.1\r\nHost: x\r\n\r\n", .parses) ]

/-! ### Host requirement (RFC 9112 §3.2) -/
def host : List V :=
  [ ("HTTP/1.1 with no Host → 400",
       "GET / HTTP/1.1\r\n\r\n", .rejects 400),
    ("HTTP/1.1 with one Host → parses",
       "GET / HTTP/1.1\r\nHost: x\r\n\r\n", .parses),
    ("HTTP/1.1 with duplicate Host → 400",
       "GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n", .rejects 400),
    ("HTTP/1.0 with no Host → parses (Host optional pre-1.1)",
       "GET / HTTP/1.0\r\n\r\n", .parses),
    ("HTTP/1.0 with duplicate Host → 400",
       "GET / HTTP/1.0\r\nHost: x\r\nHost: y\r\n\r\n", .rejects 400) ]

/-! ### Valid framing — must parse -/
def valid : List V :=
  [ ("GET with Host → parses", "GET / HTTP/1.1\r\nHost: x\r\n\r\n", .parses),
    ("Content-Length 0 → parses", "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n", .parses),
    ("Content-Length n with body → parses", "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello", .parses),
    ("chunked body → parses", "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n", .parses),
    ("chunked with trailer → parses", "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\nX-T: 1\r\n\r\n", .parses),
    ("OWS-padded Content-Length ' 5 ' → parses", "POST / HTTP/1.1\r\nHost: x\r\nContent-Length:  5 \r\n\r\nhello", .parses),
    ("Transfer-Encoding 'Chunked' (case-insensitive coding) → parses", "POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: Chunked\r\n\r\n0\r\n\r\n", .parses),
    ("HTAB in header value (allowed) → parses", "GET / HTTP/1.1\r\nHost: x\r\nX-H: a\tb\r\n\r\n", .parses),
    ("percent-encoded path + query → parses", "GET /a%20b?q=1&r=2 HTTP/1.1\r\nHost: x\r\n\r\n", .parses),
    ("HTTP/1.0 keep-alive request → parses", "GET / HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n", .parses) ]

def parseVectors : List V := smuggling ++ injection ++ lineDiscipline ++ methodVersion ++ host ++ valid

/-! ### Full path — parse → route → status -/
def hTrivial : Handler := fun _ => pure default
def corpusRouter : Router := { routes :=
  [ { method := .get, pattern := [.static "ping"],                handler := hTrivial },
    { method := .get, pattern := [.static "users", .param "id"],  handler := hTrivial } ] }

def toHead (req : HttpRequest) : RequestHead :=
  { method := req.method, target := req.target, version := req.version, headers := req.headers }

/-- Outcome status of the full path: a parse rejection's code, else the routing result. -/
def pathStatus (raw : String) : Nat :=
  match parseRequest (Reader.ofBytes (b raw)) {} with
  | .parsed req _ =>
    match corpusRouter.dispatch (toHead req) with
    | .found _ _          => 200
    | .notFound           => 404
    | .methodNotAllowed _ => 405
  | .reject e => e.statusCode
  | .needMore => 0

def fullPath : List (String × Bool) :=
  [ ("full path: GET /ping → 200",          pathStatus "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n" == 200),
    ("full path: GET /users/42 (param) → 200", pathStatus "GET /users/42 HTTP/1.1\r\nHost: x\r\n\r\n" == 200),
    ("full path: GET /nope → 404",          pathStatus "GET /nope HTTP/1.1\r\nHost: x\r\n\r\n" == 404),
    ("full path: POST /ping (GET route) → 405", pathStatus "POST /ping HTTP/1.1\r\nHost: x\r\n\r\n" == 405),
    ("full path: smuggling vector short-circuits to 400 before routing",
        pathStatus "POST /ping HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n" == 400) ]

/-! ### Pipelining — two requests in one buffer; carried remainder -/
def pipelining : List (String × Bool) :=
  [ ("pipelining: first request parses, remainder is exactly the second",
        (match parseRequest (Reader.ofBytes (b ("GET /ping HTTP/1.1\r\nHost: x\r\n\r\n"
                                                  ++ "GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n"))) {} with
         | .parsed _ rest => rest.rest.toList == (b "GET /users/7 HTTP/1.1\r\nHost: x\r\n\r\n").toList
         | _              => false)),
    ("pipelining: a request split mid-headers needs more bytes",
        (match parseRequest (Reader.ofBytes (b "GET /ping HTTP/1.1\r\nHost: x\r\nAccept: ")) {} with
         | .needMore => true | _ => false)) ]

def run : IO (Nat × Nat) := do
  let mut total := 0
  let mut failed := 0
  for (name, raw, e) in parseVectors do
    total := total + 1
    if check raw e then IO.println s!"  ok    interop :: {name}"
    else failed := failed + 1; IO.println s!"  FAIL  interop :: {name}"
  for (name, ok) in (fullPath ++ pipelining) do
    total := total + 1
    if ok then IO.println s!"  ok    interop :: {name}"
    else failed := failed + 1; IO.println s!"  FAIL  interop :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} HTTP/1.1 interop corpus vectors conform"
  if failed == 0 then
    IO.println "external HTTP/1.1 interop/conformance corpus: PASS"
  else
    IO.println s!"external HTTP/1.1 interop/conformance corpus: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Interop
