/-
  Test.IntegrationConformance — RFC 006 routing, RFC 005 serialization, and the M1
  end-to-end pipeline (parse → route → respond → serialize), driven purely (no
  sockets). Demonstrates the acceptance milestone: a request becomes a routed,
  well-formed HTTP/1.1 response.
-/
import Jemmet

namespace Test.Integration
open Jemmet

abbrev Check := String × Bool

def asStr (b : ByteArray) : String := Jemmet.asciiString b
def hasSub (s sub : String) : Bool := (s.splitOn sub).length ≥ 2
def firstLine (s : String) : String := ((s.splitOn "\r\n").head?).getD ""

/-! ### Routing -/

def dummyH : Handler := fun _ => pure (HttpResponse.text "hi")

def router : Router := { routes :=
  [ { method := .get,  pattern := [.static "hello"],                handler := dummyH },
    { method := .get,  pattern := [.static "users", .param "id"],   handler := dummyH },
    { method := .post, pattern := [.static "submit"],               handler := dummyH } ] }

def mkReq (m : Method) (path : String) : RequestHead :=
  { method := m, target := RequestTarget.ofString path, version := .http11, headers := Headers.empty }

def grpRouting : List Check :=
  [ ("static route found",
      (match router.dispatch (mkReq .get "/hello") with | .found _ _ => true | _ => false)),
    ("param captured",
      (match router.dispatch (mkReq .get "/users/42") with
       | .found _ ps => ps == [("id", "42")] | _ => false)),
    ("no path match → 404",
      (match router.dispatch (mkReq .get "/nope") with | .notFound => true | _ => false)),
    ("method mismatch → 405 with Allow",
      (match router.dispatch (mkReq .post "/hello") with
       | .methodNotAllowed allow => allow == [.get] | _ => false)),
    ("post route found",
      (match router.dispatch (mkReq .post "/submit") with | .found _ _ => true | _ => false)) ]

/-! ### Response serialization -/

def ctxGet : SerializeCtx := { method := .get }

def serOut (ctx : SerializeCtx) (r : HttpResponse) : Option String :=
  match serialize ctx r with | .ok b => some (asStr b) | .error _ => none

def grpResponse : List Check :=
  [ ("status line is HTTP/1.1",
      (match serOut ctxGet (HttpResponse.text "hi") with
       | some s => firstLine s == "HTTP/1.1 200 OK" | none => false)),
    ("Content-Length set for fixed body",
      (match serOut ctxGet (HttpResponse.text "hi") with
       | some s => hasSub s "content-length: 2" | none => false)),
    ("Server and keep-alive Connection emitted",
      (match serOut ctxGet (HttpResponse.text "hi") with
       | some s => hasSub s "server: jemmet" && hasSub s "connection: keep-alive" | none => false)),
    ("keepAlive=false → Connection: close",
      (match serOut ctxGet { (HttpResponse.text "hi") with keepAlive := false } with
       | some s => hasSub s "connection: close" | none => false)),
    ("CRLF in handler header value → rejected",
      (match serialize ctxGet { status := .ok, headers := Headers.empty.add "x" "a\r\nb",
                                body := .empty, keepAlive := true } with
       | .error .injectedHeader => true | _ => false)),
    ("HEAD emits no body",
      (match serOut { method := .head } (HttpResponse.text "hi") with
       | some s => hasSub s "content-length: 2" && !hasSub s "\r\n\r\nhi" | none => false)),
    ("204 emits no Content-Length",
      (match serOut ctxGet { status := .noContent, headers := Headers.empty, body := .empty, keepAlive := true } with
       | some s => !hasSub s "content-length" | none => false)),
    ("204 with a body → rejected",
      (match serialize ctxGet { status := .noContent, headers := Headers.empty,
                                body := .fixed "x".toUTF8, keepAlive := true } with
       | .error .invalidBodyForStatus => true | _ => false)) ]

/-! ### End-to-end: parse → route → respond → serialize -/

def endToEnd : IO Bool := do
  match parseRequestHead (Reader.ofBytes "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n".toUTF8) with
  | .parsed head _ =>
    match router.dispatch head with
    | .found h ps =>
      let resp ← h { head := head, params := ps }
      match serialize { method := head.method } resp with
      | .ok out => pure (firstLine (asStr out) == "HTTP/1.1 200 OK")
      | .error _ => pure false
    | _ => pure false
  | _ => pure false

/-! ### Runner -/

def groups : List (String × List Check) :=
  [ ("routing",  grpRouting),
    ("response", grpResponse) ]

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
  -- end-to-end (IO)
  total := total + 1
  let e2e ← endToEnd
  if e2e then
    IO.println "  ok    e2e :: parse→route→respond→serialize"
  else
    failed := failed + 1
    IO.println "  FAIL  e2e :: parse→route→respond→serialize"
  IO.println ""
  IO.println s!"{total - failed}/{total} integration checks passed"
  if failed == 0 then
    IO.println "RFC 005/006 routing + response + e2e conformance: PASS"
  else
    IO.println s!"RFC 005/006 routing + response + e2e conformance: FAIL ({failed} failed)"
  pure (failed, total)

end Test.Integration
