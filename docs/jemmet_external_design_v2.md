# jemmet External Design Specification v1

**Project:** jemmet
**Document type:** External design specification (§4 of the jemmet deliverable)
**Status:** Draft v2 (revised per senior review), RFC-ready
**Preceded by:** jemmet Requirements v1
**Companion:** jemmet RFC Roadmap v1

This document specifies jemmet's externally-visible design: the connection
abstraction, the HTTP/1.1 parser and framing engine, the response model, routing,
and the serve loop, plus the test/fake instance and the public API. Lean-like
signatures are illustrative; exact forms are settled in the RFCs.

---

## 4.1 System position (recap)

```
┌──────────────────────────────────────────────────────────────┐
│ jemmet — HTTP/1.1 edge server (THIS PROJECT)                   │
│   Serve loop / driver  →  Conn abstraction  →  HTTP parser      │
│   →  framing engine  →  router  →  handler  →  response builder  │
├───────────────┬───────────────────────────────┬──────────────┤
│  PlainIotaktConn (plaintext)                   │  TlsConn (TLS) │
│        │                                        │      │        │
│        ▼                                        ▼      ▼        │
│  iotakt (bytes)                          kroopt (TLS) → iotakt  │
└──────────────────────────────────────────────────────────────┘
```

jemmet consumes iotakt only at the **byte** level (the confirmed consumer binding
spec); it consumes kroopt only as a `TlsConn` that yields plaintext bytes. jemmet
owns all HTTP logic.

## 4.2 Module structure

```text
Jemmet/
  Conn/
    Conn.lean            -- the Conn interface (typeclass) + ConnMetadata, ConnError, outcomes
    Plain.lean           -- PlainIotaktConn: Conn over iotakt EventLoop/FdKey (M2)
    Tls.lean             -- TlsConn: Conn over kroopt (M3, gated)
    Fake.lean            -- FakeConn: deterministic, in-model instance (M1)
  Http/
    Bytes.lean           -- bounds-safe byte reader (the parser foundation)
    Request.lean         -- HttpRequest model + request-line/header parser
    Framing.lean         -- the framing engine (CL/TE/Connection resolution) — proof centerpiece
    Chunked.lean         -- chunked decode (request) / encode (response)
    Response.lean        -- HttpResponse model + HTTP/1.1 serialization
    Status.lean          -- status codes incl. 400/413/431/505
    Header.lean          -- header name/value validation + canonical access
  Route/
    Router.lean          -- method+path dispatch, :param capture
    Handler.lean         -- Handler type + request/response context
    Match.lean           -- path matching (total, deterministic)
  Serve/
    Loop.lean            -- the driver: runStepAuto dispatch, per-FdKey demux
    ConnState.lean       -- per-connection state machine (read→route→respond→keep-alive)
    Backpressure.lean    -- pending-output queue, write-interest, slow-client timeouts
    Config.lean          -- listeners (plaintext/TLS ports), limits, timeouts
  Proofs/
    FramingSound.lean    -- no-smuggling / unique boundaries (headline)
    ParserBounds.lean     -- bounds safety by construction
    RouterTotal.lean      -- routing totality + determinism
    ResponseWf.lean       -- response well-formedness / no header injection
    KeepAlive.lean        -- request-boundary state machine
  Examples/
    HelloEdge.lean        -- minimal plaintext edge server
    HttpsEdge.lean        -- HTTPS edge (M3)
  docs/  rfcs/
```

The **Http/Route/Serve (logic) vs Conn (transport instances) vs Proofs**
separation is a requirement; `Http/*` parsing/framing is pure and proven; `Conn/*`
instances are the only IO/transport-touching code besides `Serve/Loop`.

## 4.3 The connection abstraction (`Jemmet.Conn`)

The keystone. One interface; three instances.

```lean
structure ConnMetadata where
  fd        : Iotakt.Model.FdKey   -- identity (for demux/logging); jemmet never touches raw fd
  secure    : Bool                 -- true iff TLS (kroopt)
  alpn      : Option String        -- negotiated protocol (e.g. "http/1.1"); none for plaintext
  peer      : Option PeerAddr

inductive ConnError where          -- unified across layers
  | peerClosed                     -- clean EOF
  | truncated                      -- EOF/closed before a complete unit (e.g. mid-request, pre-close_notify)
  | reset                          -- transport reset (iotakt) or fatal TLS alert (kroopt)
  | transport (detail : String)    -- other, redacted

inductive CloseState   | open | closing | closed | aborting
structure ConnProgress where         -- returned by every op so the driver sees needs + owned memory
  progressMade : Bool ; needsRead : Bool ; needsWrite : Bool
  ownedInBytes : Nat ; ownedOutBytes : Nat ; closeState : CloseState
inductive RecvOutcome  | bytes (b : ByteArray) | wouldBlock | eof | error (e : ConnError)
inductive SendOutcome  | consumed (n : Nat)    | wouldBlock | error (e : ConnError)  -- n = PLAINTEXT bytes
inductive FlushOutcome | flushed | partial | wouldBlock | error (e : ConnError)
inductive CloseMode    | graceful | abortive

class Conn (κ : Type) where
  metadata : κ → ConnMetadata
  recv     : κ → Nat       → IO (RecvOutcome  × ConnProgress × κ)  -- TLS may drive a state machine
  send     : κ → ByteArray → IO (SendOutcome  × ConnProgress × κ)  -- returns plaintext bytes owned
  flush    : κ            → IO (FlushOutcome × ConnProgress × κ)   -- push owned pending output
  close    : κ → CloseMode → IO (ConnProgress × κ)
-- ConnProgress drives the loop: arm read/write interest from needsRead/needsWrite;
-- feed ownedOut/InBytes into the egress/ingress bound (RFC 010); closeState drives teardown.
-- Instances MUST NOT call runStepAuto (RFC 014 §5): the driver owns global polling.
```

Design points:

1. **Byte-level, plaintext both ways.** `recv` yields plaintext bytes regardless
   of transport; `send`/`flush` accept plaintext and the instance handles framing,
   encryption (TLS), and the socket. jemmet's parser/serializer only ever see
   plaintext.
2. **`send` consumes plaintext (not socket) bytes.** `consumed n` means the
   connection has taken ownership of `n` plaintext bytes and will encrypt-and-flush
   or fail; `wouldBlock` = zero consumed; pending (possibly ciphertext) output is
   owned by the connection. jemmet retries unconsumed plaintext and calls `flush`
   to make progress. (Mirrors kroopt's `TlsConn` write contract; `PlainIotaktConn`
   implements it trivially.)
3. **Shaped for the heavy instance.** `recv`/`send`/`flush` are `IO` because
   `TlsConn` drives kroopt's progress (decrypt/encrypt + iotakt I/O) inside them.
   `PlainIotaktConn` is then thin.
4. **Unified errors.** iotakt `IoErrno`, kroopt `TransportError`/alerts, and EOF
   map into `ConnError`; jemmet handles connection death uniformly. `truncated`
   (e.g. EOF before a full request, or peer-EOF before TLS `close_notify`) is
   distinct from clean `peerClosed`.
5. **No raw fd.** jemmet holds `FdKey` for demux/logging only; close routes through
   the instance (which routes to iotakt `closeConnection`).

### 4.3.1 Instances

- **`PlainIotaktConn`** (M2): wraps an iotakt `EventLoop` reference + `FdKey`.
  `recv` → `recvAck key n` (ack-discipline mandatory — see Serve loop); `send` →
  `sendAck key b offset len` returning `consumed n`; `flush` drains the owned
  suffix via `sendAck` with advancing offset, toggling `enableWrite`/`disableWrite`;
  `close` → `closeConnection`. Maps iotakt `ReadResult`/`WriteResult` (incl.
  `interrupted`→retry, `closed`→error) into the outcomes above.
- **`TlsConn`** (M3, gated on kroopt's `IotaktTransport` validation): wraps a
  kroopt connection. `recv` drives kroopt's progress step (which itself uses
  iotakt) and yields decrypted plaintext or `wouldBlock`; `send`/`flush` feed
  kroopt plaintext and drive ciphertext out; `metadata.alpn`/`secure` come from
  kroopt. The HTTP code above is unchanged.
- **`FakeConn`** (M1): deterministic, pure-ish (`IO`-wrapped but no syscalls). A
  scripted inbound queue and an outbound log, with a write schedule modeling
  partial sends/backpressure. Makes the serve loop, parser, framing, routing, and
  keep-alive fully testable without sockets or TLS — the analog of iotakt's fake
  poller and kroopt's `FakeTransport`.

## 4.4 HTTP/1.1 parser and framing engine (`Jemmet.Http`)

### 4.4.1 Bounds-safe byte reader (`Bytes.lean`)
A reader over an accumulating `ByteArray` that exposes line/segment/length-bounded
reads which are **bounds-safe by construction** (every read checks remaining
length; no partial-state OOB). All parsing is built on it. (Proof: `ParserBounds`.)

### 4.4.2 Request model and parser (`Request.lean`)
```lean
structure HttpRequest where
  method  : Method
  target  : RequestTarget        -- origin-form path + query
  version : Version              -- HTTP/1.0 | HTTP/1.1
  headers : Headers              -- validated name/value pairs
  framing : BodyFraming          -- decided by the framing engine, not stored ad hoc
  body    : ByteArray
```
The parser reads the request line (bounded length → 400/414 on overflow), then
headers (bounded count and total size → 431), validating names/values (reject
control chars / embedded CRLF → 400), then hands the headers to the framing engine
to decide the body.

### 4.4.3 Framing engine (`Framing.lean`) — the proof centerpiece
```lean
inductive BodyFraming | none | contentLength (n : Nat) | chunked
def decideFraming : Headers → Except FramingError BodyFraming
```
Resolution rules (sound, single-valued):
- both `Content-Length` and `Transfer-Encoding` present → **reject** (no guessing);
- multiple or conflicting `Content-Length` → **reject**;
- `Transfer-Encoding: chunked` (and only chunked, last) → `chunked`;
- single valid `Content-Length: n` → `contentLength n`;
- neither, on a request → `none` (no body).
**Proven property (`FramingSound`):** for any header set, `decideFraming` returns
a unique result or a rejection — never an ambiguous one — so no two conformant
parties can disagree about boundaries (no smuggling). (RFC 003.)

### 4.4.4 Chunked (`Chunked.lean`)
Decode chunked request bodies (bounded chunk-size and extension length); encode
chunked responses (reusing the well-tested chunk framing iotakt validated at the
byte level, but owned here). Malformed chunk framing → 400.

### 4.4.5 Response model and serialization (`Response.lean`)
```lean
structure HttpResponse where
  status   : Status
  headers  : Headers
  body     : ResponseBody          -- fixed ByteArray | chunked stream
  keepAlive: Bool
def serialize : HttpResponse → ByteArray   -- emits "HTTP/1.1 <code> <reason>\r\n…"
```
Emits a correct **HTTP/1.1** status line (fixing iotakt's `HTTP/1.0` stand-in),
auto-sets `Date`/`Server`/`Content-Length` (or `Transfer-Encoding: chunked`), and
the keep-alive `Connection` header. All emitted header values are encoded/validated
so handler data cannot inject structure. (Proof: `ResponseWf`.)

## 4.5 Routing (`Jemmet.Route`)
```lean
abbrev Handler := RequestCtx → IO HttpResponse
structure Router where routes : List Route        -- method × pattern × Handler
def Router.dispatch : Router → HttpRequest → Dispatch     -- found h params | notFound | methodNotAllowed
```
Path matching supports static segments and `:param` capture; dispatch is **total
and deterministic** (every request maps to exactly one of: a handler with captured
params, 404, or 405). (Proof: `RouterTotal`.) jemmet owns this; iotakt's optional
`Router` is not used.

## 4.6 Serve loop / connection driver (`Jemmet.Serve`)

The driver owns the iotakt event loop and is **shared infrastructure** for
plaintext and TLS connections.

```text
loop ← EventLoop.create cfg ; add plaintext listener(s) ; (M3) add TLS listener(s)
repeat:
  (loop, events) ← loop.runStepAuto                 -- pull, not callback
  for ev in events:
    | newConnection key _   → conns[key] := ConnState.fresh (mkConn key)   -- Plain or Tls by listener
    | dataReady key ev'     → conns[key] := drive conns[key] ev'           -- demux by FdKey
    | tick now              → sweep timeouts (header/body/idle/write)       -- slowloris defense
```

Per-connection state is **phase-indexed** (RFC 007/015):
```text
ReadingHead → ReadingBody → Dispatching → WaitingForHandler(deadline,taskId)
  → WritingResponse → (KeepAlive ↺ | Closing) → Closed
```
The event-batch ordering, stale-event drop, per-batch step bound + fairness, and the
close/cancel/timeout/pending-output interaction are the **driver event-semantics
contract** (RFC 014); the `(phase, error) → action` policy is RFC 010; handler work
is handed to a henret task in `WaitingForHandler` so it never blocks the loop (RFC
015).

Per-connection drive (one bounded progress step, then yield):
```text
on readable : Conn.recv → feed parser; when a full request is framed:
               router.dispatch → handler → response; serialize; Conn.send/flush
on writable : Conn.flush pending output; when drained, disableWrite; advance keep-alive
on eof/error: if mid-request ⇒ truncated; else graceful close
keep-alive  : after a response fully flushed, reset per-request state, carry any
              pipelined remainder, await the next request (idle timeout armed)
```

Design points:
1. **Pull-based, demultiplexed.** One `runStepAuto` loop, many connections;
   per-`FdKey` state. (Per the iotakt binding spec and review.)
2. **Ack-discipline.** `recv`/`send` go through iotakt `recvAck`/`sendAck` inside
   the `Conn` instances; jemmet never bypasses the ack or the next readiness is
   coalesced away.
3. **Uniform for TLS.** For a `TlsConn`, `Conn.recv` drives kroopt then yields
   plaintext; the loop is unchanged — TLS vs plaintext differs only in which
   `Conn` instance `mkConn` builds, chosen by the listener the connection arrived
   on (separate ports, v0.1).
4. **Backpressure & timeouts (`Backpressure.lean`).** A **mandatory** three-tier
   egress bound (jemmet-queued + Conn-owned plaintext + kroopt-owned ciphertext,
   from `ConnProgress.ownedOutBytes`) caps user-space pending output; large
   responses stream (chunked `ResponseBody`) rather than fully serialize before
   backpressure applies; a slow reader cannot force unbounded buffering;
   header/body/idle/write timeouts are swept on `tick`. (RFC 010 — proven/
   model-checked.)
5. **HTTP/2 not precluded.** `ConnState` is per-connection but structured so a
   future multiplexed (stream-keyed) state can replace the single-request state
   without reshaping the loop or `Conn`; ALPN (`metadata.alpn = "h2"`) is the
   selection hook. (Forward; RFC 013.)

## 4.7 Public API (provisional)
```lean
namespace Jemmet
def serve   (cfg : Config) (router : Router) : IO Unit          -- run the edge server
structure Config where
  plaintextPorts : List UInt16
  tlsPorts       : List (UInt16 × Kroopt.ServerConfig) := []     -- M3
  limits         : Limits := {}                                  -- header/body/conn caps
  timeouts       : Timeouts := {}                                -- header/body/idle/write
-- response helpers: ok / notFound / json / text / chunked / status
end Jemmet
```
Handlers are `RequestCtx → IO HttpResponse`; the application never sees a `Conn`,
an `FdKey`, iotakt, or kroopt.

## 4.8 Concurrency / process model
Single process, single driver loop, level-triggered, Linux-only (inherited from
iotakt). No background threads. Deterministic with respect to the iotakt event
trace, which is what makes `FakeConn` replay meaningful.

## 4.9 Open design decisions (for the RFCs)
1. Exact `Conn` typeclass vs structure-of-closures (proof ergonomics vs instance
   ergonomics) — RFC 002.
2. Whether framing soundness is proven over `decideFraming` alone or over the full
   read→frame→boundary pipeline — RFC 003.
3. Header collection representation (assoc list vs bounded map) and its
   adversarial-complexity bound — RFC 004.
4. Response-body streaming interface for large/generated bodies — RFC 005.
5. Exact per-connection `ConnState` shape that stays h2-extensible — RFC 007/013.
6. The kroopt `ServerConfig`/`TlsConn` surface jemmet wires to — RFC 009 (with
   kroopt).
