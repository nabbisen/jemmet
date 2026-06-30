/-
  Test.ObserveConformance — redacted access-log conformance (RFC 016 / §3.4).

  A hostile request (CRLF-injected path, secret headers, secret body, secret query string)
  must render to a single log line that (a) contains no CR/LF — no forged second entry —
  and (b) leaks none of the header values, body bytes, or query parameters. Safe fields
  (method token, status, sizes) must be present.
-/
import Jemmet

namespace Test.Observe
open Jemmet

abbrev Check := String × Bool
def hasSub (s sub : String) : Bool := (s.splitOn sub).length ≥ 2

-- a hostile request: path carries a CRLF + a forged log line; headers/body/query carry secrets
def evilReq : HttpRequest :=
  { method  := .get
    target  := ⟨"/x?token=qsecret", "/x\r\nFAKE: forged-entry", some "token=qsecret"⟩
    version := .http11
    headers := (Headers.empty.add "Authorization" "authsecret").add "Cookie" "cookiesecret"
    framing := .none
    body    := "BODYSECRET".toUTF8 }

def rec : AccessRecord := AccessRecord.ofExchange 7 false evilReq 200 50 120 5
def line : String := rec.render

-- an unknown method must collapse to OTHER, never echoing the attacker's token
def oddReq : HttpRequest := { evilReq with method := .other "EVILMETHOD" }
def oddLine : String := (AccessRecord.ofExchange 7 false oddReq 200 0 0 0).render

def checks : List Check :=
  [ ("no log injection: rendered line has no LF", line.contains '\n' == false),
    ("no log injection: rendered line has no CR", line.contains '\r' == false),
    ("CRLF in path is scrubbed to placeholders (stays one line)", hasSub line "/x??FAKE"),
    ("no leak: Authorization value absent", hasSub line "authsecret" == false),
    ("no leak: Cookie value absent", hasSub line "cookiesecret" == false),
    ("no leak: body bytes absent", hasSub line "BODYSECRET" == false),
    ("no leak: query string not logged", hasSub line "qsecret" == false),
    ("safe field present: method token", hasSub line "method=GET"),
    ("safe field present: status", hasSub line "status=200"),
    ("safe field present: byte counts", hasSub line "req=50" && hasSub line "resp=120"),
    ("unknown method collapses to OTHER", hasSub oddLine "method=OTHER"),
    ("unknown method token not echoed", hasSub oddLine "EVILMETHOD" == false),
    ("sanitize maps control chars to '?'", sanitize "a\r\nb\tc" == "a??b?c") ]

def run : IO (Nat × Nat) := do
  let mut total := 0
  let mut failed := 0
  for (name, ok) in checks do
    total := total + 1
    if ok then IO.println s!"  ok    observe :: {name}"
    else failed := failed + 1; IO.println s!"  FAIL  observe :: {name}"
  IO.println ""
  IO.println s!"{total - failed}/{total} observability redaction checks passed"
  if failed == 0 then
    IO.println "RFC 016 redacted access-log conformance: PASS"
  else
    IO.println s!"RFC 016 redacted access-log conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Observe
