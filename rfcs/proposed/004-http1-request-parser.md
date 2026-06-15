# RFC 004: HTTP/1.1 request parser and bounds safety

## Status
Proposed (revised per senior review v1→v2)

## Summary
The bounds-safe byte reader and the HTTP/1.1 request-line + header parser, the
`HttpRequest` model, header name/value validation, and request limits — with
bounds safety proven by construction.

## Motivation
The parser is jemmet's first contact with attacker-controlled bytes. Out-of-bounds
reads, header injection, and unbounded inputs are all parser-level threats
(Requirements §3.2.2/§3.2.4/§3.2.5). The parser must be safe by construction, not
by testing alone.

## Goals
1. A byte reader whose every read is length-checked (bounds-safe by construction).
2. Parse the request line (method, origin-form target, version) and headers.
3. Validate header names/values (reject control chars / embedded CR/LF).
4. Enforce request-line, header-count, and header-size limits (→ 400/414/431).
5. Produce a clean `HttpRequest`; hand framing to RFC 003.

## Non-Goals
Body framing decision (RFC 003); response (RFC 005); routing (RFC 006).

## External Design
```lean
structure HttpRequest where
  method : Method ; target : RequestTarget ; version : Version
  headers : Headers ; framing : BodyFraming ; body : ByteArray
def parseRequestHead : ByteReader → Except ParseError (RequestLine × Headers × ByteReader)
```
- `ByteReader` exposes `takeLine`/`takeN`/`peek` that return `none`/`needMore`
  rather than ever indexing out of bounds.
- Request line over the configured max length → 414 (URI too long) / 400.
- Header count over max, or total header bytes over max → 431.
- Header name: token chars only; value: visible + space/tab, no bare CR/LF, no NUL
  → else 400.
- Incomplete input ⇒ `needMore` (the serve loop reads more); never partial parse.

## Proof Obligations
1. `ParserBounds`: every `ByteReader` operation accesses only indices `< size`
   (bounds-safe by construction); the parser is total over all byte inputs.
2. `ParseStep` (added per review — bounds safety alone does not justify protocol
   safety): each `parseStep` either (a) consumes no bytes and needs more input, or
   (b) consumes a positive, bounded prefix and returns exactly one semantic result,
   or (c) rejects deterministically; and it **never drops, duplicates, or reorders
   bytes**. This is essential for split reads across `recv` boundaries and feeds the
   raw-stream `FramingSound` theorem (RFC 003).

## Test Obligations
Malformed-input corpus (bad request lines, header injection, oversized inputs,
split reads across `recv` boundaries); header-injection rejection; fuzzers over the
request-line and header parsers.

## Trust / Assumption Changes
None.

## Acceptance Criteria
Parser + reader implemented; `ParserBounds` proven (no `sorry`/`axiom`/`unsafe`);
limit handling returns the right status; fuzzers run clean.

## Alternatives Considered
- *Index-based parsing with runtime bounds checks only:* rejected — safety by
  construction is provable and avoids partial-state bugs.
- *Reuse iotakt's `Http` parser:* rejected (RFC 001) — jemmet owns its parser.

## Open Questions
1. `Headers` representation and its adversarial-complexity bound (assoc list vs
   bounded map) — coordinate with RFC 006's routing keys.
2. Whether to canonicalize header names at parse time or at access time.
