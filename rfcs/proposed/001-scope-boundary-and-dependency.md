# RFC 001: Scope, boundary, non-goals, and the iotakt-v1.0 dependency

## Status
Proposed

## Summary
Locks jemmet's identity as the verified HTTP/1.1 **edge** server of the
iotakt/kroopt/jemmet stack, fixes the three-project boundary, establishes that
jemmet consumes iotakt strictly at the **byte level** (reusing none of iotakt's
HTTP stand-in modules), and records the **iotakt-v1.0 dependency decision** plus
the vendoring/compatibility policy.

## Motivation
jemmet's value is that the internet-facing process is the verified one. That only
holds if (a) nothing unverified sits in front of it (so jemmet terminates its own
connections), and (b) jemmet does not absorb responsibilities that belong to its
siblings (I/O → iotakt, crypto → kroopt). Without a written boundary, jemmet would
drift into reimplementing I/O or TLS, or into depending on iotakt's HTTP stand-ins
and thereby owning two parsers.

## Goals
1. State jemmet = HTTP/1.1 edge server; the egress-facing process.
2. Fix the boundary: iotakt moves bytes; kroopt secures bytes; jemmet interprets
   bytes.
3. Establish byte-level consumption of iotakt (the confirmed consumer binding
   spec) and **no reuse** of `Iotakt.Http`/`RequestBody`/`Router`.
4. Record the iotakt-v1.0 dependency decision and the vendoring/compatibility
   policy.

## Non-Goals
I/O / fd lifecycle (iotakt); TLS/crypto (kroopt); reverse-proxy or
behind-a-proxy deployment for TLS; HTTP/2/3, WebSocket (forward); application
framework, authn/authz, compression (v0.1). (Full list: Requirements §2.4.)

## External Design
The stack and responsibilities are as in Requirements §1 and External Design §4.1.
The operative rule: **if jemmet needs anything from iotakt or kroopt beyond their
published consumer surfaces, that is a boundary violation to redesign around, not
a request for an upstream change.** jemmet uses iotakt via
`recvAck`/`sendAck`/`enableWrite`/`disableWrite`/`closeConnection`/`runStepAuto`/
`FdKey` only; iotakt's `Http`/`RequestBody`/`Router` are stand-ins jemmet
supersedes.

### The iotakt-v1.0 dependency decision
jemmet should build on a **frozen** iotakt. iotakt is at v0.13.1-dev — a declared
v1.0 *candidate* whose remaining work (kqueue, `recvInto`) is additive-only.
Decision options:
- **(Recommended) Cut iotakt v1.0** before jemmet M2 binds to it. jemmet binding
  is the natural trigger for that sign-off; it removes a moving dependency from
  under a months-long project.
- **(Fallback) Pin the `-dev` candidate** as a vendored tarball, accepting that it
  is additive-only and recording the pin here.

Either way: iotakt and kroopt are consumed as **vendored tarball releases**, pinned
by version; jemmet maintains a **compatibility matrix** (jemmet vX ↔ iotakt vY ↔
kroopt vZ) in `docs/compatibility.md`, since the three release independently.

## Proof Obligations
None (scope document).

## Test Obligations
None directly; the boundary is enforced by RFC 008/009 calling only the published
surfaces.

## Trust / Assumption Changes
Establishes iotakt and kroopt as ASSUMED dependencies (each proven+tested in its
own matrix).

## Acceptance Criteria
Boundary, byte-level-consumption rule, non-goals, and the iotakt-v1.0 decision are
accepted and recorded; the compatibility policy is stated.

## Alternatives Considered
- *jemmet behind nginx/Caddy for TLS:* rejected — moves the attack surface to an
  unverified component, defeating jemmet's purpose.
- *Reusing iotakt's HTTP modules:* rejected — leads to two parsers and couples
  jemmet to an I/O library's stand-in; the clean boundary is byte-level.
- *TLS inside jemmet:* rejected — that is kroopt's responsibility; jemmet stays
  small.

## Open Questions
1. Cut iotakt v1.0 now, or pin the candidate? (Recommend cut; owner decision.)
2. Initial compatibility-matrix entries (depends on the iotakt/kroopt versions
   chosen at M2/M3).
