/-
  Jemmet.Http.Response — the response model and HTTP/1.1 serialization (RFC 005).

  `serialize` emits a correct `HTTP/1.1 <code> <reason>` status line (superseding
  iotakt's `HTTP/1.0` stand-in), auto-manages the framing/hop-by-hop headers jemmet
  owns (`Connection`/`Content-Length`/`Transfer-Encoding`/`Date`/`Server`), and
  **validates every emitted header** so handler-supplied data cannot inject header or
  status structure (no response splitting). It also enforces the message-body
  semantics: `HEAD` and bodyless statuses (1xx/204/304) emit no body, and
  Content-Length and chunked are mutually exclusive.

  The anti-injection and framing properties are proven in `Jemmet.Proofs.ResponseWf`;
  `finalHeaders` is structured so those proofs are clean case analyses.
-/
import Jemmet.Http.Header
import Jemmet.Http.Request
import Jemmet.Http.Status

namespace Jemmet

/-- A response body. `chunked` streaming is wired in with the chunked encoder; this
    phase serializes `fixed`/`empty` bodies and emits chunked framing headers. -/
inductive ResponseBody where
  | empty
  | fixed (b : ByteArray)
  | chunked
  deriving Inhabited

/-- The response a handler produces. `headers` are handler-supplied; jemmet strips and
    re-derives the framing/hop-by-hop headers on serialization. -/
structure HttpResponse where
  status    : Status
  headers   : Headers
  body      : ResponseBody
  keepAlive : Bool
  deriving Inhabited

/-- Why serialization refused (a handler bug, surfaced as 500 — never emitted). -/
inductive SerializeError where
  | invalidBodyForStatus   -- body present on a bodyless status (1xx/204/304)
  | injectedHeader         -- a handler header name/value carried CR/LF/CTL
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Serialization context: the request method (for HEAD) and an optional Date. -/
structure SerializeCtx where
  method : Method
  date   : Option String := none
  deriving Inhabited

/-- A status that permits a message body (everything but 1xx / 204 / 304). -/
def statusAllowsBody (code : Nat) : Bool :=
  !(code / 100 == 1 || code == 204 || code == 304)

/-- No CR/LF/CTL/DEL — the property that makes a header value injection-safe. -/
def headerSafe (s : String) : Bool :=
  s.all (fun c => decide (0x20 ≤ c.toNat ∧ c.toNat ≠ 0x7F))

/-- Header names jemmet owns; handler attempts to set these are dropped, not trusted. -/
def controlledNames : List String :=
  ["connection", "transfer-encoding", "content-length", "date", "server"]

/-- Validate handler headers: drop jemmet-controlled names, reject any remaining
    name/value carrying CR/LF/CTL (→ `injectedHeader`), keep the rest in order. -/
def validateHandlerHeaders : List (String × String) → Except SerializeError (List (String × String))
  | [] => .ok []
  | (n, v) :: rest =>
    if controlledNames.contains (asciiLower n) then
      validateHandlerHeaders rest
    else if headerSafe n && headerSafe v then
      match validateHandlerHeaders rest with
      | .ok vs   => .ok ((n, v) :: vs)
      | .error e => .error e
    else
      .error .injectedHeader

/-- The framing header(s): Content-Length for fixed/empty, chunked otherwise — and
    none at all for a bodyless status. Always at most one, never both. -/
def framingHeaders (allowed : Bool) (body : ResponseBody) : List (String × String) :=
  if allowed then
    match body with
    | .fixed b => [("content-length", toString b.size)]
    | .empty   => [("content-length", "0")]
    | .chunked => [("transfer-encoding", "chunked")]
  else []

/-- Assemble the final, validated, ordered header list plus whether to emit a body. -/
def finalHeaders (ctx : SerializeCtx) (resp : HttpResponse) :
    Except SerializeError (List (String × String) × Bool) :=
  let framingAllowed := statusAllowsBody resp.status.code
  let bodyNonEmpty :=
    match resp.body with | .fixed b => b.size != 0 | .chunked => true | .empty => false
  if !framingAllowed && bodyNonEmpty then
    .error .invalidBodyForStatus
  else if !(match ctx.date with | some d => headerSafe d | none => true) then
    .error .injectedHeader
  else
    match validateHandlerHeaders resp.headers.entries with
    | .error e => .error e
    | .ok hs =>
      let controlled :=
        [("server", "jemmet"),
         ("connection", if resp.keepAlive then "keep-alive" else "close")]
        ++ (match ctx.date with | some d => [("date", d)] | none => [])
        ++ framingHeaders framingAllowed resp.body
      let emitBody := framingAllowed && ctx.method != .head
      .ok (controlled ++ hs, emitBody)

/-- Render one header line. -/
@[inline] def renderHeaderLine (nv : String × String) : String :=
  nv.1 ++ ": " ++ nv.2 ++ "\r\n"

/-- Serialize a response to an HTTP/1.1 byte stream (or refuse a handler-invalid one). -/
def serialize (ctx : SerializeCtx) (resp : HttpResponse) : Except SerializeError ByteArray :=
  match finalHeaders ctx resp with
  | .error e => .error e
  | .ok (hs, emitBody) =>
    let statusLine := "HTTP/1.1 " ++ toString resp.status.code ++ " " ++ resp.status.reason ++ "\r\n"
    let headerBlock := String.join (hs.map renderHeaderLine)
    let head := (statusLine ++ headerBlock ++ "\r\n").toUTF8
    let bodyBytes :=
      if emitBody then (match resp.body with | .fixed b => b | _ => ByteArray.empty)
      else ByteArray.empty
    .ok (head ++ bodyBytes)

/-! ### Response helpers -/

def HttpResponse.text (s : String) (keepAlive : Bool := true) : HttpResponse :=
  { status := .ok, headers := Headers.empty.add "content-type" "text/plain; charset=utf-8",
    body := .fixed s.toUTF8, keepAlive := keepAlive }

def HttpResponse.notFound (keepAlive : Bool := true) : HttpResponse :=
  { status := .notFound, headers := Headers.empty, body := .empty, keepAlive := keepAlive }

end Jemmet
