/-
  Jemmet.Conn.Fake — FakeConn, the deterministic in-model `Conn` instance.

  Implements RFC 002. `FakeConn` is the analog of iotakt's fake poller and kroopt's
  `FakeTransport`: a scripted inbound queue, an outbound sink, and a per-step write
  schedule that models partial sends / backpressure — making the serve loop, parser,
  framing, routing and keep-alive (M1) fully testable without sockets or TLS.

  Every operation is defined as `pure` of a total **pure transition function**
  (`recvPure`/`sendPure`/`flushPure`/`closePure`). That is the substance of the
  determinism obligation (proved in `Jemmet.Proofs.ConnFakeDet`): the `IO` wrapper
  introduces no nondeterminism, so replay is exact. The transition functions also
  maintain `ConnProgress.consistent` by construction.
-/
import Jemmet.Conn.Conn

namespace Jemmet

/-- A scripted `recv` step, consumed front-to-back from the inbox. -/
inductive RecvStep where
  /-- Deliver these plaintext bytes (subject to the caller's `n` cap; any remainder
      is buffered and surfaced as `ownedInBytes` until a later `recv` drains it). -/
  | deliver (b : ByteArray)
  /-- No data available yet (the driver should wait for read readiness). -/
  | wouldBlock
  /-- Clean end of stream. -/
  | eof
  /-- A transport error. -/
  | error (e : ConnError)

/--
The fake connection state. All fields are plain data; there is no hidden IO.

* `inbox`      — remaining scripted `recv` steps.
* `inBuffered` — inbound bytes received-but-not-delivered (= `ownedInBytes`).
* `pendingOut` — plaintext accepted by `send` but not yet flushed (= `ownedOutBytes`).
* `sink`       — everything successfully flushed "to the socket" (the observable log
                 a test inspects to confirm what the peer would have seen).
* `writeQuota` — per-step cap on bytes accepted by `send` / drained by `flush`; one
                 entry is consumed per `send`/`flush` call. `[]` ⇒ unlimited. A `0`
                 entry models `wouldBlock` / backpressure.
* `closeSt`    — lifecycle state.
* `reading`    — whether read interest is still armed (false after eof/close).
-/
structure FakeConn where
  meta       : ConnMetadata
  inbox      : List RecvStep
  inBuffered : ByteArray
  pendingOut : ByteArray
  sink       : ByteArray
  writeQuota : List Nat
  closeSt    : CloseState
  reading    : Bool

namespace FakeConn

/-- The `ConnProgress` of a closed connection: quiescent and owning nothing. -/
def closedProgress : ConnProgress :=
  { progressMade := true, needsRead := false, needsWrite := false,
    ownedInBytes := 0, ownedOutBytes := 0, closeState := .closed }

/-- Build the `ConnProgress` reflecting the current owned buffers and lifecycle.
    `needsWrite` is armed iff there is owned output (the write-interest accounting
    invariant), and `needsRead` follows `reading` while the connection is `open`. -/
def progressOf (c : FakeConn) (progressMade : Bool) : ConnProgress :=
  match c.closeSt with
  | .closed   => closedProgress
  | _ =>
    { progressMade  := progressMade
      needsRead     := c.reading && (c.closeSt == .«open»)
      needsWrite    := c.pendingOut.size > 0
      ownedInBytes  := c.inBuffered.size
      ownedOutBytes := c.pendingOut.size
      closeState    := c.closeSt }

/-- A sensible default fake connection: open, plaintext, nothing scripted. -/
def fresh (fd : FdKey := { raw := 3, gen := 0 }) : FakeConn :=
  { meta := { fd, secure := false, alpn := none, peer := none }
    inbox := [], inBuffered := .empty, pendingOut := .empty, sink := .empty
    writeQuota := [], closeSt := .open, reading := true }

/-- Script the inbound side (recv steps). -/
def withInbox (c : FakeConn) (steps : List RecvStep) : FakeConn :=
  { c with inbox := steps }

/-- Script the write schedule (per-`send`/`flush` byte caps). -/
def withWriteQuota (c : FakeConn) (q : List Nat) : FakeConn :=
  { c with writeQuota := q }

/-- Pure transition for `recv` of up to `n` plaintext bytes. -/
def recvPure (c : FakeConn) (n : Nat) : RecvOutcome × ConnProgress × FakeConn :=
  match c.closeSt with
  | .closed | .aborting => (.eof, closedProgress, c)
  | _ =>
    if c.inBuffered.size > 0 then
      -- Drain previously-buffered inbound first (split across recv boundaries).
      let take := Nat.min n c.inBuffered.size
      let delivered := c.inBuffered.extract 0 take
      let rest := c.inBuffered.extract take c.inBuffered.size
      let c' := { c with inBuffered := rest }
      (.bytes delivered, progressOf c' (take > 0), c')
    else
      match c.inbox with
      | [] =>
        -- Nothing scripted yet: no data available, keep read interest armed.
        (.wouldBlock, progressOf c false, c)
      | step :: rest =>
        match step with
        | .deliver b =>
          let take := Nat.min n b.size
          let delivered := b.extract 0 take
          let buffered := b.extract take b.size
          let c' := { c with inbox := rest, inBuffered := buffered }
          (.bytes delivered, progressOf c' true, c')
        | .wouldBlock =>
          let c' := { c with inbox := rest }
          (.wouldBlock, progressOf c' false, c')
        | .eof =>
          let c' := { c with inbox := rest, reading := false }
          (.eof, progressOf c' true, c')
        | .error e =>
          let c' := { c with inbox := rest, reading := false }
          (.error e, progressOf c' true, c')

/-- Pure transition for `send`: accept up to the current write quota into owned
    plaintext (`pendingOut`); the caller retries the unconsumed suffix. -/
def sendPure (c : FakeConn) (b : ByteArray) : SendOutcome × ConnProgress × FakeConn :=
  match c.closeSt with
  | .«open» =>
    let cap := match c.writeQuota with | q :: _ => Nat.min q b.size | [] => b.size
    let quota' := match c.writeQuota with | _ :: qs => qs | [] => []
    if cap == 0 then
      -- Backpressure: connection accepts nothing right now.
      let c' := { c with writeQuota := quota' }
      (.wouldBlock, progressOf c' false, c')
    else
      let accepted := b.extract 0 cap
      let c' := { c with pendingOut := c.pendingOut ++ accepted, writeQuota := quota' }
      (.consumed cap, progressOf c' true, c')
  | _ =>
    -- Sending on a closing/closed connection is a usage error.
    (.error .reset, progressOf c false, c)

/-- Pure transition for `flush`: drain owned plaintext toward the sink, subject to
    the write quota. A graceful close in progress (`closing`) completes to `closed`
    once the owned output is fully drained. -/
def flushPure (c : FakeConn) : FlushOutcome × ConnProgress × FakeConn :=
  match c.closeSt with
  | .closed | .aborting => (.flushed, closedProgress, c)
  | _ =>
    if c.pendingOut.size == 0 then
      -- Nothing owned to flush; if we were draining for a graceful close, finish.
      let c' := if c.closeSt == .closing then { c with closeSt := .closed } else c
      (.flushed, progressOf c' false, c')
    else
      let cap := match c.writeQuota with | q :: _ => Nat.min q c.pendingOut.size | [] => c.pendingOut.size
      let quota' := match c.writeQuota with | _ :: qs => qs | [] => []
      if cap == 0 then
        let c' := { c with writeQuota := quota' }
        (.wouldBlock, progressOf c' false, c')
      else
        let drained := c.pendingOut.extract 0 cap
        let rest := c.pendingOut.extract cap c.pendingOut.size
        if rest.size == 0 then
          let closeSt' := if c.closeSt == .closing then .closed else c.closeSt
          let c' := { c with pendingOut := .empty, sink := c.sink ++ drained,
                             writeQuota := quota', closeSt := closeSt' }
          (.flushed, progressOf c' true, c')
        else
          let c' := { c with pendingOut := rest, sink := c.sink ++ drained, writeQuota := quota' }
          (.«partial», progressOf c' true, c')

/-- Pure transition for `close`. `graceful` drains owned output first (entering
    `closing`, completing to `closed` on a later `flush`); `abortive` drops owned
    buffers and closes immediately. -/
def closePure (c : FakeConn) (mode : CloseMode) : ConnProgress × FakeConn :=
  match mode with
  | .graceful =>
    if c.pendingOut.size == 0 then
      let c' := { c with closeSt := .closed, inBuffered := .empty, reading := false }
      (closedProgress, c')
    else
      let c' := { c with closeSt := .closing, inBuffered := .empty, reading := false }
      (progressOf c' true, c')
  | .abortive =>
    let c' := { c with closeSt := .closed, pendingOut := .empty, inBuffered := .empty,
                       reading := false }
    (closedProgress, c')

/-- The keystone instance. Each method is exactly `pure` of its transition function
    — no syscalls, no nondeterminism (see `Jemmet.Proofs.ConnFakeDet`). -/
instance : Conn FakeConn where
  metadata c := c.meta
  recv  c n := pure (recvPure c n)
  send  c b := pure (sendPure c b)
  flush c   := pure (flushPure c)
  close c m := pure (closePure c m)

end FakeConn
end Jemmet
