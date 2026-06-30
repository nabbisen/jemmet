/-
  Jemmet.Iotakt — `PlainIotaktConn`, the plaintext iotakt transport binding (RFC 008).

  jemmet owns *what bytes mean*; iotakt owns *how bytes move*. This module refines
  jemmet's structural `FdKey` stand-in to iotakt's real `Iotakt.Model.FdKey` (the two are
  structurally identical: `raw : Int`, `gen : Nat`) and implements the `Conn` typeclass
  over iotakt's byte-level surface, mapping `Iotakt.Model.ReadResult`/`WriteResult`/
  `IoErrno` onto jemmet's `RecvOutcome`/`SendOutcome`/`ConnError`.

  The native `IotaktRuntime.Loop.EventLoop` (recvAck/sendAck/enableWrite/disableWrite/
  closeConnection) needs the C epoll backend + henret, so it is not built in this
  sandbox. The binding therefore takes the loop operations behind `IotaktLoopOps σ` — a
  record of the exact iotakt EventLoop ops over real model types. In deployment, a ~10-
  line adapter instantiates `IotaktLoopOps IotaktRuntime.Loop.EventLoop` from the native loop
  (see the reference in `docs`); in-sandbox, a deterministic model loop instantiates it,
  so the binding's ack discipline, partial-write re-arm, and FdKey demux are testable
  here. The loop state `σ` is threaded functionally, matching iotakt's functional
  EventLoop (`recvAck : EventLoop → … → IO (EventLoop × ReadResult)`).

  The binding enforces the write-interest invariant by construction (RFC 010 / RFC 014
  §4): owned output is buffered in the connection, iotakt write interest is armed exactly
  while that buffer is non-empty, and `ConnProgress.needsWrite ↔ ownedOutBytes > 0`.
-/
import Jemmet
import Iotakt.Model

namespace Jemmet.Iotakt
open Jemmet

/-- Refine jemmet's structural `FdKey` to/from iotakt's real one (identical shape). -/
def ofIotaktKey (k : Iotakt.Model.FdKey) : Jemmet.FdKey := { raw := k.raw, gen := k.gen }

/-- Map an iotakt `IoErrno` to jemmet's unified `ConnError`. Clean EOF is *not* an error
    (it surfaces as `RecvOutcome.eof`); a reset/broken pipe collapses to `.reset`. -/
def connErrorOfErrno : Iotakt.Model.IoErrno → ConnError
  | .connectionReset => .reset
  | .brokenPipe      => .reset
  | .notConnected    => .reset
  | .badFd           => .transport "bad file descriptor"
  | .permissionDenied => .transport "permission denied"
  | .tooManyFiles    => .transport "too many open files"
  | .other code      => .transport s!"errno {code}"
  | e                => .transport (toString (repr e))

/-- The iotakt EventLoop operations jemmet's `Conn` consumes, over real iotakt model
    types. `σ` is the loop-state type: `IotaktRuntime.Loop.EventLoop` in deployment (native), a
    model loop in tests. Threaded functionally, as iotakt's EventLoop is. -/
structure IotaktLoopOps (σ : Type) where
  /-- recv + ack-readable: at most `maxBytes`, clearing the coalesced readiness slot. -/
  recvAck      : σ → Iotakt.Model.FdKey → Nat → IO (σ × Iotakt.Model.ReadResult)
  /-- send + ack-writable: write `len` bytes of `ba` from `offset`. -/
  sendAck      : σ → Iotakt.Model.FdKey → ByteArray → Nat → Nat → IO (σ × Iotakt.Model.WriteResult)
  /-- arm iotakt write interest for the key. -/
  enableWrite  : σ → Iotakt.Model.FdKey → IO σ
  /-- clear iotakt write interest for the key. -/
  disableWrite : σ → Iotakt.Model.FdKey → IO σ
  /-- close the connection (drops the registration; old generation goes stale). -/
  closeConn    : σ → Iotakt.Model.FdKey → IO σ

/-- A plaintext connection bound to an iotakt loop. Owned output is buffered in `outBuf`
    (the `send`-consumed, not-yet-flushed plaintext); the loop state `σ` is carried
    functionally. `meta.fd` is the refined iotakt key. -/
structure PlainIotaktConn (σ : Type) where
  ops          : IotaktLoopOps σ
  loop         : σ
  key          : Iotakt.Model.FdKey
  meta         : ConnMetadata
  outBuf       : ByteArray := ByteArray.empty
  closeSt      : CloseState := .«open»

namespace PlainIotaktConn

/-- Build a fresh plaintext connection over an iotakt loop for `key`. -/
def fresh (ops : IotaktLoopOps σ) (loop : σ) (key : Iotakt.Model.FdKey)
    (peer : Option PeerAddr := none) : PlainIotaktConn σ :=
  { ops, loop, key,
    meta := { fd := ofIotaktKey key, secure := false, alpn := none, peer } }

/-- The `ConnProgress` reflecting owned output and lifecycle. `needsWrite` is armed iff
    the owned-output buffer is non-empty (the write-interest invariant); `needsRead`
    follows the open state; inbound bytes are delivered straight through, so the
    connection owns none. -/
def progressOf (c : PlainIotaktConn σ) (progressMade : Bool) : ConnProgress :=
  match c.closeSt with
  | .closed =>
    { progressMade, needsRead := false, needsWrite := false,
      ownedInBytes := 0, ownedOutBytes := 0, closeState := .closed }
  | st =>
    { progressMade,
      needsRead     := st == .«open»,
      needsWrite    := c.outBuf.size > 0,
      ownedInBytes  := 0,
      ownedOutBytes := c.outBuf.size,
      closeState    := st }

/-- `recv`: recvAck up to `n` bytes, delivering plaintext straight through. -/
def recv (c : PlainIotaktConn σ) (n : Nat) : IO (RecvOutcome × ConnProgress × PlainIotaktConn σ) := do
  let (loop', r) ← c.ops.recvAck c.loop c.key n
  let c := { c with loop := loop' }
  match r with
  | .bytes b      => pure (.bytes b, c.progressOf true, c)
  | .wouldBlock   => pure (.wouldBlock, c.progressOf false, c)
  | .eof          => pure (.eof, c.progressOf true, c)
  | .interrupted  => pure (.wouldBlock, c.progressOf false, c)   -- EINTR: caller re-polls
  | .error e      => pure (.error (connErrorOfErrno e), c.progressOf false, c)

/-- `send`: take ownership of the plaintext into `outBuf` and arm iotakt write interest.
    The bytes are pushed to the socket by `flush` (or on a `writable` readiness). -/
def send (c : PlainIotaktConn σ) (b : ByteArray) : IO (SendOutcome × ConnProgress × PlainIotaktConn σ) := do
  let c := { c with outBuf := c.outBuf ++ b }
  let loop' ← if c.outBuf.size > 0 then c.ops.enableWrite c.loop c.key else pure c.loop
  let c := { c with loop := loop' }
  pure (.consumed b.size, c.progressOf true, c)

/-- `flush`: drain `outBuf` to the socket via sendAck. On a partial write, keep the
    unsent suffix and leave write interest armed; when fully drained, clear it. This is
    the partial-write re-arm protocol and the write-interest invariant in one place. -/
def flush (c : PlainIotaktConn σ) : IO (FlushOutcome × ConnProgress × PlainIotaktConn σ) := do
  if c.outBuf.size == 0 then
    pure (.flushed, c.progressOf false, c)
  else
    let (loop', w) ← c.ops.sendAck c.loop c.key c.outBuf 0 c.outBuf.size
    let c := { c with loop := loop' }
    match w with
    | .wrote n =>
      let c := { c with outBuf := c.outBuf.extract n.toNat c.outBuf.size }
      if c.outBuf.size == 0 then
        let loop' ← c.ops.disableWrite c.loop c.key
        let c := { c with loop := loop' }
        pure (.flushed, c.progressOf true, c)
      else
        pure (.«partial», c.progressOf true, c)
    | .wouldBlock  => pure (.wouldBlock, c.progressOf false, c)
    | .interrupted => pure (.wouldBlock, c.progressOf false, c)
    | .closed      => pure (.error .reset, c.progressOf false, c)
    | .error e     => pure (.error (connErrorOfErrno e), c.progressOf false, c)

/-- `close`: graceful keeps the buffered output for the serve layer to drain first;
    both modes then drop registration via iotakt `closeConnection`. The connection
    becomes quiescent. -/
def close (c : PlainIotaktConn σ) (mode : CloseMode) : IO (ConnProgress × PlainIotaktConn σ) := do
  let c := match mode with | .abortive => { c with outBuf := ByteArray.empty } | .graceful => c
  let loop' ← c.ops.closeConn c.loop c.key
  let c := { c with loop := loop', closeSt := .closed, outBuf := ByteArray.empty }
  pure (c.progressOf true, c)

end PlainIotaktConn

/-- The `Conn` instance: jemmet's serve loop drives an iotakt connection through exactly
    the same typeclass as `FakeConn`, so every proof and conformance test over `Conn`
    applies unchanged to the real transport. -/
instance : Conn (PlainIotaktConn σ) where
  metadata c := c.meta
  recv  := PlainIotaktConn.recv
  send  := PlainIotaktConn.send
  flush := PlainIotaktConn.flush
  close := PlainIotaktConn.close

/-! ### The iotakt-driven serve loop

  Ties the transport binding to jemmet's transport-independent `serveConn` (RFC 007),
  giving an end-to-end HTTP path over iotakt: accept → recv → parse → route → respond →
  serialize → send → keep-alive → close. Because `serveConn` is generic over `[Conn κ]`,
  the proven parser/framing/router/serializer and the keep-alive serve loop run verbatim
  over `PlainIotaktConn`; only the transport changes. The iotakt loop state `σ` is
  threaded through the whole drive. In deployment the accepted keys come from
  `EventLoop.runStepAuto` (a `newConnection` event per accept). -/

/-- Serve one accepted iotakt connection to completion (all keep-alive / pipelined
    requests), then close it. Returns the advanced loop state. -/
def serveOne (ops : IotaktLoopOps σ) (loop : σ) (router : Router) (lim : Limits)
    (key : Iotakt.Model.FdKey) : IO σ := do
  let c := PlainIotaktConn.fresh ops loop key
  let c ← serveConn router lim c
  let (_, c) ← PlainIotaktConn.close c .graceful
  pure c.loop

/-- The connection driver: serve each accepted connection on one loop, threading the
    iotakt loop state forward. This is the handoff's worked shape (newConnection → serve
    → close). In deployment, `newConns` is the stream of `newConnection` keys produced by
    successive `EventLoop.runStepAuto` batches. -/
def runServer (ops : IotaktLoopOps σ) (loop0 : σ) (router : Router) (lim : Limits := {})
    (newConns : List Iotakt.Model.FdKey) : IO σ :=
  newConns.foldlM (fun loop key => serveOne ops loop router lim key) loop0

/-! ### Phase-indexed interleaving driver (RFC 014 §3 / RFC 007 / RFC 015)

  `runServer` serves each connection to completion before the next. The real driver does
  **one bounded progress step per ready connection per `runStepAuto` batch**, so a slow
  or pipelined connection cannot starve the others (RFC 014 §3 fairness): per-connection
  state (inbound carry, owned output, phase) persists across batches, and within a batch
  the driver imposes the RFC 014 ordering (accept → I/O, coalesced one-step-per-key →
  timeout) and drops events for torn-down/unknown keys. This is the implementation whose
  event contract `Jemmet.Proofs.EventSemantics` specifies and `Event.lean` models. -/

/-- One event in a `runStepAuto` batch, iotakt-keyed (newConnection → `accept`, dataReady
    readable/writable → `readable`/`writable`, tick → `timeout`). -/
inductive DriverEvent where
  | accept   (key : Iotakt.Model.FdKey)
  | readable (key : Iotakt.Model.FdKey)
  | writable (key : Iotakt.Model.FdKey)
  | timeout  (now : Nat)

/-- Per-connection state carried across batches: the inbound carry (bytes not yet a full
    request), owned output (serialized responses not yet flushed), keep-alive intent, and
    fairness/timeout bookkeeping. -/
structure ServeState where
  key        : Iotakt.Model.FdKey
  meta       : ConnMetadata
  drain      : ByteArray := .empty
  outBuf     : ByteArray := .empty
  keepAlive  : Bool := true
  steps        : Nat := 0
  lastActive   : Nat := 0
  requestStartedAt : Nat := 0   -- when the in-flight request began (read-timeout basis)

/-- The whole-loop driver state: the shared iotakt loop, the per-`FdKey` connection table,
    a stale-event counter, and modeled time. -/
structure ServeDriver (σ : Type) where
  ops          : IotaktLoopOps σ
  loop         : σ
  router       : Router
  lim          : Limits := {}
  idleTimeout  : Nat := 30
  readTimeout  : Nat := 30      -- RFC 010 ingress slowloris: max time to finish reading one request
  maxOwnedOut  : Nat := 262144      -- RFC 010 egress cap: per-connection owned-output bound
  now          : Nat := 0
  conns        : List (Iotakt.Model.FdKey × ServeState) := []
  droppedStale : Nat := 0
  closedKeys   : List Iotakt.Model.FdKey := []
  phase        : LifecyclePhase := .running   -- RFC 016 production lifecycle
  drainDeadline : Nat := 0                     -- when a forced drain force-closes the remainder

namespace ServeDriver

def findConn (d : ServeDriver σ) (key : Iotakt.Model.FdKey) : Option ServeState :=
  (d.conns.find? (fun p => decide (p.1 = key))).map (·.2)
def isLive (d : ServeDriver σ) (key : Iotakt.Model.FdKey) : Bool := (d.findConn key).isSome

/-- RFC 016: request a graceful shutdown. New connections are refused from now on, in-flight
    connections finish their current request and close (no new keep-alive request), and any
    remainder still live at `now + drainWindow` is force-closed (bounded drain). Idempotent. -/
def requestShutdown (d : ServeDriver σ) (drainWindow : Nat) : ServeDriver σ :=
  match d.phase with
  | .running => { d with phase := .draining (d.now + drainWindow), drainDeadline := d.now + drainWindow }
  | _        => d
def setConn (d : ServeDriver σ) (key : Iotakt.Model.FdKey) (st : ServeState) : ServeDriver σ :=
  { d with conns := (key, st) :: d.conns.filter (fun p => decide (p.1 ≠ key)) }
def removeConn (d : ServeDriver σ) (key : Iotakt.Model.FdKey) : ServeDriver σ :=
  { d with conns := d.conns.filter (fun p => decide (p.1 ≠ key)), closedKeys := key :: d.closedKeys }

/-- One bounded readable step: a single `recv`, frame whatever complete requests are
    buffered, serialize their responses, and one flush attempt — then yield (no looping
    to completion). The inbound remainder is carried for the next batch. -/
def stepReadable (d : ServeDriver σ) (st : ServeState) : IO (ServeDriver σ) := do
  let c : PlainIotaktConn σ :=
    { ops := d.ops, loop := d.loop, key := st.key, meta := st.meta, outBuf := st.outBuf, closeSt := .«open» }
  -- RFC 010 backpressure: while owned output is at the cap, do not read/produce more —
  -- only attempt to drain. This bounds owned output regardless of how much the peer sends
  -- (egress-slowloris defense); `egressAdmits` is the pure decision proven in EgressBound.
  if !egressAdmits d.maxOwnedOut st.outBuf.size then
    let (_fo, _p, c) ← Conn.flush c
    pure { (d.setConn st.key { st with outBuf := c.outBuf }) with loop := c.loop }
  else
  let (rout, _p, c) ← Conn.recv c 4096
  match rout with
  | .bytes b =>
    let (resp, leftover, ka) ← serveBuffer d.router d.lim (st.drain ++ b)
    let (_so, _p, c) ← Conn.send c resp
    let (_fo, _p, c) ← Conn.flush c
    let d := { d with loop := c.loop }
    -- a completed request (response produced) restarts the read clock for the next one;
    -- a partial request leaves it running, so a slow trickle still times out (slowloris)
    let reqStart := if resp.size > 0 then d.now else st.requestStartedAt
    pure (d.setConn st.key
      { st with drain := leftover, outBuf := c.outBuf, keepAlive := ka && d.phase.admitsKeepAlive,
                steps := st.steps + 1, lastActive := d.now, requestStartedAt := reqStart })
  | .wouldBlock => pure { d with loop := c.loop }
  | .eof | .error _ =>
    let (_p, c) ← Conn.close c .graceful
    pure ({ d with loop := c.loop }.removeConn st.key)

/-- One bounded writable step: drain owned output toward the socket. -/
def stepWritable (d : ServeDriver σ) (st : ServeState) : IO (ServeDriver σ) := do
  let c : PlainIotaktConn σ :=
    { ops := d.ops, loop := d.loop, key := st.key, meta := st.meta, outBuf := st.outBuf, closeSt := .«open» }
  let (_fo, _p, c) ← Conn.flush c
  pure { (d.setConn st.key { st with outBuf := c.outBuf }) with loop := c.loop }

/-- Process one I/O event, stepping each key at most once per batch (coalescing/fairness);
    an event for a torn-down/unknown key is dropped with a counter (stale). -/
def stepIo (acc : List Iotakt.Model.FdKey × ServeDriver σ) (ev : DriverEvent) :
    IO (List Iotakt.Model.FdKey × ServeDriver σ) := do
  let (stepped, d) := acc
  let once (key : Iotakt.Model.FdKey)
           (act : ServeState → IO (ServeDriver σ)) : IO (List Iotakt.Model.FdKey × ServeDriver σ) :=
    if stepped.any (fun k => decide (k = key)) then pure acc
    else match d.findConn key with
      | some st => do let d ← act st; pure (key :: stepped, d)
      | none    => pure (key :: stepped, { d with droppedStale := d.droppedStale + 1 })
  match ev with
  | .readable key => once key d.stepReadable
  | .writable key => once key d.stepWritable
  | _ => pure acc

/-- A connection is timed out if it has been idle past the idle timeout, or — when a
    partial request is buffered — has been reading one request past the read timeout
    (the ingress-slowloris defense: a slow trickle keeps `lastActive` fresh but not
    `requestStartedAt`). -/
def connTimedOut (st : ServeState) (now idleTimeout readTimeout : Nat) : Bool :=
  (!(now < st.lastActive + idleTimeout))
  || (st.drain.size > 0 && !(now < st.requestStartedAt + readTimeout))

def sweepTimeouts (now : Nat) (d : ServeDriver σ) : ServeDriver σ :=
  let d := { d with now := now }
  let dead := d.conns.filter (fun p => connTimedOut p.2 now d.idleTimeout d.readTimeout)
  let d := { d with conns := d.conns.filter (fun p => !(connTimedOut p.2 now d.idleTimeout d.readTimeout)),
                    closedKeys := dead.map Prod.fst ++ d.closedKeys }
  -- RFC 016 bounded drain (mirrors `stepLifecycle`'s tick, proven in `Proofs/Lifecycle`):
  -- a drain stops cleanly once empty, and is force-closed at the deadline.
  match d.phase with
  | .draining dl =>
      if d.conns.isEmpty then { d with phase := .stopped }
      else if dl ≤ now then
        { d with phase := .stopped, closedKeys := d.conns.map Prod.fst ++ d.closedKeys, conns := [] }
      else d
  | _ => d

/-- Dispatch one `runStepAuto` batch under the RFC 014 ordering contract: accepts first
    (so a same-batch I/O event has state), then I/O coalesced (one step per key), then
    timeouts last (swept against state already advanced this batch). -/
def dispatchBatch (d : ServeDriver σ) (batch : List DriverEvent) : IO (ServeDriver σ) := do
  let d := batch.foldl (fun d ev => match ev with
    | .accept key =>
      if d.isLive key then d
      else if d.phase.acceptsNew then
        d.setConn key { key, meta := (PlainIotaktConn.fresh d.ops d.loop key).meta,
                        lastActive := d.now, requestStartedAt := d.now }
      else d   -- RFC 016: draining/stopped — refuse the new connection
    | _ => d) d
  let io := batch.filter (fun ev => match ev with | .readable _ | .writable _ => true | _ => false)
  let (_, d) ← io.foldlM stepIo ([], d)
  let d := batch.foldl (fun d ev => match ev with | .timeout now => sweepTimeouts now d | _ => d) d
  pure d

/-- The deterministic driver run: fold over a sequence of `runStepAuto` batches. -/
def run (d0 : ServeDriver σ) (trace : List (List DriverEvent)) : IO (ServeDriver σ) :=
  trace.foldlM (fun d batch => d.dispatchBatch batch) d0

end ServeDriver

end Jemmet.Iotakt
