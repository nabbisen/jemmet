# RFC 006: Routing

## Status
Proposed

## Summary
jemmet's own router: method + path dispatch with `:param` capture, a typed
`Handler`, and total, deterministic resolution to a handler, 404, or 405.

## Motivation
jemmet owns routing (iotakt's optional `Router` is a stand-in, RFC 001). For a
verified server, dispatch should be total and deterministic — every request maps
to exactly one outcome — and bounded against adversarial keys (Requirements
§3.2.6).

## Goals
1. Method + path matching with static segments and `:param` capture.
2. A typed `Handler := RequestCtx → IO HttpResponse` and request context.
3. Total, deterministic dispatch: found-with-params | 404 | 405.
4. Bounded behavior for adversarial paths/keys.

## Non-Goals
Middleware framework, content negotiation, regex routing (v0.1); the handler's own
logic.

## External Design
```lean
abbrev Handler := RequestCtx → IO HttpResponse
structure Route where method : Method ; pattern : PathPattern ; handler : Handler
structure Router where routes : List Route
inductive Dispatch | found (h : Handler) (params : Params) | notFound | methodNotAllowed
def Router.dispatch : Router → HttpRequest → Dispatch
```
- `PathPattern` = list of `static s | param name` segments.
- Matching is left-to-right, first-match; method mismatch on an otherwise-matching
  path → 405 (with `Allow`); no path match → 404.

## Proof Obligations
`RouterTotal`: `dispatch` is total and deterministic (every `(method, path)` yields
exactly one `Dispatch`); first-match order makes resolution unique given a route
list.

## Test Obligations
Route-table cases (static, param, overlap, method mismatch); adversarial-path
complexity stays within the bound.

## Trust / Assumption Changes
None.

## Acceptance Criteria
Router + matcher implemented; `RouterTotal` proven; 404/405 correct (405 sets
`Allow`); complexity bound documented and tested.

## Alternatives Considered
- *Reuse iotakt `Router`:* rejected (RFC 001).
- *Regex/trie router in v0.1:* deferred — list-of-patterns is provably total and
  sufficient for v0.1.

## Open Questions
1. Trie vs list once route counts grow (keep list for v0.1 provability).
2. Query-string handling location (parser vs router vs handler context).
