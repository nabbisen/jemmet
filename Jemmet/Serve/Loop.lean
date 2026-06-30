/-
  Jemmet.Serve.Loop — the per-connection driver over the `Conn` abstraction (RFC 007).

  `serveBuffer` runs the pure boundary machine (`drain`) over an accumulated buffer:
  for each complete pipelined request it routes, runs the handler, applies the
  keep-alive policy, and serializes (a handler whose response cannot be serialized
  becomes a 500 — never a malformed wire response). `driveConn` is transport-independent
  (any `Conn` instance, including `FakeConn`): recv → process → send → keep-alive loop,
  carrying the pipelined remainder exactly (the carry correctness is
  `Jemmet.Proofs.keepAlive_boundary`). The iotakt event loop (RFC 008/014) replaces the
  recv/send pumps with `runStepAuto`-driven I/O in M2; this is the logic they drive.
-/
import Jemmet.Serve.ConnState
import Jemmet.Conn.Conn

namespace Jemmet

def methodToken : Method → String
  | .get => "GET" | .head => "HEAD" | .post => "POST" | .put => "PUT"
  | .delete => "DELETE" | .patch => "PATCH" | .options => "OPTIONS"
  | .connect => "CONNECT" | .trace => "TRACE" | .other s => s

def methodList (ms : List Method) : String :=
  String.intercalate ", " (ms.map methodToken)

/-- A guaranteed-serializable 500 (used when a handler response cannot be serialized). -/
def serverError (method : Method) : ByteArray :=
  match serialize { method := method }
      { status := .internalServerError, headers := Headers.empty, body := .empty, keepAlive := false } with
  | .ok b    => b
  | .error _ => "HTTP/1.1 500 Internal Server Error\r\nconnection: close\r\n\r\n".toUTF8

/-- The deterministic HTTP error response for a parse rejection (§3.4: every malformed input
    maps to a status, not undefined behaviour). The status mirrors `ParseError.statusCode`
    (proven mapping, RFC 010); the connection is closed afterward — a malformed request is a
    desync risk, so there is no resync (RFC 003 danger-zone rule). -/
def errorResponse (e : ParseError) : HttpResponse :=
  let st : Status := match e with
    | .uriTooLong           => .uriTooLong
    | .badVersion           => .httpVersionNotSupported
    | .headerFieldsTooLarge => .headerFieldsTooLarge
    | .bodyTooLarge         => .payloadTooLarge
    | _                     => .badRequest
  { status := st, headers := Headers.empty, body := .empty, keepAlive := false }

/-- Process every complete pipelined request in `buf`: route, run the handler, apply the
    keep-alive policy, serialize. Returns the concatenated responses, the unconsumed
    remainder (carried to the next read), and whether to keep the connection alive. -/
def serveBuffer (router : Router) (lim : Limits) (buf : ByteArray) :
    IO (ByteArray × ByteArray × Bool) := do
  let (reqs, rest, dend) := drain lim (Reader.ofBytes buf)
  let mut out : ByteArray := .empty
  let mut keepAlive := true
  for req in reqs do
    let head := req.toHead
    let resp ← match router.dispatch head with
      | .found h ps => h { head := head, params := ps, body := req.body }
      | .notFound   => pure (HttpResponse.notFound)
      | .methodNotAllowed allow =>
          pure { status := .methodNotAllowed,
                 headers := Headers.empty.add "allow" (methodList allow),
                 body := .empty, keepAlive := true }
    let ka := requestWantsKeepAlive head && resp.keepAlive
    keepAlive := ka
    let bytes := match serialize { method := head.method } { resp with keepAlive := ka } with
      | .ok b    => b
      | .error _ => serverError head.method
    out := out ++ bytes
  -- a malformed request: emit the deterministic error response and close (no resync)
  match dend with
  | .rejected e =>
    let bytes := match serialize { method := .get } (errorResponse e) with
      | .ok b    => b
      | .error _ => serverError .get
    out := out ++ bytes
    keepAlive := false
  | .needMore => pure ()
  pure (out, rest.rest, keepAlive)

/-! ### Transport-independent recv/send pumps over `Conn` -/

def recvAll {κ : Type} [Conn κ] (c : κ) (acc : ByteArray) : Nat → IO (ByteArray × κ × Bool)
  | 0        => pure (acc, c, false)
  | fuel + 1 => do
    let (outcome, _p, c') ← Conn.recv c 4096
    match outcome with
    | .bytes b    => recvAll c' (acc ++ b) fuel
    | .wouldBlock => pure (acc, c', false)
    | .eof        => pure (acc, c', true)
    | .error _    => pure (acc, c', true)

def sendAll {κ : Type} [Conn κ] (c : κ) (out : ByteArray) : Nat → IO κ
  | 0        => pure c
  | fuel + 1 => do
    if out.isEmpty then pure c
    else
      let (sout, _p, c') ← Conn.send c out
      match sout with
      | .consumed n =>
        let (_f, _p2, c'') ← Conn.flush c'
        sendAll c'' (out.extract n out.size) fuel
      | .wouldBlock =>
        let (_f, _p2, c'') ← Conn.flush c'
        sendAll c'' out fuel
      | .error _ => pure c'

/-- Drive a connection: recv available bytes, process complete requests, send responses,
    and either keep-alive (carrying the remainder) or close. -/
def driveConn {κ : Type} [Conn κ] (router : Router) (lim : Limits) (c : κ) (carry : ByteArray) :
    Nat → IO κ
  | 0        => pure c
  | fuel + 1 => do
    let (buf, c1, eof) ← recvAll c carry 64
    if buf.isEmpty then
      pure c1
    else
      let (out, leftover, ka) ← serveBuffer router lim buf
      let c2 ← sendAll c1 out 256
      if ka && !eof then
        driveConn router lim c2 leftover fuel
      else
        let (_p, c3) ← Conn.close c2 .graceful
        let (_f, _p2, c4) ← Conn.flush c3
        pure c4

/-- Serve a fresh connection to completion (bounded keep-alive iterations). -/
def serveConn {κ : Type} [Conn κ] (router : Router) (lim : Limits := {}) (c : κ) : IO κ :=
  driveConn router lim c .empty 64

end Jemmet
