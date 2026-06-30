# Changelog

All notable changes to jemmet are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); jemmet releases as version-named
tarballs at logical breakpoints (RFC 012).

## [Unreleased]

## [0.4.0] — 2026-06-15 — plaintext HTTP/1.1 edge

First tagged release: the verified plaintext edge (M0–M2) and its hardening — framing
soundness / no-smuggling, parser bounds-safety, routing totality, response well-formedness,
keep-alive boundary, egress boundedness, handler policy, and the production lifecycle, all
machine-checked (103 axiom-clean theorems), plus 296 conformance checks across 12 suites and
5,400 fuzz iterations. TLS (M3) is deferred to 0.5.0; the comprehensive M4 hardening re-run
across both transports is 0.6.0. Known limitation: the native curl/epoll end-to-end is a
deployment-only seam (not exercised in-repo), and the mdbook `docs/src` structure is not yet
built.

### Changed — dependencies are pinned git deps, not vendored
- **iotakt and henret are independent projects; jemmet depends on them and no longer
  contains them.** Removed the vendored peer sources entirely — both the v0.4.0 unpacked
  source trees (~500 files of peer code in-repo) and the interim pinned-tarball/`vendor/`
  apparatus. jemmet's repo now holds a *reference* to each dependency, not the dependency.
- `lakefile.toml` declares each peer as a pinned Lake **git dependency**:
  `iotakt` → `git "https://github.com/nabbisen/iotakt" @ "v0.14.6"` (the henret-free model
  package); `henret` → `git "https://github.com/nabbisen/henret" @ "v0.34.4"` (commit
  `ad0ceab4ebed2884c9165be44154dca2c1f4816f`). Lake fetches them into the gitignored
  `.lake/packages/`; `lake-manifest.json` is the committed lockfile pinning resolved commits.
- iotakt re-pinned **0.13.1 → 0.14.6**; henret **0.15.2 → 0.34.4**. API compatibility
  re-verified against the 0.14.6 / 0.34.4 sources: the consumed `Iotakt.Model` types
  (`FdKey`/`IoErrno`/`ReadResult`/`WriteResult`) and henret's terminal `TaskState`
  constructors (`completed`/`failed`/`cancelled`) all resolve; the binding is σ-abstracted.
- Removed `scripts/vendor_sync.py`, `verify_vendor.py`, `vendor_tree_hash.py` and the
  `vendor/` tree; `scripts/ci.sh` returns to 7 steps (Lake restores pinned deps from the
  committed manifest — no sync step).
- **Lockfile pending:** run `lake update iotakt henret` once to generate + commit
  `lake-manifest.json` (henret locks to `ad0ceab4…`). _A full `lake build` against the
  pins still needs a 4.15.0 toolchain (blocked in this environment by network allowlist);
  static API checks pass._

### Release versioning

Milestones are mapped to SemVer 0.x minors (one minor per milestone):
M0 → 0.1.0, M1 → 0.2.0, M1.5 → 0.3.0, M2 → 0.4.0 (current HEAD — the hardened plaintext
edge), M3 → 0.5.0 (TLS, gated on kroopt), M4 → 0.6.0 (the full hardening pass re-run across
plaintext + TLS, which is why it follows M3). 1.0.0 is the stable release and is never cut
without explicit maintainer confirmation. The roadmap's former "M4 — v0.1 release" wording
is corrected to "0.6.0" (since 0.1.0 is now M0). The observability, RFC 016 lifecycle,
interop, audit, matrix, and CI work already in the tree belongs to 0.4.0. Documentation
only — no version tagged.

### M0 — project startup & design freeze (in progress)

Added:
- Lake project skeleton pinned to **Lean 4.15.0** (`lean-toolchain`,
  `lakefile.toml`), with libraries `Jemmet` (core) and `JemmetProofs` (proven core),
  and the `conformance` test executable (`lake test`). No external dependencies.
- The full RFC set under `rfcs/proposed/` (001–016) plus the **RFC 000 lifecycle
  policy vendored** into `rfcs/done/` so the repo describes its own policy.
- Project docs under `docs/` (requirements, external design, RFC roadmap), aligned to
  the `_v2` filenames the README references.
- `scripts/check-cleanliness.py` — the RFC 011/012 cleanliness guard (asserts no
  project-local `sorry`/`axiom`/`unsafe`), comment-aware.
- CI skeleton (`.github/workflows/ci.yml`): build → proofs → cleanliness → test.

### RFC 002 — the connection abstraction (keystone): implemented

Added:
- `Jemmet/Conn/Conn.lean` — the `Conn` typeclass (`recv`/`send`/`flush`/`close`/
  `metadata`, each returning a `ConnProgress`), the unified `ConnError`/`CloseState`
  model, the `RecvOutcome`/`SendOutcome`/`FlushOutcome`/`CloseMode` outcomes,
  `ConnMetadata`/`FdKey`/`PeerAddr`, and `ConnProgress.consistent` (write-interest
  accounting + closed-is-quiescent invariants).
- `Jemmet/Conn/Fake.lean` — `FakeConn`, the deterministic in-model instance: scripted
  inbox, owned-output/sink model, per-step write schedule (partial sends /
  backpressure), built on total pure transition functions.
- `Jemmet/Proofs/ConnFakeDet.lean` — **FakeConn determinism** (the RFC 002 proof
  obligation): each `Conn` op is `pure` of its pure transition, and replay of an
  operation script is exact. Axiom-clean (only `Quot.sound` via `funext`).
- `Test/Conformance.lean` + `Test/Main.lean` — the **`Conn` conformance suite** (the
  RFC 002 test obligation): would-block, split reads (`ownedInBytes`), partial send +
  retry, flush draining, graceful vs abortive close, EOF/error mapping, with
  `ConnProgress.consistent` asserted after every operation. 49/49 checks pass.

Notes:
- RFC 002 remains in `rfcs/proposed/` (not yet moved to `done/`) until the M1
  pure-core set is accepted together, to avoid prematurely breaking the many inbound
  cross-references to `../proposed/002…`.

### M1 — pure HTTP core (in progress)

#### RFC 004 — HTTP/1.1 request parser and bounds safety: implemented

Added:
- `Jemmet/Http/Header.lean` — byte-class predicates (tchar / field-value / OWS),
  header name/value validation, and the `Headers` collection with parse-time
  lowercase canonicalization and case-insensitive `getAll` (duplicates preserved so
  the framing decision can see every occurrence).
- `Jemmet/Http/Bytes.lean` — the bounds-safe `Reader`: the only byte accessor is the
  total `byteAt`, advances are clamped, and line reading enforces a single line
  discipline (strict CRLF; bare CR/LF rejected) with a per-line length bound.
- `Jemmet/Http/Request.lean` — `Method`/`Version`/`RequestTarget`, the `HttpRequest`
  model, the request-line and header parser, the limit set (request-line / header
  count / header bytes / header-line), and the `ParseError → status` taxonomy
  (400/414/431/505). Incomplete input yields `needMore`; there is no partial-parse
  state.
- `Jemmet/Proofs/ParserBounds.lean` — **ParserBounds** and **ParseStep** (the RFC 004
  proof obligations): `byteAt` reads only in-bounds indices; every `Reader`
  transition preserves `off ≤ size`; transitions are monotone and buffer-preserving;
  and `parseRequestHead_parsed` / `parseRequestHead_remainder` establish that a parsed
  head consumes a forward, bounded, contiguous prefix and carries the remainder as
  exactly the input suffix (no drop/dup/reorder). Axiom-clean.

#### RFC 003 — HTTP framing soundness and smuggling defense: framing engine + decision soundness

Added:
- `Jemmet/Http/Framing.lean` — `decideFraming`, the single-valued framing decision
  (reject CL+TE; reject multiple Content-Length; accept only a lone `chunked`
  Transfer-Encoding; strict all-digit Content-Length; otherwise none) with explicit
  rejection — it never guesses.
- `Jemmet/Proofs/FramingSound.lean` — the single-message **FramingSound** lemmas:
  `framing_unique` (deterministic single-valued decision), `framing_reject_both` and
  `framing_no_ambiguous_accept` (the CL+TE ambiguity is refused, never resolved to a
  boundary), and `framing_ok_none`. Axiom-clean.
- `Test/HttpConformance.lean` — the **smuggling-vector corpus** and parser corpus (RFC
  003/004 test obligations): CL.TE / TE.CL / duplicate-CL / obfuscated-length /
  non-chunked-TE all refused; bare-LF / obs-fold / whitespace-before-colon / control-
  byte injection / bad-version / malformed-request-line rejected with the right
  status; limits enforced; split reads → `needMore` with the pipelined remainder
  carried exactly. 29/29 checks pass (78 total with the Conn suite).

#### RFC 006 — routing: implemented

Added:
- `Jemmet/Route/Match.lean` — `Segment` (static / `:param`), `PathPattern`, `splitPath`,
  and `matchPattern`: total, deterministic, structurally-recursive segment matching
  with parameter capture.
- `Jemmet/Route/Handler.lean` — `RequestCtx` (parsed head + captured params + body) and
  the typed `Handler := RequestCtx → IO HttpResponse`.
- `Jemmet/Route/Router.lean` — `Route`/`Router`/`Dispatch` and `Router.dispatch`:
  first-match method+path dispatch resolving to `found`/`notFound`/`methodNotAllowed`
  (the last carrying the `Allow` set).
- `Jemmet/Proofs/RouterTotal.lean` — **RouterTotal** (the RFC 006 proof obligation):
  `dispatch_trichotomy` (every request resolves to exactly one outcome — totality),
  `dispatch_found_sound` (a `found` names a real in-table route whose method and pattern
  match, capturing exactly those params), and `dispatch_notFound_sound` (a `notFound`
  means genuinely no route pattern matches the path). Dispatch is a deterministic
  function. Axiom-clean.

#### RFC 005 — response model and HTTP/1.1 serialization: implemented

Added:
- `Jemmet/Http/Status.lean` — `Status` (code + reason) with the common status constants.
- `Jemmet/Http/Response.lean` — `HttpResponse`/`ResponseBody`, and `serialize`: a correct
  `HTTP/1.1 <code> <reason>` status line (superseding iotakt's `HTTP/1.0` stand-in),
  jemmet-owned framing/hop-by-hop headers (`Connection`/`Content-Length`/
  `Transfer-Encoding`/`Server`/`Date`), the message-body semantics (HEAD and
  1xx/204/304 emit no body; CL xor chunked), and **output validation** that rejects any
  handler header carrying CR/LF/CTL (→ `injectedHeader`) so handler data cannot inject
  structure.
- `Jemmet/Proofs/ResponseWf.lean` — **ResponseWf** (the RFC 005 proof obligation, the
  security-critical part): `validateHandlerHeaders_clean` — every emitted handler header
  is CR/LF/CTL-free (anything else is rejected, never emitted, the anti-response-
  splitting guarantee); `serialize_ok_handlers_validated` — a successful serialize
  implies the handler headers passed validation; and `framingHeaders_le_one` /
  `framingHeaders_disallowed` — the framing header is Content-Length xor chunked
  (never both) and absent entirely for a bodyless status. Axiom-clean.
- `Test/IntegrationConformance.lean` — routing, serialization, and the **end-to-end M1
  pipeline** (parse → route → respond → serialize, no sockets): static/param/404/405
  dispatch with `Allow`; status-line / `Content-Length` / `Server` / keep-alive vs close;
  CRLF-in-header rejection; HEAD and 204 body rules; and a full request→well-formed-
  response demonstration. 14/14 checks pass (92 total across all suites).

#### RFC 003 — chunked decoder + full-request body assembly: implemented

Added:
- `Jemmet/Http/Chunked.lean` — the chunked transfer decoder and full-request body
  assembly. `parseChunkSize` reads a hex chunk-size line (extensions ignored but
  bounded; ≥1 hex digit required); `decodeChunked` reads size→data→CRLF chunks
  (bounded), accumulates the body under `maxBodyBytes`, consumes bounded trailers
  after the terminating `0` chunk, and rejects malformed framing (`badChunk`), an
  over-cap body (`bodyTooLarge`), or yields `needMore` on a short stream. `takeCRLF`
  (in `Bytes.lean`, via `takeN`) matches the post-data terminator exactly — binary
  chunk data cannot be line-scanned. `encodeChunked`/`encodeChunk` provide the
  response direction. `parseRequest` ties it together: head (RFC 004) → framing
  decision (RFC 003) → body consumed per framing (`none` / `contentLength n` /
  `chunked`) → a complete `HttpRequest` plus the carried remainder.
- `Limits` gains `maxBodyBytes` (1 MiB, → 413) and `maxChunkLineBytes` (→ 400);
  `ParseError` gains `badFraming`/`badChunk`/`bodyTooLarge` with status mapping.
- `Jemmet/Proofs/ChunkedBounds.lean` — **bounds safety over the body path**, extending
  the `ParseStep` story from the head to the whole request. With a `Fwd` (forward,
  buffer-preserving, in-bounds) reader relation and its transitivity:
  `takeCRLF_fwd`, `consumeTrailers_fwd`, `decodeChunked_fwd`, and `parseRequest_parsed`
  prove the decoder advances the reader only forward, never past the end, preserves the
  buffer (`rest.data = r0.data`), and leaves the remainder as an exact suffix — so the
  parser never drops, duplicates, or reorders bytes, even through a chunked body.
  Decoding is deterministic (a total function). Axiom-clean (`propext`, `Quot.sound`).
- `Test/HttpConformance.lean` gains a 15-case chunked+body group: encode→decode
  round-trips, multi-chunk in-order assembly, trailer handling, malformed rejections
  (bad hex size, missing post-data CRLF, over-long size line → 400), body-cap → 413,
  incomplete → `needMore`, Content-Length exact/short/over-cap, empty body, pipelined
  remainder after both CL and chunked bodies carried exactly, and CL.TE smuggling
  rejected on the full-request path. 44 HTTP checks (107 total across all suites).

This completes the request path (head **and** body) and the constructive,
no-drop/dup/reorder direction of RFC 003's raw-stream `FramingSound` over body
consumption. The full raw-stream composition (byte→normalization→boundary→body as one
theorem) remains the next M1 proof; its components are now all proven.

#### RFC 003 — raw-stream FramingSound: PROVEN (headline obligation met)

Added:
- `Jemmet/Proofs/FramingSoundStream.lean` — the **raw-stream `FramingSound` capstone**,
  assembling the proven components (single-message framing uniqueness from
  `FramingSound`, head `ParseStep` bounds from `ParserBounds`, body-path `Fwd` bounds
  from `ChunkedBounds`) into RFC 003's headline theorem over the whole pipeline
  (bytes → head → framing → body → remainder):
  - `parseRequest_trichotomy` — every input yields exactly one of `needMore` /
    `reject` / `parsed` (totality);
  - `parseRequest_deterministic` — a given input parses to a unique `(req, rest)`;
    there is never a second interpretation (no two conformant parties disagree);
  - `parseRequest_parsed_unique_framing` — a parsed request's body framing is exactly
    the unique, *accepted* `decideFraming` decision over its own headers, so ambiguous
    framing (CL+TE, conflicting CL, non-final/non-`chunked` TE) is never parsed with a
    guessed body — it is rejected;
  - `framing_sound_stream` / `framing_sound_stream_ofBytes` — the combined statement:
    needMore, or deterministic reject, or one consumed request with unique accepted
    framing whose remainder is the exact input suffix on a never-mutated buffer (no
    byte dropped, duplicated, or reordered).

  This is jemmet's no-smuggling / no-desync property, now over the **raw byte stream**
  rather than normalized `Headers` — resolving RFC 003's v1→v2 open question and its
  central security obligation. Axiom-clean (`propext`, `Quot.sound`); the smuggling +
  chunked corpus (44 HTTP checks) exercises it operationally.

#### RFC 007 — serve loop (keep-alive boundary) + KeepAlive proof: implemented

The transport-independent serve layer over the `Conn` abstraction (the iotakt
`runStepAuto` event loop wires on top in M2; this is the logic it drives).

Added:
- `Jemmet/Serve/ConnState.lean` — the per-connection phase (`reading`/`dispatching`/
  `writing`/`closing`/`closed`), the keep-alive policy (HTTP/1.1 persistent unless
  `Connection: close`; HTTP/1.0 the reverse), and the **pure request-boundary machine**:
  `nextRequest` parses exactly one request off the head; `drain` consumes every complete
  pipelined request in a buffer in order, leaving the partial remainder for the next
  read; a malformed request stops the drain (no resync — RFC 003 danger-zone rule).
- `Jemmet/Serve/Loop.lean` — `serveBuffer` (drain → route → run handler → keep-alive
  policy → serialize; an unserializable handler response becomes a 500, never a
  malformed wire response) and a `Conn`-generic driver (`recvAll`/`sendAll`/`driveConn`/
  `serveConn`): recv → process → send → keep-alive, carrying the pipelined remainder
  exactly. Works over any `Conn` instance, including `FakeConn`.
- `Jemmet/Proofs/KeepAlive.lean` — **KeepAlive** (the RFC 007 proof obligation,
  §3.2.7): `nextRequest_one_iff_parsed` (a boundary step is exactly one `parseRequest`,
  so each consumed unit is one complete, unambiguously-framed request),
  `nextRequest_one_fwd` (its remainder is the exact input suffix), and
  `drainAux_fwd`/`keepAlive_boundary` (draining a pipelined batch leaves the cursor at a
  forward position on the same never-mutated buffer — the carried remainder is exactly
  the unconsumed suffix, so requests are consumed strictly in order with nothing dropped,
  duplicated, or replayed). Builds on `parseRequest_parsed`. Axiom-clean
  (`propext`, `Quot.sound`).
- `Test/ServeConformance.lean` — the driver exercised through `FakeConn` (no sockets):
  pipelined keep-alive (two in-order responses), the keep-alive/close Connection policy,
  routing through the driver (404), a request split across reads reassembled via the
  carried remainder, and HTTP/1.0 default-close. 6/6 checks pass (113 total).

This completes the **pure** RFC 007 core and the last headline proof in the v0.1 set.
The iotakt-bound parts — the `runStepAuto` event loop, per-`FdKey` demux, stale-event
handling, and timeouts (RFC 008/014) — wire on top in M2 once iotakt is vendored.

#### RFC 014 — driver event-semantics model + M1.5 checkpoint: implemented

The highest-risk seam (the henret→iotakt event boundary) made a model-level contract,
testable without real iotakt — the gate that precedes binding `PlainIotaktConn`.

Added:
- `Jemmet/Serve/Event.lean` — the event-semantics model: `LoopEvent`
  (`newConnection`/`dataReady`/`tick`), the driver state keyed by `FdKey`, and
  `dispatchBatch` enforcing the contract — ordering (newConnection → I/O → tick),
  stale-event drop (an event for a torn-down/unknown key is dropped with a counter;
  generation-protected, so a reused raw fd with a new generation is a *different*
  `FdKey` with fresh state), readiness coalescing (each key stepped at most once per
  batch — fairness), idle-timeout sweep on `tick`, and write interest armed iff owned
  output is non-empty. `runTrace` is the deterministic fake event-trace runner.
- `Jemmet/Proofs/EventSemantics.lean` — the invariants: `no_step_after_remove` /
  `removeConn_find_none` / `stepConn_stale` (**no event is processed for a removed
  `FdKey`** — RFC 014's proof obligation), `addConn_live` (newConnection makes a key
  live for a same-batch `dataReady`), and `needsWrite_iff` (write-interest accounting,
  RFC 010). Axiom-clean (`propext`, `Quot.sound`).
- `Test/EventConformance.lean` — **the M1.5 adversarial event-trace suite**: stale event
  dropped, readiness coalesced to one step, I/O-before-tick ordering, close-then-reuse-
  raw-fd via generation (old gen dead / new gen live), stale event for a reused fd's old
  generation dropped, partial-write re-arm (drained ⇒ write interest off), idle-timeout
  close, batch ordering (newConnection before a same-batch dataReady that appears earlier
  in the list), and pipelined steps across batches. 9/9 pass (122 total).

This clears the **M1.5 driver-model checkpoint**: the event-trace runner passes the
adversarial suite and the no-stale / write-interest invariants are proven. With RFC 007
(keep-alive) and RFC 014 (event semantics) in place, the remaining serve-layer pieces
are the real-transport bindings.

#### RFC 008 — PlainIotaktConn: the iotakt transport binding (M2 begins)

jemmet's first real cross-project wiring: the `Conn` instance over iotakt, bound to
iotakt's **real Lean-only model types** — the verified core now meets the transport.

Added:
- `vendor/iotakt-0.13.1/` — iotakt vendored and **pinned as the frozen v1.0-equivalent**
  (RFC 001 decision recorded: the consumer surface is frozen and remaining iotakt work is
  additive-only, per the handoff). Built **Lean-only** via a stripped lakefile (the pure
  `Iotakt.Model`: `FdKey`/`IoEvent`/`IoErrno`/`ReadResult`/`WriteResult`); the native
  epoll backend + henret bridge are intentionally omitted and seamed in at deployment.
  Verified to build standalone in-sandbox (11 modules, no henret/no C toolchain).
- `Jemmet/Iotakt.lean` — `PlainIotaktConn σ`, the `Conn` instance over iotakt's model
  types. `FdKey` refinement is the identity on fields (iotakt's `{raw:Int, gen:Nat}`
  matches jemmet's stand-in). The native EventLoop ops sit behind `IotaktLoopOps σ` (the
  exact recvAck/sendAck/enableWrite/disableWrite/closeConnection surface over real
  model types), with `σ` threaded **functionally** — matching iotakt's functional
  EventLoop and resolving RFC 008 OQ1 (thread the loop, don't hold by reference). The
  result-case mappings (ReadResult/WriteResult/IoErrno → RecvOutcome/SendOutcome/
  ConnError) follow the binding spec; clean EOF is never an error. The write-interest
  invariant is enforced by construction: owned output is buffered, iotakt write interest
  tracks it exactly, and `ConnProgress.needsWrite ↔ ownedOutBytes > 0` after every op.
- `Test/IotaktConformance.lean` — RFC 008 conformance over a deterministic model loop
  (23 checks): readable-across-records via per-record ack, partial-write re-arm (quota 3
  over a 7-byte response — all bytes in order, interest held across partials then cleared
  once drained), two-connection FdKey demultiplexing, and the errno/EOF/close mappings;
  `ConnProgress.consistent` after every operation. The same `Conn` typeclass that every
  proof and `FakeConn` test targets, now satisfied by the real transport binding.
- `lakefile.toml` requires the vendored iotakt; the binding lives in its own
  `JemmetIotakt` library so the proven core stays transport-independent and
  dependency-free. `docs/compatibility.md` records the pin.

Serve-loop integration (RFC 007 over the real transport):
- `Jemmet/Iotakt.lean` also provides `serveOne` / `runServer` — the iotakt connection
  driver that reuses the transport-independent `serveConn` (RFC 007) over
  `PlainIotaktConn`. Because `serveConn` is generic over `[Conn κ]`, the proven parser/
  framing/router/serializer and the keep-alive serve loop run **verbatim** over the real
  binding; only the transport changes. The iotakt loop state is threaded through the
  whole drive. This is the handoff's worked shape (newConnection → serve → close); in
  deployment the accepted keys come from `EventLoop.runStepAuto`.
- `Test/IotaktConformance.lean` adds an end-to-end serve scenario (6 checks): a real
  `GET /a` parsed→routed→responded→serialized→written to the model socket as a correct
  `HTTP/1.1 200`, two connections served and demuxed to the right sinks, a pipelined pair
  answered on one keep-alive connection, and a `:param` route (`GET /users/42`). The full
  HTTP path now runs over the iotakt binding, not just `FakeConn`.

Phase-indexed interleaving driver (RFC 014 §3 fairness):
- `Jemmet/Iotakt.lean` adds `ServeDriver` — the driver that does **one bounded progress
  step per ready connection per `runStepAuto` batch** (vs `runServer`'s serve-to-
  completion), so a slow or pipelined connection cannot starve the others. Per-connection
  state (inbound carry, owned output, keep-alive, fairness/timeout bookkeeping) persists
  across batches; `dispatchBatch` imposes the RFC 014 ordering (accept → I/O coalesced
  one-step-per-key → timeout) and drops events for torn-down/unknown keys. This is the
  concrete implementation of the contract `EventSemantics` proves and `Event.lean`
  models, now over real HTTP serving.
- `Test/IotaktConformance.lean` adds an interleaving scenario (6 checks): a fast
  connection is served in the same batch a slow peer is still accumulating its request
  (no starvation); the slow connection completes on a later batch; both finish
  interleaved rather than serially; coalesced readiness yields exactly one step;
  unknown-key events are dropped; and accept is ordered before a same-batch readable.

#### RFC 010 — egress boundedness: PROVEN + model-checked

The mandatory v0.1 egress-slowloris safety property: a peer that refuses to drain a
response cannot force unbounded user-space buffering.

Added:
- `Jemmet/Serve/Egress.lean` — the three-tier accounting model (`EgressAccount`:
  jemmet-queued + connection-owned plaintext + TLS-owned ciphertext), the `withinBound`
  check, the `egressAdmits` backpressure decision (admit new output only below the cap),
  and `stepOwned` — the pure model of one driver step's effect on owned output.
- `Jemmet/Proofs/EgressBound.lean` — **proven**: `plaintext_total` / `plaintext_withinBound`
  (accounting soundness), `admits_iff_below` / `not_admits_at_cap` (the driver stops
  producing exactly when at the cap), `stepOwned_bounded` (one step preserves the bound),
  and the headline **`egress_invariant`** — over *any* sequence of steps each adding at
  most `maxStep`, owned output stays within `cap + maxStep`, a bound independent of how
  many requests the peer sends. Axiom-clean (`propext`, `Quot.sound`).
- `Jemmet/Iotakt.lean` — `ServeDriver.stepReadable` now applies RFC 010 backpressure: a
  `maxOwnedOut` cap gates production, so while owned output is at the cap the driver only
  drains (no recv/produce). The pure `egressAdmits` decision proven above is the gate.
- `Test/IotaktConformance.lean` — model-check (4 checks): a non-draining reader
  (`writeQuota 0`) flooded with 30 requests keeps owned output bounded (≤ cap + one
  response; does **not** grow with request count; backpressure halts production after a
  couple of steps), while a draining reader is served fully. The proven invariant, holding
  on the real driver.

Verification: `JemmetIotakt` builds against real iotakt types; clean rebuild reproduces;
cleanliness guard passes (0 sorry/axiom/unsafe across 36 jemmet files; the vendored
iotakt is third-party and out of jemmet's cleanliness scope); 145 conformance checks pass
(122 + 23). The native curl end-to-end test is a deployment step (gcc + epoll + henret);
the Lean logic it would exercise is the platform-neutral code proven/tested here, with a
~6-line `IotaktLoopOps Iotakt.Loop.EventLoop` adapter documented in RFC 008.


#### RFC 015 — handler execution policy: PROVEN + tested

The last structural piece of the effectful boundary: a slow or blocking *handler* must not
stall the driver loop.

Added:
- `Jemmet/Serve/HandlerPolicy.lean` — the policy model. `HandlerPhase`
  (`running deadline task` = RFC 015's `WaitingForHandler` / `ready` / `timedOut` /
  `cancelled`) with a total transition `stepHandler`: task hand-off keeps the loop free
  while a handler runs in a henret task; a `tick` past the deadline → `timedOut` (503); a
  `closeConn` → `cancelled`; and the terminal phases absorb every later event. Plus the
  bounded in-flight `HandlerPool` (spawn only below the cap, retire frees a slot).
- `Jemmet/Proofs/HandlerPolicy.lean` — **proven**: `deadline_fires` / `before_deadline`
  (the deadline fires exactly when elapsed, never early), `cancel_on_close` /
  `ready_close_drops`, `cancelled_absorbs` / **`no_late_response`** (a task completing
  after close produces no response), `timedOut_absorbs`, and the bounded-concurrency
  invariant **`pool_invariant`** (in-flight tasks never exceed the cap over any sequence
  of spawns/retires). Axiom-clean.
- `Test/HandlerConformance.lean` — adversarial (9 checks): a slow task on one connection
  leaves another free to complete (non-blocking); a deadline overrun times out; close
  cancels and a late completion is dropped; the in-flight count is capped and a retire
  frees a slot; the inline fast path is ready immediately without spawning; a failed
  handler becomes a 500.

The henret task API (spawn/poll/cancel) is reachable through iotakt in deployment; here
the phase machine is the pure contract (the analog of `IotaktLoopOps` for the transport).
If the task API is unavailable, v0.1 falls back to strict-inline handlers with the same
loop-enforced deadline — the `timedOut` transition is identical either way.


### M4 hardening — TESTED-tier fuzz harnesses

#### Fuzzers (RFC 003/004/011, Requirements §3.2.5)

The proofs establish the parser invariants abstractly; the fuzzers are the empirical
witness over a large adversarial corpus — the TESTED-tier complement to the PROVEN core.

Added `Test/Fuzz.lean` — a deterministic, reproducible (seeded 64-bit LCG) property-based
suite, **4200 iterations across 7 harnesses**, all green:
- request parser over pure-random bytes and over structured requests, and the
  request-line + header parser (`parseRequestHead`) directly: every input yields a defined
  `needMore`/`reject`/`parsed`, and on `parsed` the remainder offset stays within the
  (unchanged) buffer — bounds-safety and totality witnessed on real bytes;
- framing soundness / no-smuggling: random header sets carrying both Content-Length and
  Transfer-Encoding, or duplicate Content-Length, are always rejected (never an ambiguous
  accept);
- response serialization / no response-splitting: header values carrying CR/LF are always
  rejected rather than emitted (anti-splitting);
- chunked decoder over random bytes and structured chunk framings: defined result and
  in-bounds remainder, fuel-bounded.

Being deterministic, the harnesses are CI-suitable (RFC 012 gate) and reproduce exactly.









#### RFC 016 — production lifecycle completed (graceful shutdown, leak detection, failure modes)

Finishes the partial RFC 016 flagged by the audit. Server lifecycle is now a verified model
wired into the driver:

- **Server-level graceful shutdown (bounded drain).** New `Serve/Lifecycle.lean`: a
  `running → draining(deadline) → stopped` machine. `requestShutdown` stops accepting new
  connections; in-flight connections finish their current request and close (no new keep-alive
  request); the remainder still live at the deadline is force-closed. The driver consults the
  phase at its accept gate (`dispatchBatch`) and keep-alive gate (`stepReadable`), and
  `sweepTimeouts` performs the bounded force-close — mirroring the proven model.
- **Proven (9 new theorems, `Proofs/Lifecycle`).** Once draining the live set never grows
  (`no_growth_after_shutdown`, `accept_refused_not_running`); the drain is bounded and
  leak-free (`drain_deadline_forces_stop`, `no_leak_after_forced_stop`, `drain_empty_stops`);
  shutdown is idempotent and `stopped` is absorbing. Proven core: 94 → 103.
- **Resource-leak detection.** `LeakReport` (live connections, owned output, in-flight tasks)
  with `ServerState.audit` / `LeakReport.clean`; a forced stop is proven to leave zero live
  connections, complementing the proven `removeConn` table-drop.
- **Failure-modes doc.** New `docs/failure-modes.md`: an operator-facing catalog mapping every
  failure class (request, connection, handler, lifecycle, leak) to jemmet's deterministic
  response and its proof/test.
- **Conformance.** New `Test/LifecycleConformance` (17/17: 10 model + 7 driver). Default phase
  `running` keeps all existing behaviour and the 43 iotakt checks unchanged.

RFC 016 is now complete; the only RFC outstanding is 009 (TLS), gated on kroopt.

#### Audit pass — conformance gaps closed, dead code removed

A codebase audit (RFC fulfilment, dead code, tests↔requirements, code↔tests, docs↔code).
Findings acted on:

- **Serve-path error responses (RFC 010 / §3.4) — gap closed.** `serveBuffer` had ignored
  `drain`'s `DrainEnd`, silently dropping a rejected request instead of replying. The parser
  computed the right status (and `LimitConformance` verified it), but the loop never *sent*
  it. Added `errorResponse : ParseError → HttpResponse` (mapping each error to its `Status`,
  `Connection: close`) and made `serveBuffer` emit it and close on a malformed request — no
  resync (RFC 003 danger-zone rule). New `IntegrationConformance` checks (now 20): bad
  version→505, over-limit→413, smuggling→400, missing Host→400, and a valid-then-malformed
  pipeline→200 then 505, each closing; plus an exhaustive check that `errorResponse`'s code
  matches the proven `ParseError.statusCode`.
- **Handler deadline → 503 (RFC 015) — gap closed.** `stepHandler` produced a `.timedOut`
  phase that never rendered to a response, leaving `timeoutResponse` orphaned. Added
  `HandlerPhase.response` (ready→its response, timedOut→503, else none) and defined `writes`
  as `response.isSome`. New `HandlerConformance` checks (now 11): a timeout renders a 503, a
  cancelled phase renders nothing.
- **Dead code removed:** `Bytes.peek?` (orphan reader primitive) and `Iotakt.toIotaktKey`
  (the driver holds iotakt `FdKey`s natively, so the reverse translation was never used).
  Kept: `StreamSource.ofList` (the documented RFC 005 handler-streaming interface, awaiting
  driver integration) and the `Status` vocabulary table (now fully used by `errorResponse`).
- **Docs reconciled with code:** the proof/trust/test matrix's stale `IotaktConformance`
  counts (35/35, 39/39 → 43/43 across 8 scenarios incl. ingress read-timeout), the
  `statusCode_*` count (×9 → ×10), and the `IntegrationConformance`/`HandlerConformance`
  counts (→ 20/20, 11/11).
- **Noted as partial (not claimed done):** RFC 016 — observability, the compatibility
  matrix, and connection-level graceful close are in; server-level graceful shutdown (drain
  on signal), resource-leak detection, and a dedicated failure-modes doc remain.

#### RFC 011/012 — external HTTP/1.1 interop/conformance corpus

A curated, named corpus of adversarial and real-world request vectors run through the full
parse → frame → route → respond path — the h2spec-style conformance suite for HTTP/1.1.

Added `Test/InteropCorpus.lean` (53 vectors), each with a spec-justified expected outcome:
- **smuggling/desync** (14): CL+TE, dup/list Content-Length, non-chunked/compound/duplicate
  Transfer-Encoding, malformed chunk framing — all rejected (no guessing);
- **injection/splitting** (3): bare CR in value, whitespace-before-colon, obs-fold — rejected;
- **line discipline** (4): bare-LF endings and empty request line rejected; truncated/empty
  input → needMore;
- **method/version/target** (10): unknown/lowercase methods parse; 0.9/2.0/1.2 → 505;
  malformed request lines and empty targets → 400; asterisk-form and absolute-form parse;
- **Host** (5): the RFC 9112 §3.2 rule (see below);
- **valid framing** (10): CL/chunked/trailers, OWS-padded values, case-insensitive coding,
  HTAB in values, percent-encoded paths, HTTP/1.0 keep-alive — all parse;
- **full path** (5): GET→200, param route→200, unknown→404, wrong method→405, smuggling
  short-circuits to 400 before routing;
- **pipelining** (2): two requests in one buffer (remainder is exactly the second); a
  request split mid-headers → needMore.

**Conformance fix found by the corpus** — RFC 9112 §3.2 Host enforcement: an HTTP/1.1
request with no Host header (or a duplicate Host) is now rejected with 400 (`badHost`),
where before it parsed. Added the `badHost` parse error (statusCode 400, pinned in
`LimitStatus`), the check in `parseRequest`, and updated the `parseRequest` structure proofs
(`ChunkedBounds`, `FramingSoundStream`) for the new branch. Existing test vectors that had
omitted Host were corrected.

#### RFC 015 — handler hand-off validated over real henret

The handler hand-off was proven over an abstract `HandlerPhase` model with an ASSUMED henret
task API. With henret 0.15.2 in hand, that seam is now validated against the real runtime.

Added:
- `vendor/henret-0.15.2/` — henret's Lean-only actor/task runtime core, vendored with a
  stripped lakefile (no `Henret.Native`, no exes, no C compiler). Builds standalone.
- `Jemmet/Henret.lean` (`JemmetHenret` library, the only library that depends on henret) —
  `handlerPhaseOf` maps henret's concrete `TaskState` onto jemmet's `HandlerPhase`, and
  `writesResponse` derives the write-decision. Local lemmas: a cancelled handler never
  writes, a completed handler writes its response, an in-flight handler writes nothing.
- `Test/HenretConformance.lean` — 8 checks driving the **real** `Henret.step` scheduler:
  complete → `completed` → writes a response; cancel → `cancelled` → no response; fail →
  `failed` → writes a 500; running → in flight → nothing yet; **terminal permanence** (a
  late complete after cancel, or late cancel after complete, is rejected and the state is
  unchanged — jemmet's "no late response after close", enforced by henret's proven-terminal
  states); and the sleep/tick deadline timer the `WaitingForHandler` path relies on.

This confirms RFC 015's default task-handoff path is viable against real henret (not the
strict-inline fallback), and `docs/compatibility.md` records the henret 0.15.2 pin. The
jemmet core and its proven theorems remain dependency-free; only `JemmetHenret` imports
henret, mirroring the `JemmetIotakt` isolation.

#### RFC 016 — redacted observability

A structured access log that is safe to point at the open internet: it cannot leak secrets
and cannot be forged by attacker-controlled input.

Added:
- `Jemmet/Observe.lean` — `AccessRecord` carries only safe fields (connection id, secure
  flag, a fixed method token, the request path, status, byte counts, timing); it has no
  field for header values or body bytes, and `ofExchange` reads only `req.method` and
  `req.target.path` — never `req.headers`/`req.body`. Query strings are not logged (secrets
  ride in query params) and unknown methods collapse to `OTHER`. `render` runs a final
  control-character scrub over the assembled line.
- `Jemmet/Proofs/ObserveSafe.lean` — **proven**: the sanitizer strips every control
  character (`sanitize_no_ctl`), so a rendered line contains neither LF nor CR
  (`render_no_newline`) — an attacker cannot forge a second log entry. Axiom-clean.
- `Test/ObserveConformance.lean` — 13 checks against a hostile request (CRLF-injected path,
  secret Authorization/Cookie headers, secret body, secret query): the line stays single,
  leaks none of the secrets, drops the query, collapses the odd method, and keeps the safe
  fields.

Injection-freedom is proven; leak-freedom is by construction (the record type) and tested.

#### RFC 010 — limit/timeout matrix

Turns the safe-default resource limits into an exhaustively-checked status mapping, and adds
the ingress (read-side) timeout to complement the egress bound already in place.

Added:
- `Jemmet/Proofs/LimitStatus.lean` — **proven**: every `ParseError` maps to a single,
  deterministic status (`uriTooLong`→414, `badVersion`→505, `headerFieldsTooLarge`→431,
  `bodyTooLarge`→413, the rest→400), and `statusCode_is_error` proves the whole map lands
  in the 4xx/5xx range — never a 2xx/3xx, never undefined. A regression that changed a code
  now fails the build. Axiom-clean.
- `Test/LimitConformance.lean` — the exhaustive limit/status matrix (14 checks): each
  configured limit (request-line length→414, header line/count/total bytes→431, body size
  via Content-Length and chunked→413, chunk-line length→400, version→505, CL+TE and
  duplicate CL→400) is exercised at its boundary; at/under-limit inputs parse, over-limit
  inputs reject with the documented code.
- Ingress read timeout (slowloris defense) in `ServeDriver`: a `requestStartedAt` clock per
  connection (set on accept, reset only when a request *completes*) and a `readTimeout`. A
  connection trickling a partial request keeps `lastActive` fresh but not `requestStartedAt`,
  so `connTimedOut` closes it once it passes the read deadline — while a completed request
  resets the clock and an idle keep-alive connection still times out on the idle basis.
  Four new conformance checks in `Test/IotaktConformance.lean` cover all four cases.

This is the read-side counterpart to the proven egress bound: ingress is now bounded in
time (slow requests can't pin a connection), egress in space (owned output stays under cap).

#### RFC 005 — chunked response streaming

Large or generated bodies must not be fully serialized before backpressure applies. This
adds the streaming interface that lets the RFC 010 egress bound hold for big responses.

Added:
- `Jemmet/Http/Stream.lean` — a pull-based streaming body: `ChunkStream` (the chunks to
  emit), `encodeStream` (the whole body as a round-trip oracle), `streamStep` (emit exactly
  one chunk's framing, or the terminator when done — never materializing more than one
  chunk), and `StreamSource = IO (Option ByteArray)` with a list-backed `ofList` for tests.
- `Jemmet/Proofs/StreamBound.lean` — **proven**: `streamStep_single` (a step emits exactly
  one `encodeChunk`, not the whole body — so streaming feeds the egress invariant one
  bounded addition at a time), `streamStep_progress` (each step shortens the stream →
  termination), `encodeStream_terminated` (output is always terminator-framed), and the
  step characterisations. Axiom-clean.
- `Test/Fuzz.lean` — two new harnesses (1200 iterations): the encode→decode **round-trip**
  (a streamed body decodes back to its concatenation via the proven decoder — the encoder
  and decoder are inverse), and the **peak-owned bound** (streaming one chunk at a time
  with a flush between never holds the whole body; peak owned < full body for ≥2 chunks).

Together with the proven `egress_invariant`, this closes the loop: a large response streams
in bounded chunks, each a single bounded addition, so owned output stays within the cap.

#### RFC 012 — CI / release gate + matrix-honesty guard

Ties everything that exists into one honest green check, and makes the "PROVEN" claim
machine-checkable rather than a promise.

Added:
- `scripts/check-axioms.py` — the **matrix-honesty guard**. Stronger than the cleanliness
  grep: it checks the *compiled* axiom dependency of every theorem in the proven core
  (via `#print axioms`), failing the build if any theorem depends on `sorryAx` or any
  axiom outside the whitelist `{propext, Quot.sound, Classical.choice}`. It skips
  comment text and reports the verified theorem count. Confirmed non-vacuous by a negative
  test (narrowing the whitelist flags the expected theorems). Today: **73 proven theorems,
  all axiom-clean.**
- `scripts/ci.sh` — the RFC 012 gate: cleanliness guard → build core → build proofs →
  build the iotakt binding → matrix-honesty guard → conformance suite + fuzz harnesses.
  Fails closed (any step stops the gate). Runs from a clean tree to a single PASS.

This is what lets the proof-trust-test matrix be honest: the matrix cannot list a PROVEN
theorem the kernel did not actually check axiom-cleanly, and the guard is wired into the
gate so a regression that smuggled in a `sorry` (even via a tactic) would fail CI.

Pending (next, tracked in the proof-trust-test matrix):
- Bind the RFC 014 model driver to iotakt's real `runStepAuto` `EventLoop` (the native
  serve-loop wiring) behind the same `IotaktLoopOps` seam; RFC 010 egress-boundedness
  model check; RFC 015 handler task-handoff; TESTED-tier fuzzers; chunked **response**
  streaming.
