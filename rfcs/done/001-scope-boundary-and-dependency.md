# RFC 001: Scope, boundary, non-goals, and the iotakt-v1.0 dependency

## Status
Implemented (M0 — scope/boundary fixed; iotakt-v1.0 dependency decision recorded).
**Amended in v0.4.1** — the dependency-*consumption mechanism* changed from a vendored
tarball to a pinned Lake git dependency (see *Amendment (v0.4.1)* below). Scope, the
three-project boundary, byte-level iotakt consumption, and the non-goals are unchanged.

## Amendment (v0.4.1) — dependencies are pinned git deps, not vendored
The dependency-consumption *mechanism* recorded further down (vendored tarball; see
*Decision recorded (M2, RFC 008 vendoring)*) is **superseded**. Only *how* jemmet consumes
its siblings changed; the boundary, byte-level consumption rule, and non-goals stand.

**Policy.** iotakt, henret, and kroopt are independent projects. jemmet **depends on them
and does not contain them** — no copy of a sibling's source, tree or tarball, lives in this
repo. Each is consumed as a **pinned Lake git dependency**, declared in `lakefile.toml` as
`require … from git "<url>" @ "<rev>"`, fetched by Lake into the gitignored
`.lake/packages/`, and commit-locked by the committed `lake-manifest.json`. The lockfile is
the reproducibility guarantee: it records the resolved commit, so a clean build does not
rely on tag mutability.

**Current pins.** iotakt `v0.14.6` (the henret-free `Iotakt.Model` package); henret
`v0.34.4` = commit `ad0ceab4ebed2884c9165be44154dca2c1f4816f`. kroopt joins the same way at
M3 (`v0.124.0`, RFC 009). `docs/compatibility.md` records the peers' published release
provenance for the record; jemmet references those attestations, it does not re-host them.

**Why.** The vendored-tarball pin conflated "jemmet depends on iotakt" with "jemmet ships
iotakt." A dependency is a reference, not a copy. Lake's git-dependency + committed-manifest
model gives the same version pinning and reproducibility without embedding another project's
source in jemmet's tree, and mirrors how the peers pin each other (iotakt pins henret by git
commit, not by vendoring).

## Summary
Locks jemmet's identity as the verified HTTP/1.1 **edge** server of the
iotakt/kroopt/jemmet stack, fixes the three-project boundary, establishes that
jemmet consumes iotakt strictly at the **byte level** (reusing none of iotakt's
HTTP stand-in modules), and records the **iotakt-v1.0 dependency decision** plus
the dependency/compatibility policy (consumption mechanism amended in v0.4.1; see above).

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
4. Record the iotakt-v1.0 dependency decision and the dependency/compatibility
   policy. _(Consumption mechanism amended in v0.4.1: pinned git dep, not vendored.)_

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

Either way: jemmet maintains a **compatibility matrix** (jemmet vX ↔ iotakt vY ↔
kroopt vZ) in `docs/compatibility.md`, since the three release independently.

> _Note (v0.4.1): the original "vendored tarball releases, pinned by version" mechanism is
> superseded — siblings are now pinned Lake **git dependencies**. See *Amendment (v0.4.1)*
> at the top. The compatibility-matrix discipline is unchanged._

### Decision recorded (M2, RFC 008 vendoring) — _superseded in v0.4.1_
_Historical record of the v0.4.0 mechanism; the current policy is the git-dependency
Amendment (v0.4.1) above. Preserved because the decision and its rationale are part of the
project's history._

**Pin the candidate (the fallback).** iotakt v1.0 is the iotakt maintainer's release
to cut, not jemmet's, and it is not yet cut. jemmet therefore pins **iotakt 0.13.1** as
a vendored tarball and treats it as the frozen v1.0-equivalent, which the iotakt→jemmet
handoff explicitly sanctions: the consumer surface is "effectively frozen" and the
remaining iotakt work (kqueue, `recvInto`) is **additive-only and cannot break what
jemmet builds on** (HANDOFF §0, §6.2). The pin is vendored under
`vendor/iotakt-0.13.1`, built **Lean-only** (the pure `Iotakt.Model`; the native epoll
backend + henret bridge are seamed in at deployment per RFC 008). jemmet bumps to the
tagged iotakt v1.0 when it lands; because the surface is additive-only, that bump is a
re-pin, not a redesign.

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
