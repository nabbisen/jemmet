# jemmet — proof / trust / test matrix

RFC 011's living record of what jemmet **proves**, what it **tests**, what it
**assumes**, and what is **out of scope** — kept honest as the project grows. This
snapshot covers M0 (RFC 002) and the M1 pure core (RFC 004 parser, the RFC 003 framing
engine, RFC 006 routing, and RFC 005 response serialization).

The cleanliness guard (`scripts/check-cleanliness.py`) asserts no project-local
`sorry` / `axiom` / `unsafe` in `Jemmet/` or `Test/`. All theorems below depend only
on Lean's foundational axioms (`propext`, `Quot.sound`), confirmed via
`#print axioms`.

## PROVEN (machine-checked)

| Property | Theorem(s) | Module | RFC |
|---|---|---|---|
| FakeConn determinism (op = `pure` of pure transition; exact replay) | `runIO_eq_pure`, `stepIO_eq_pure` | `Proofs/ConnFakeDet` | 002 |
| Framing decision is single-valued | `framing_unique` | `Proofs/FramingSound` | 003 |
| CL+TE ambiguity is rejected, never resolved to a boundary | `framing_reject_both`, `framing_no_ambiguous_accept` | `Proofs/FramingSound` | 003 |
| "No body" acceptance implies no CL/TE | `framing_ok_none` | `Proofs/FramingSound` | 003 |
| Byte access is in-bounds (the only accessor) | `byteAt_some_lt`, `byteAt_none_ge` | `Proofs/ParserBounds` | 004 |
| Reader invariant `off ≤ size` preserved by every transition | `ofBytes_wf`, `advance_wf`, `takeN_step`, `takeLine_step`, `scanLine_step` | `Proofs/ParserBounds` | 004 |
| ParseStep: head parse is monotone, bounded, buffer-preserving; remainder is exactly the input suffix | `parseRequestHead_parsed`, `parseRequestHead_remainder` | `Proofs/ParserBounds` | 004 |
| Dispatch is total: every request resolves to exactly one outcome | `dispatch_trichotomy` | `Proofs/RouterTotal` | 006 |
| `found`/`notFound` are sound (real matching route / genuinely no path match) | `dispatch_found_sound`, `dispatch_notFound_sound`, `findHandler_sound`, `allowedMethods_nil` | `Proofs/RouterTotal` | 006 |
| Anti-injection: every emitted handler header is CR/LF/CTL-free (else rejected) | `validateHandlerHeaders_clean`, `serialize_ok_handlers_validated` | `Proofs/ResponseWf` | 005 |
| Framing header is Content-Length xor chunked, and absent for bodyless statuses | `framingHeaders_le_one`, `framingHeaders_disallowed` | `Proofs/ResponseWf` | 005 |
| Body path is forward, buffer-preserving, in-bounds; chunked decode never drops/dups/reorders | `decodeChunked_fwd`, `consumeTrailers_fwd`, `takeCRLF_fwd` | `Proofs/ChunkedBounds` | 003 |
| Full request (head+body) consumes a forward bounded prefix; remainder is an exact suffix | `parseRequest_parsed` | `Proofs/ChunkedBounds` | 003/004 |
| **Raw-stream FramingSound**: total; deterministic (no second interpretation); parsed framing is the unique accepted decision (ambiguous framing rejects); remainder is the exact suffix (no drop/dup/reorder) | `framing_sound_stream`, `parseRequest_trichotomy`, `parseRequest_deterministic`, `parseRequest_parsed_unique_framing` | `Proofs/FramingSoundStream` | 003 |
| **KeepAlive boundary**: each step is one complete request; pipelined remainder carried exactly (forward suffix, same buffer) — no boundary confusion on reuse | `keepAlive_boundary`, `drainAux_fwd`, `nextRequest_one_fwd`, `nextRequest_one_iff_parsed` | `Proofs/KeepAlive` | 007 |
| **No event for a removed `FdKey`**: stale `dataReady`/`tick` dropped, never stepped (generation-protected); write interest iff owned output > 0 | `no_step_after_remove`, `removeConn_find_none`, `stepConn_stale`, `addConn_live`, `needsWrite_iff` | `Proofs/EventSemantics` | 014 |

## TESTED (executable conformance)

| Area | Where | Result |
|---|---|---|
| `Conn` interface conformance (would-block, split reads, partial send/retry, flush, close, EOF/error), `ConnProgress.consistent` after every op | `Test/Conformance` | 49/49 |
| Valid request framing (none / Content-Length / chunked; HTTP/1.0; case-insensitive names) | `Test/HttpConformance` | pass |
| Smuggling corpus refused (CL.TE, TE.CL, dup-CL, obfuscated length, non-chunked TE) | `Test/HttpConformance` | pass |
| Parser rejection (bare-LF, obs-fold, ws-before-colon, control-byte injection, bad version, malformed line) | `Test/HttpConformance` | pass |
| Limits → status (414 / 431) and split reads → `needMore` with exact pipelined remainder | `Test/HttpConformance` | pass |
| Routing (static/param/404/405-with-Allow), serialization (status line/CL/keep-alive/close/HEAD/204), CRLF-injection rejection, and end-to-end parse→route→respond→serialize | `Test/IntegrationConformance` | 14/14 |
| Chunked decode (round-trip, multi-chunk, trailers, malformed→400, over-cap→413, incomplete→needMore), Content-Length assembly, pipelined remainder, CL.TE on full path | `Test/HttpConformance` (chunked+body) | 15/15 |
| Serve loop over `FakeConn`: pipelined keep-alive (in-order responses), Connection close/keep-alive policy, 404 routing, request split across reads, HTTP/1.0 default-close | `Test/ServeConformance` | 6/6 |
| Adversarial event-trace (M1.5): stale-drop, coalescing, I/O-before-tick, close-then-reuse-fd by generation, partial-write re-arm, idle-timeout, batch ordering | `Test/EventConformance` | 9/9 |

## ASSUMED (siblings / platform; proven+tested in their own matrices)

- iotakt — non-blocking I/O correctness, fd lifecycle, `FdKey` identity filtering.
- kroopt — TLS 1.3 correctness, no early/unauthenticated plaintext.
- The Lean runtime and toolchain.

## OUTSCOPE

- Cryptographic security (kroopt / HACL\*); kernel / TCP behavior; volumetric
  network DoS; application-level authn/authz and handler correctness.

## PENDING (declared, not yet proven)

- **Fuzz harnesses** over the full byte→boundary pipeline and the chunked decoder — a
  TESTED obligation in RFC 003/004, distinct from the now-proven raw-stream theorem.
- `framing_ok_cl` witness lemma (accepted Content-Length ⇒ a single well-formed
  length); chunked **response** body streaming (`ChunkSource`).
- Byte-level status-line well-formedness for `serialize` is currently covered by the
  integration goldens; a `serialize`-output structural theorem is a candidate to
  promote from tested to proven.
- Keep-alive boundary (RFC 007), serve loop (RFC 007), `PlainIotaktConn` (RFC 008).

The M1 proof obligations are complete, RFC 007's keep-alive boundary is proven, and the
**M1.5 driver-model checkpoint is cleared**: the fake event-trace runner passes the
adversarial suite and the no-stale-event / write-interest invariants are proven. The
pure serve layer (RFC 007 keep-alive + RFC 014 event semantics) runs and is model-
checked over `FakeConn` end-to-end. What remains is M2 — the real-transport phase:
`PlainIotaktConn` (RFC 008) and binding the model driver to iotakt's `runStepAuto`
`EventLoop`, plus RFC 010 egress-boundedness, RFC 015 handler hand-off, and fuzzers.
