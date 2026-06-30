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
| **Egress boundedness** (RFC 010): owned user-space output stays within `cap + maxStep` over any step sequence — a non-draining peer cannot buffer unboundedly; three-tier accounting sound | `egress_invariant`, `stepOwned_bounded`, `plaintext_total`, `not_admits_at_cap`, `admits_iff_below` | `Proofs/EgressBound` | 010 |
| **Handler policy** (RFC 015): deadline fires exactly when elapsed; close cancels; terminal phases absorb later events (**no late response after close**); in-flight tasks ≤ cap | `pool_invariant`, `no_late_response`, `deadline_fires`, `before_deadline`, `cancelled_absorbs`, `timedOut_absorbs` | `Proofs/HandlerPolicy` | 015 |
| **Access-log injection defense** (RFC 016): the sanitizer strips all control chars; a rendered line has no CR/LF | `sanitize_no_ctl`, `render_no_newline`, `sanitizeChar_not_ctl` | `Proofs/ObserveSafe` | 016 |
| **Production lifecycle** (RFC 016): graceful shutdown is bounded and leak-free — once draining, no new accept and no new keep-alive request (the live set never grows); past the deadline the remainder is force-closed and the server reaches `stopped` with zero live connections; `stopped` absorbs all later events; shutdown is idempotent | `accept_running`, `accept_refused_not_running`, `shutdown_begins_drain`, `shutdown_idempotent`, `drain_deadline_forces_stop`, `drain_empty_stops`, `stopped_absorbing`, `no_growth_after_shutdown`, `no_leak_after_forced_stop` | `Proofs/Lifecycle` | 016 |
| **Limit→status mapping** (RFC 010): every parse error maps to a fixed status; all are 4xx/5xx | `statusCode_*` (×10), `statusCode_is_error` | `Proofs/LimitStatus` | 010 |
| **Chunked streaming** (RFC 005): a step emits exactly one chunk (never the whole body); streaming terminates; output is terminator-framed | `streamStep_single`, `streamStep_progress`, `encodeStream_terminated`, `streamStep_chunk` | `Proofs/StreamBound` | 005 |

## TESTED (executable conformance)

| Area | Where | Result |
|---|---|---|
| `Conn` interface conformance (would-block, split reads, partial send/retry, flush, close, EOF/error), `ConnProgress.consistent` after every op | `Test/Conformance` | 49/49 |
| Valid request framing (none / Content-Length / chunked; HTTP/1.0; case-insensitive names) | `Test/HttpConformance` | pass |
| Smuggling corpus refused (CL.TE, TE.CL, dup-CL, obfuscated length, non-chunked TE) | `Test/HttpConformance` | pass |
| Parser rejection (bare-LF, obs-fold, ws-before-colon, control-byte injection, bad version, malformed line) | `Test/HttpConformance` | pass |
| Limits → status (414 / 431) and split reads → `needMore` with exact pipelined remainder | `Test/HttpConformance` | pass |
| Routing (static/param/404/405-with-Allow), serialization (status line/CL/keep-alive/close/HEAD/204), CRLF-injection rejection, and end-to-end parse→route→respond→serialize | `Test/IntegrationConformance` | 20/20 |
| Chunked decode (round-trip, multi-chunk, trailers, malformed→400, over-cap→413, incomplete→needMore), Content-Length assembly, pipelined remainder, CL.TE on full path | `Test/HttpConformance` (chunked+body) | 15/15 |
| Serve loop over `FakeConn`: pipelined keep-alive (in-order responses), Connection close/keep-alive policy, 404 routing, request split across reads, HTTP/1.0 default-close | `Test/ServeConformance` | 6/6 |
| Adversarial event-trace (M1.5): stale-drop, coalescing, I/O-before-tick, close-then-reuse-fd by generation, partial-write re-arm, idle-timeout, batch ordering | `Test/EventConformance` | 9/9 |
| **iotakt binding** (RFC 008) over a model loop: readable-across-records via ack, partial-write re-arm + write-interest invariant, two-connection FdKey demux, errno/EOF/close mapping, `ConnProgress.consistent` per op; **end-to-end serve** (RFC 007 over the real binding): GET→route→respond→serialize→socket, two-connection demux, pipelined keep-alive, `:param` route; **interleaving driver** (RFC 014 §3): no-starvation/fairness, lockstep completion, coalescing, stale-drop, accept-ordering | `Test/IotaktConformance` | 43/43 (8 scenarios) |
| **Egress backpressure** (RFC 010) model-check: a non-draining reader flooded with requests keeps owned output bounded (≤ cap+resp, no growth with request count); a draining reader served fully | `Test/IotaktConformance` | incl. egress + ingress read-timeout (RFC 010) |
| **Handler policy** (RFC 015): slow task doesn't block another conn, deadline timeout, close-drops-late-response, in-flight cap, inline fast path, failed→500 | `Test/HandlerConformance` | 11/11 |
| **Fuzzers** (TESTED, §3.2.5): request/header parser + chunked decoder bounds-safety, framing no-smuggling, response no-splitting — deterministic, reproducible | `Test/LimitConformance` | 14 checks (limit/status matrix) |
| `Test/ObserveConformance` | 13 checks (redacted access log) |
| `Test/LifecycleConformance` | 17 checks (graceful-shutdown model + driver wiring + leak audit) |
| **Handler hand-off over real henret** (RFC 015): drives `Henret.step` — complete→response, cancel→no response (no late response after close), fail→500, in-flight→nothing, terminal-permanence of completed/cancelled, sleep/tick deadline timer | `Test/HenretConformance` | 8/8 |
| **HTTP/1.1 interop corpus** (RFC 011/012): 53 adversarial + valid vectors through parse→frame→route→respond — smuggling, injection, line-discipline, method/version/target, Host (RFC 9112 §3.2), valid framing, routing, pipelining | `Test/InteropCorpus` | 53/53 |
| `Test/Fuzz` | 5400 iters / 9 harnesses |

## ASSUMED (siblings / platform; proven+tested in their own matrices)

- iotakt — non-blocking I/O correctness, fd lifecycle, `FdKey` identity filtering.
- henret — actor/task runtime correctness (proven+tested in henret's own matrix). The RFC 015 hand-off seam is no longer purely assumed: `JemmetHenret` + `Test/HenretConformance` validate jemmet's handler-phase mapping against the real `Henret.step` runtime, including henret's terminal-state permanence.
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

The M1 proof obligations are complete, RFC 007's keep-alive boundary is proven, the
**M1.5 driver-model checkpoint is cleared**, and **M2 has begun**: iotakt 0.13.1 is
vendored (Lean-only core, pinned per RFC 001) and `PlainIotaktConn` (RFC 008) binds
jemmet's `Conn` typeclass to iotakt's real model types — verified over a deterministic
model loop (ack discipline, partial-write re-arm, FdKey demux, error mapping). The same
`Conn` interface that every proof and `FakeConn` test targets is now satisfied by the
real transport binding. What remains in M2: wiring the RFC 014 model driver to iotakt's
native `runStepAuto` `EventLoop` (behind the same `IotaktLoopOps` seam; the curl E2E is a
deployment step), plus RFC 010 egress-boundedness, RFC 015 handler hand-off, and fuzzers.

> **Matrix-honesty guard (RFC 012).** The PROVEN rows above are machine-verified: `scripts/check-axioms.py` checks the compiled axiom dependency of every proven-core theorem and fails if any depends on `sorryAx` or a non-whitelisted axiom. Current status: **103 proven theorems, all axiom-clean** (whitelist `propext`, `Quot.sound`, `Classical.choice`). The full gate is `scripts/ci.sh`: cleanliness → build → proofs → matrix-honesty → conformance + fuzz.
