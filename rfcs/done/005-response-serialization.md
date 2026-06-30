# RFC 005: Response model and HTTP/1.1 serialization

## Status
Implemented (M1 — HTTP/1.1 response serialization + chunked streaming; well-formedness proven)

## Summary
The `HttpResponse` model and its serialization to a correct HTTP/1.1 byte stream,
superseding iotakt's `HTTP/1.0` stand-in, with output validation that prevents
response splitting/header injection.

## Motivation
Responses must be well-formed HTTP/1.1 and must not let handler-supplied data
inject header or status structure (Requirements §3.2.2). iotakt's stand-ind emits
an `HTTP/1.0` status line; jemmet owns and corrects this.

## Goals
1. `HttpResponse` with status, headers, body (fixed or chunked), keep-alive flag.
2. Serialize a correct `HTTP/1.1 <code> <reason>` status line and headers.
3. Auto-manage `Date`, `Server`, and `Content-Length`/`Transfer-Encoding: chunked`.
4. Emit keep-alive `Connection` consistent with the negotiated policy.
5. Validate/encode all emitted header values (no CR/LF injection).

## Non-Goals
Parsing (RFC 004); routing (RFC 006); content negotiation/compression (v0.1).

## HTTP/1.1 semantic rules (added per review)
Beyond well-formedness, serialization MUST enforce message-body semantics so jemmet
does not create protocol-level desync or client-compat issues:
- `HEAD` responses: emit headers as if the body existed (incl. `Content-Length`),
  but emit no body;
- `1xx`, `204 No Content`, `304 Not Modified`: no message body, no
  `Content-Length`/`Transfer-Encoding` body framing;
- `Content-Length` and `Transfer-Encoding: chunked` are mutually exclusive on a
  response (never both);
- unknown response length with keep-alive: use chunked, or fall back to
  connection-close framing (never an unframed body on a kept-alive connection);
- handler attempts to set hop-by-hop or framing-controlling headers
  (`Connection`, `Transfer-Encoding`, `Content-Length`, `Date`, `Server`) are
  overridden/rejected by jemmet, not trusted;
- invalid status/body combinations (e.g. body with 204) are rejected as handler
  errors (→ 500), never emitted.

## External Design
```lean
inductive ResponseBody | fixed (b : ByteArray) | chunked (stream : ChunkSource)
structure HttpResponse where
  status : Status ; headers : Headers ; body : ResponseBody ; keepAlive : Bool
def serializeHead : HttpResponse → Except SerializeError ByteArray
```
- Status line uses `HTTP/1.1`; reason phrase from `Status`.
- `Content-Length` set for `fixed`; `Transfer-Encoding: chunked` for `chunked`.
- `Date`/`Server` injected if absent.
- `Connection: keep-alive`/`close` per `keepAlive` and request policy.
- Header values validated: reject bare CR/LF and control chars so handler
  data cannot inject structure → `SerializeError` (handler bug) rather than a split
  response.

## Proof Obligations
`ResponseWf`: a serialized response is well-formed (exactly one status line; CRLF
line discipline; no header value contains CR/LF) **and body-framing-correct** (the
semantic rules above: HEAD/1xx/204/304 emit no body; CL xor chunked; no unframed
kept-alive body), for all valid `HttpResponse`; invalid status/body combinations and
header values are rejected, never emitted.

## Test Obligations
Serialization golden tests; CRLF-injection attempts in header values rejected;
keep-alive vs close framing; chunked response round-trips with RFC 004's decoder.

## Trust / Assumption Changes
None.

## Acceptance Criteria
Serializer implemented (HTTP/1.1 line); `ResponseWf` proven; injection rejected;
goldens pass.

## Alternatives Considered
- *Reuse iotakt `HttpResponse.toBytes`:* rejected — emits `HTTP/1.0`; jemmet owns
  responses (RFC 001).
- *Trust handlers to produce valid headers:* rejected — output validation is a
  security boundary.

## Open Questions
1. `ChunkSource` streaming interface for large/generated bodies (pull vs push).
2. Whether to expose a typed header API that makes injection unrepresentable.
