# RFC 012: CI, packaging, and release gates

## Status
Implemented (M2 scope — CI gate: build/proofs/conformance/fuzz; tarball + committed-manifest policy. Deferred: HTTPS E2E step → M3)

## Summary
How jemmet is built, verified, tested, packaged, and released — the CI gate, the
tarball layout, and the vendored-dependency / compatibility-matrix policy.

## Motivation
A release must be reproducible and honest. The CI gate is the integration
checkpoint; nothing ships unless it passes.

## Goals
1. A CI gate: build → proof build → unit suites → plaintext E2E (curl) → HTTPS E2E
   (gated, M3) → fuzzers → matrix-honesty guard.
2. Tarball releases: version in the archive name, files at the archive root (no
   intermediate parent dir), at logical breakpoints.
3. Pin iotakt/kroopt as vendored tarballs; maintain the compatibility matrix.

## Non-Goals
Multi-platform CI in v0.1 (Linux only, inherited from iotakt); package-registry
publishing.

## External Design
- CI steps (each must pass): `lake build`; build the proofs lib and assert 0
  `sorry`/`axiom`/`unsafe` + theorem-count match; `FakeConn` unit suites (parser,
  framing, router, response, serve loop, keep-alive); plaintext E2E via curl;
  HTTPS E2E via curl/openssl (M3, gated); fuzz smoke; doc build (mdbook).
- Release: `jemmet-vX.Y.Z[-dev].tar.gz`, files at root; CHANGELOG/ROADMAP updated;
  RFCs moved `proposed→done` as they land.
- Dependencies: vendored `iotakt-vY` and `kroopt-vZ` tarballs; `docs/compatibility.md`
  records the validated triple.
- CI builds against the committed `lake-manifest.json` (relative `./vendor/...` path deps) and must **not** run `lake update`, so the build is reproducible and portable across checkout locations.

## Proof / Test Obligations
The gate runs the proof build and all test suites; the matrix-honesty guard is a
required step.

## Trust / Assumption Changes
None.

## Acceptance Criteria
CI gate green end-to-end (HTTPS E2E gated to M3); a v0.1 tarball builds at the
correct layout; compatibility matrix recorded.

## Alternatives Considered
- *Multi-platform CI now:* deferred — Linux-only matches iotakt's native backend.

## Open Questions
1. Whether HTTPS E2E runs in CI from M3 or as a separate gated job until kroopt is
   vendored.
