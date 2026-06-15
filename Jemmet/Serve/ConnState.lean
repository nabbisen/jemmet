/-
  Jemmet.Serve.ConnState — the per-connection state machine and the keep-alive
  request-boundary handling (RFC 007), kept pure so it is provable and FakeConn-
  testable. The iotakt-bound `runStepAuto` event loop (RFC 008/014) wires on top of
  this in M2; the request-boundary logic here is transport-independent.

  The boundary machine consumes exactly one well-framed request per step (via
  `parseRequest`, RFC 003/004) and carries the pipelined remainder exactly — proven in
  `Jemmet.Proofs.KeepAlive`. Keep-alive policy follows HTTP/1.1 (default persistent) vs
  HTTP/1.0 (default close).
-/
import Jemmet.Http
import Jemmet.Route

namespace Jemmet

/-- The head view of a parsed request (drops framing/body), for routing and the
    serialization context. -/
def HttpRequest.toHead (req : HttpRequest) : RequestHead :=
  { method := req.method, target := req.target, version := req.version, headers := req.headers }

/-- Per-connection phase (RFC 007/015). The handler runs in `dispatching`; in the
    real driver that becomes a `WaitingForHandler` task hand-off (RFC 015). -/
inductive Phase where
  | reading                          -- accumulating bytes; awaiting a full request
  | dispatching (req : HttpRequest)  -- request framed; route + run handler
  | writing (out : ByteArray)        -- response serialized; flushing owned output
  | closing                          -- draining before close (no keep-alive)
  | closed
  deriving Inhabited

/-- Does the request ask to keep the connection alive? HTTP/1.1 is persistent unless
    `Connection: close`; HTTP/1.0 is non-persistent unless `Connection: keep-alive`. -/
def requestWantsKeepAlive (head : RequestHead) : Bool :=
  let conn := (head.headers.get? "connection").map asciiLower
  match head.version with
  | .http11 => conn != some "close"
  | .http10 => conn == some "keep-alive"

/-! ### The request-boundary machine -/

/-- One step of the boundary machine: parse exactly one request off the read head. -/
inductive NextReq where
  | needMore
  | reject (e : ParseError)
  | one (req : HttpRequest) (rest : Reader)
  deriving Inhabited

def nextRequest (lim : Limits) (r : Reader) : NextReq :=
  match parseRequest r lim with
  | .needMore       => .needMore
  | .reject e       => .reject e
  | .parsed req rest => .one req rest

/-- Why the drain loop stopped: a partial request needs more bytes, or a malformed one
    must close the connection (no resync — RFC 003 danger-zone rule). -/
inductive DrainEnd where
  | needMore
  | rejected (e : ParseError)
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Drain every *complete* pipelined request currently in the buffer, in order, leaving
    the partial remainder for the next read. Bounded by `fuel` (one request consumes ≥1
    byte, so `remaining + 1` suffices). -/
def drainAux (lim : Limits) (r : Reader) (acc : List HttpRequest) :
    Nat → (List HttpRequest × Reader × DrainEnd)
  | 0        => (acc.reverse, r, .needMore)
  | fuel + 1 =>
    match nextRequest lim r with
    | .needMore   => (acc.reverse, r, .needMore)
    | .reject e   => (acc.reverse, r, .rejected e)
    | .one req rest => drainAux lim rest (req :: acc) fuel

/-- Drain pipelined requests from a reader. -/
def drain (lim : Limits) (r : Reader) : (List HttpRequest × Reader × DrainEnd) :=
  drainAux lim r [] (r.remaining + 1)

end Jemmet
