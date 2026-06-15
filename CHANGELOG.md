# Changelog

All notable changes to jemmet are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); jemmet releases as version-named
tarballs at logical breakpoints (RFC 012).

## [Unreleased]

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

Pending (next increments, tracked honestly in the proof-trust-test matrix):
- Fuzz harnesses over the full byte→boundary pipeline and the chunked decoder (a
  TESTED obligation, distinct from the now-proven theorem).
- `framing_ok_cl` witness lemma; chunked **response** body streaming (`ChunkSource`);
  a byte-level `serialize` status-line structural theorem (promote from goldens).
- Then M2: keep-alive boundary + serve loop (RFC 007), `PlainIotaktConn` (RFC 008).
