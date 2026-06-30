# RFC 003: HTTP framing soundness and smuggling defense

## Status
Implemented (M1 — framing soundness / no-smuggling proven over the raw stream)

## Summary
Defines jemmet's HTTP/1.1 framing and the **raw-stream** proof that, for any finite
byte prefix and parser state, jemmet either needs more bytes, rejects
deterministically, or consumes exactly one request and returns a uniquely defined
remainder. The headline security property — strengthened from "over normalized
`Headers`" to "over the raw incremental byte stream," because smuggling lives in
the normalization pipeline, *before* `Headers` exist.

## Motivation
Request smuggling/desync is the defining attack. The review's red-team point: the
v1 target `decideFraming : Headers → …` is necessary but not sufficient, because
the dangerous ambiguities are in line parsing, header normalization, whitespace,
duplicate/case-insensitive names, `Transfer-Encoding` list parsing, and chunked
decoding — i.e. *getting to* `Headers`. The believable property is over raw bytes.

## Goals
1. Single-valued framing decision with explicit rejection (as v1).
2. A **raw-stream unique-boundary-or-reject** theorem over the full pipeline.
3. Explicit handling of the known danger zones.

## Non-Goals
Body content interpretation; routing; TLS framing.

## External Design
Pipeline: `raw bytes → line parse → header name/value validation →
case-insensitive duplicate normalization → whitespace handling → Transfer-Encoding
list parse → Content-Length parse → body consumption → pipelined remainder`.
Decision (`decideFraming`, single-valued; reject, never guess): reject CL+TE;
reject multiple/conflicting CL; accept only chunked-as-final TE; single valid CL →
`contentLength n`; neither → `none`.
Danger zones handled explicitly (all → reject, deterministically): whitespace
before the header colon; case-insensitive duplicate names; comma-separated TE
values (only `chunked`, only last); obs-fold/legacy folded headers (reject);
**bare LF vs CRLF** (define one line discipline; reject the other or normalize
once, consistently); leading/trailing whitespace around the CL number; chunk
extensions and trailers (bounded; ignore extensions, validate trailers); pipelined
remainder after a malformed chunked body (reject + close, do not resync);
HTTP/1.0 keep-alive (no close-delimited request bodies — reject ambiguous 1.0
request bodies).

## Proof Obligations
`FramingSound` (raw-stream): for any finite byte prefix `p` and parser state `s`,
`parse s p` returns exactly one of:
- `needMore` (a strict extension of `p` could still parse), or
- `reject e` (no extension parses), or
- `consumed req rest` where `req` is one complete request and `rest` is the unique
  remainder, and `p = encode(req) ++ rest'` with `rest` the carried remainder —
**no input yields two different `(req, rest)` interpretations** (no two conformant
parties disagree about boundaries) and the parser never drops, duplicates, or
reorders bytes. The single-message `decideFraming` uniqueness is a lemma; the
theorem is over the stream.

## Test Obligations
A smuggling-vector corpus (CL.TE, TE.CL, duplicate/space-obfuscated headers,
bare-LF, obs-fold, chunk-size tricks, trailer tricks) all rejected; chunked edge
cases; fuzzers over the full byte→boundary pipeline and the chunked decoder.

## Trust / Assumption Changes
None.

## Acceptance Criteria
The pipeline implemented with the danger-zone rules; the **raw-stream**
`FramingSound` theorem proven (no project-local `sorry`/`axiom`/`unsafe`); the
smuggling corpus passes; fuzzers run clean. (Resolves the v1 open question: prove
over the full pipeline, not `decideFraming` alone.)

## Alternatives Considered
- *Best-effort framing / prefer-TE-over-CL:* rejected — "prefer" is the
  disagreement smuggling exploits.
- *Prove only over normalized `Headers`:* rejected per review — misses the
  normalization-stage attacks.

## Open Questions
1. Whether to additionally formalize tokenization of header names/values as a
   separate proven lemma feeding the stream theorem (likely yes).
