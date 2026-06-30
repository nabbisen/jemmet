# jemmet Requirements Specification v1

**Project:** jemmet
**Document type:** Requirements specification (covers executive summary, library
requirements, and threat model / security requirements)
**Status:** Draft v2 (revised per senior review), RFC-ready
**Language ecosystem:** Lean 4
**Consumes:** iotakt (non-blocking I/O boundary) and kroopt (TLS secure channel)
**Position:** the internet-facing HTTP/1.1 edge server of the iotakt/kroopt/jemmet stack
**Primary design principle:** A small, auditable, formally-disciplined HTTP edge
server that terminates its own connections (plaintext and, via kroopt, TLS),
parses HTTP itself, and proves the framing-soundness properties that make a
verified edge worth more than an unverified one.

---

## 0. Revision note — what changed from v1 (senior review response)

v1's boundary discipline and pure HTTP core were endorsed. v2 hardens the
**effectful driver/actor/socket boundary**, which the review identified as the
highest-risk component (M2/M3 danger zone), turning prose expectations into
enforceable contracts:

1. **Driver/event semantics as a contract** (new RFC 014): event-batch ordering,
   stale-`FdKey` handling, tick-vs-I/O ordering, bounded per-batch steps + fairness,
   the close/cancel/timeout/pending-output interaction, and **no nested
   `runStepAuto`**. Backed by a deterministic fake event-trace runner.
2. **Handler execution policy** (new RFC 015): henret task-handoff so a slow/blocking
   handler cannot stall the loop; phase-indexed `ConnState` with `WaitingForHandler`
   (deadline, cancellation).
3. **`Conn` exposes `ConnProgress`** (RFC 002): `needsRead`/`needsWrite`/owned-byte
   counts/`closeState`, so the driver arms interests and bounds memory rather than
   guessing; instances may not nest the driver.
4. **Raw-stream no-smuggling theorem** (RFC 003): proven over the full
   bytes→normalization→boundary pipeline, not only normalized `Headers`.
5. **Mandatory egress boundedness** (RFC 010, now PROVEN/model-checked): a
   three-tier user-space accounting bound (jemmet-queued + Conn-owned plaintext +
   kroopt-owned ciphertext).
6. **Phase-indexed total error policy** and a keep-alive proof covering malformed/
   partial states (RFC 007/010).
7. **TLS progress matrix** as the M3 gate, not happy-path HTTPS (RFC 009).
8. **M1.5 driver-model checkpoint** before `PlainIotaktConn` is stable; RFC
   010/014/015 accepted there.
9. **Production lifecycle gates** (new RFC 016): graceful shutdown, leak detection,
   redacted observability, failure-mode docs.
10. **Response HTTP semantics** (RFC 005): HEAD/1xx/204/304 body rules, CL-xor-chunked,
    hop-by-hop override.

Two adopted recommendations create cross-project coordination, named honestly: the
handler task-handoff needs the henret task API reachable through iotakt to support
spawn/observe/cancel without an iotakt change (RFC 015 — else v0.1 uses strict-inline
handlers with loop-enforced deadlines); and the TLS egress tier needs kroopt to
expose owned-ciphertext accounting (RFC 009 — a small additive consumer need on
kroopt).

---

## 1. Executive Summary

`jemmet` is a Lean 4 **HTTP/1.1 server** intended to be the **front, egress-facing
edge** of a formally-disciplined Lean systems stack — not an application server
hidden behind an unverified proxy. Its value proposition is that the process
actually exposed to the internet is the verified one: the request parser, the
HTTP framing engine, the routing, and the connection lifecycle are all auditable
Lean, with the most safety-critical property — **no HTTP request smuggling /
desync** — machine-checked rather than hoped for.

jemmet does not move bytes and does not encrypt them. It sits at the top of a
three-project stack, each with one responsibility:

```
jemmet (HTTP)  ── consumes ──▶  kroopt (TLS)  ── consumes ──▶  iotakt (non-blocking I/O)
   │                                                              │
   └────────────── consumes iotakt directly for plaintext ───────┘
```

- **iotakt** owns *how bytes move* (fd lifecycle, readiness, non-blocking
  recv/send).
- **kroopt** owns *the bytes are encrypted and authenticated* (TLS 1.3).
- **jemmet** owns *what the bytes mean* (HTTP semantics, routing, responses,
  keep-alive policy).

The architectural keystone is a single **connection abstraction** — a `Conn`
interface with `recv`/`send`/`flush`/`close`/`metadata` — implemented by both a
plaintext connection (`PlainIotaktConn`, over iotakt) and a TLS connection
(`TlsConn`, over kroopt). Because both deliver the same thing — a stream of
**plaintext bytes** — jemmet runs exactly one HTTP code path; whether a
connection is encrypted is a wiring choice at accept time, not a branch in the
handlers. This is the same discipline kroopt uses for its `Transport` typeclass
and iotakt uses for its fake poller: one interface, multiple instances, including
a deterministic `FakeConn` for testing without sockets or TLS.

jemmet consumes iotakt strictly at the **byte level** (the iotakt consumer
binding spec: `recvAck`/`sendAck`/`enableWrite`/`disableWrite`/`closeConnection`/
`runStepAuto`/`FdKey`). It does **not** reuse iotakt's `Http`/`RequestBody`/
`Router` modules — those are stand-ins that jemmet supersedes with its own parser
and router. iotakt moves bytes; jemmet interprets them.

The first release prioritizes correctness, framing soundness, and auditability
over throughput and feature breadth. It ships a working **plaintext** HTTP/1.1
edge server first (it depends only on iotakt, whose consumer contract is
confirmed), then layers **HTTPS** by wiring in kroopt's `TlsConn` once kroopt's
real-iotakt binding is validated. HTTP/2 is explicitly future work, but the
connection and serve-loop design is kept from precluding it.

### 1.1 Why jemmet exists

A formally-verified edge is pointless if an unverified TLS terminator (nginx,
Caddy) sits in front of it: the real attack surface would then be the unverified
component. So jemmet terminates its own connections. But an HTTP server should
not own socket polling (iotakt's job) or cryptography (kroopt's/HACL\*'s job).
jemmet is the narrow top layer that turns an authenticated plaintext byte stream
into HTTP semantics, and nothing more.

### 1.2 What jemmet is not

Not an I/O library (iotakt), not a TLS stack (kroopt), not an application
framework, not a reverse proxy / load balancer, not a static-file server beyond a
minimal handler, not an async runtime. (Full non-goals: §2.4.)

---

## 2. Library Requirements

### 2.1 Architectural Goals

jemmet MUST:

1. Be a Lean 4 HTTP/1.1 server usable as the internet-facing edge of the
   iotakt/kroopt stack.
2. Consume iotakt strictly at the byte level, via the confirmed consumer binding
   spec; reuse none of iotakt's HTTP/routing stand-in modules.
3. Treat plaintext and TLS connections uniformly through a single `Conn`
   abstraction, so the HTTP code path is identical for both.
4. Own its entire HTTP layer: request parsing, framing, response building,
   routing, keep-alive policy.
5. Keep the connection/serve-loop design from precluding HTTP/2 (multiplexed
   streams over one connection) even though h2 is deferred.
6. Maintain a proof/trust/test matrix from the first release, honest about what
   is proven (framing soundness, parser bounds-safety, routing totality) vs.
   tested (HTTP conformance via interop) vs. assumed (iotakt, kroopt).
7. Require **no change** to iotakt or kroopt; if jemmet needs something from
   either beyond their published consumer surfaces, that is a boundary violation
   to redesign around.

### 2.2 The Connection Abstraction (keystone requirement)

jemmet MUST define one connection interface that all transports implement:

```
Conn:
  recv     : Conn → Nat            → IO (RecvOutcome × Conn)   -- up to N plaintext bytes
  send     : Conn → ByteArray      → IO (SendOutcome × Conn)   -- returns plaintext bytes consumed
  flush    : Conn                  → IO (FlushOutcome × Conn)  -- drive pending output toward peer
  close    : Conn → CloseMode      → IO Conn                   -- graceful or abortive
  metadata : Conn                  → ConnMetadata              -- ALPN, peer addr, secure?, fd identity
```

Requirements on this interface:

1. **Byte-level.** `recv` yields raw plaintext bytes; jemmet's parser sits above.
   Both `PlainIotaktConn` and `TlsConn` deliver bytes identically.
2. **Plaintext-consumption send semantics.** `send` returns the count of
   **plaintext bytes accepted/owned by the connection**, not bytes written to the
   socket. `wouldBlock` means zero consumed. Pending (possibly encrypted) output
   is owned by the connection until flushed. This mirrors kroopt's `TlsConn`
   contract exactly, so `PlainIotaktConn` implements the same semantics trivially.
3. **Shaped for the heavy instance.** `recv` on a `TlsConn` may drive kroopt's
   state machine, which itself performs iotakt I/O and crypto, before yielding
   plaintext or `wouldBlock`. The interface MUST be effectful (`IO`) and built for
   that; `PlainIotaktConn.recv` is then a thin `recvAck`.
4. **Unified error/close model.** iotakt `IoErrno`, kroopt `TransportError`/TLS
   alerts, and peer-EOF MUST collapse into one jemmet-facing `ConnError`/close
   view, so jemmet handles "the connection died" identically regardless of layer.
5. **Three instances required:** `PlainIotaktConn` (over iotakt), `TlsConn` (over
   kroopt), and `FakeConn` (deterministic, in-model, no IO) for tests and proofs.
6. **Every operation returns a `ConnProgress`** (`progressMade`/`needsRead`/
   `needsWrite`/`ownedInBytes`/`ownedOutBytes`/`closeState`), so the driver arms
   iotakt interests and bounds owned memory from fact, not inference. (RFC 002.)
7. **Instances MUST NOT nest the driver loop** (`runStepAuto`); the driver is the
   sole owner of global polling. (RFC 002/014.)

### 2.3 HTTP/1.1 Goals

jemmet MUST provide:

1. An HTTP/1.1 request parser: request line, headers, and a **framing engine**
   that resolves Content-Length, Transfer-Encoding (chunked), and Connection in
   exactly one sound way (§3).
2. A response builder emitting correct **HTTP/1.1** status lines (not the
   `HTTP/1.0` stand-in iotakt shipped), with Content-Length or chunked bodies,
   `Date`/`Server`, and keep-alive `Connection` handling.
3. Routing: method + path dispatch with path-parameter capture, 404/405, and a
   typed handler interface.
4. Keep-alive (persistent connections) with correct request boundaries on a reused
   connection (pipelining-correct read framing).
5. Chunked transfer-encoding on both directions (decode requests, stream
   responses).
6. Request-size and connection limits with safe defaults and the matching status
   responses (413, 431).

### 2.4 Non-Goals

jemmet MUST NOT:

1. perform syscalls or own fd lifecycle (iotakt);
2. implement TLS or any cryptography (kroopt / HACL\*);
3. reuse iotakt's `Http`/`RequestBody`/`Router` parsing/dispatch (it supersedes
   them; it consumes iotakt only at the byte level);
4. act as a reverse proxy, load balancer, or sit *behind* one for TLS (it is the
   edge);
5. implement HTTP/2, HTTP/3/QUIC, or WebSocket in v0.1 (h2 is forward work;
   the design must not preclude it);
6. provide an application framework, ORM, template engine, or session store
   (handler/application concerns above jemmet);
7. implement DNS, an async runtime, or multi-threaded request handling in v0.1;
8. implement content compression in v0.1 (deferred; see §3 decompression-bomb
   note);
9. provide authentication or authorization (handler/application concern).

### 2.5 Proof / Trust / Test Posture

jemmet is **mostly TESTED** (HTTP conformance is established by interop with real
clients), with a **PROVEN core** where verification is cheap and high-value, and
an explicit **ASSUMED** dependency on its two siblings:

- **PROVEN:** request-framing soundness / no-smuggling (§3.2.1), parser bounds
  safety, router totality and determinism, response well-formedness, keep-alive
  request-boundary correctness.
- **TESTED:** end-to-end HTTP/1.1 conformance via curl, browsers, and
  conformance suites; keep-alive and pipelining; chunked round-trips; limit
  enforcement; HTTPS E2E (through kroopt).
- **ASSUMED:** iotakt's I/O correctness and kroopt's TLS correctness (each
  proven+tested in its own matrix); the Lean runtime and toolchain.
- **OUTSCOPE:** cryptographic security (kroopt/HACL\*), kernel/TCP behavior,
  volumetric network DoS, application-level authn/authz.

The "no project-local `sorry`/`axiom`/`unsafe` in the proven core except
whitelisted, documented assumptions" rule (adopted from kroopt) applies.

### 2.5a Driver, Handler, and Egress Contracts (added per review)

The effectful boundary is the highest-risk component, so it carries enforceable
requirements, not prose:

1. **Driver event semantics (RFC 014)** are a model-level contract: batch ordering
   (newConnection → I/O → tick), stale-`FdKey` drop at the jemmet edge, one bounded
   progress step per connection per batch with fairness, a total
   close/cancel/timeout/pending-output interaction, and no nested `runStepAuto`. A
   deterministic fake event-trace runner replays adversarial sequences (M1.5).
2. **Handler execution (RFC 015)** MUST NOT block the loop: the default is henret
   task-handoff with a phase-indexed `WaitingForHandler` (deadline + cancellation)
   and a bounded in-flight cap; a declared fast path may run inline.
3. **Egress boundedness (RFC 010)** is a **mandatory** v0.1 safety property:
   `jemmetQueuedPlaintext + connOwnedPlaintext + tlsOwnedCiphertext ≤
   maxUserSpacePendingOut` for every live connection, proven or model-checked;
   large responses stream rather than fully serialize before backpressure applies.

## 2.6 Dependency and Compatibility Policy

1. jemmet depends on iotakt, henret, and kroopt as **pinned Lake git dependencies**
   (the henret→iotakt pattern — `require … from git "<url>" @ "<rev>"`): independent
   projects referenced by revision and commit-locked by `lake-manifest.json`, never
   vendored (no sibling source in this repo) and never on unpinned trees.
2. jemmet maintains a **compatibility matrix**: jemmet vX is validated against
   iotakt vY and kroopt vZ. Because the three projects release independently, this
   coupling MUST be explicit in `docs/compatibility.md` and the CHANGELOG.
3. **iotakt v1.0 gate.** jemmet should build on a *frozen* iotakt, not a moving
   `-dev` candidate. The recommended action is to cut iotakt v1.0 before jemmet
   M2 binds to it; if jemmet instead pins a `-dev` candidate, RFC 001 records that
   as a conscious decision with the understanding that remaining iotakt work is
   additive-only. (RFC 001.)

### 2.7 Conventions

English throughout; Apache-2.0, author nabbisen; `LICENSE`+`NOTICE`; concise
`README.md` with full docs under `docs/src` (mdbook); `rfcs/` adopting iotakt RFC
000 verbatim; `CHANGELOG.md` + `ROADMAP.md`; module files split by logical
boundary (~300 ELOC soft / ~500 ELOC hard split guidance); releases as tarballs
at logical breakpoints with the version in the archive name and files at the
archive root.

---

## 3. Threat Model / Security Requirements

jemmet is the process exposed to the open internet. Its **entire input surface is
attacker-controlled bytes**. This section is therefore first-class, not an
appendix: the security posture is much of jemmet's reason to exist.

### 3.1 Assets, Adversary, Trust Boundaries

**Assets to protect:** the integrity of request/response framing (so requests
cannot be smuggled or desynced); the availability of the server (so a single
peer cannot exhaust it); the plaintext behind TLS (kroopt's responsibility, which
jemmet relies on); and the correctness of what reaches the application handlers.

**Adversary:** any party that can open a connection to a jemmet listener and send
arbitrary, malformed, hostile, or adversarially-timed bytes — including a
malicious client, a malicious upstream, and a man-on-the-path before TLS is
established.

**Trust boundaries jemmet relies on (ASSUMED, not jemmet's to prove):**

1. kroopt delivers only **authenticated, post-handshake plaintext**; no
   pre-handshake or unauthenticated bytes ever reach jemmet (kroopt's
   "no early/unauthenticated plaintext" proofs). jemmet does not re-validate TLS.
2. iotakt delivers bytes for the **correct, current** connection only
   (`FdKey` generation filtering); jemmet does not re-validate fd identity.
3. The boundary jemmet **must not** weaken: jemmet must not assume a connection is
   TLS when it is plaintext. v0.1 keeps plaintext and TLS on **separate
   listeners/ports** (no same-port sniffing) so the security context of a
   connection is unambiguous from how it was accepted.

### 3.2 Threats and Required Mitigations

#### 3.2.1 Request smuggling / desync (the headline threat)
Conflicting or ambiguous framing — Content-Length vs Transfer-Encoding, duplicate
or conflicting `Content-Length`, malformed chunked encoding, header obfuscation —
is the classic way to make two parties disagree about request boundaries.
**Requirement:** jemmet's framing engine resolves framing in exactly one sound
way, and that **soundness is a PROVEN property** (jemmet's analog of kroopt's
no-early-plaintext): for any byte stream, the parser yields a unique, unambiguous
sequence of request boundaries or a hard rejection — never an interpretation that
a different parser could disagree with. Specifically: reject messages bearing both
`Content-Length` and `Transfer-Encoding`; reject multiple/conflicting
`Content-Length`; accept only well-formed chunked; never "guess." (RFC 003.)

#### 3.2.2 Header injection / response splitting
CR/LF (or bare CR/LF) injected via header values or routed data could split or
forge responses. **Requirement:** header *names* and *values* are validated on
input (reject control characters / embedded CRLF), and response serialization
encodes/validates all emitted header values so no handler-supplied data can inject
header or status structure. Output well-formedness is a PROVEN property where
feasible.

#### 3.2.3 Slowloris — slow ingress and slow egress
A peer that sends headers/body one byte at a time, or refuses to drain a response,
ties up a connection indefinitely. **Requirement:** bounded **timeouts** on
header read, body read, and idle keep-alive; bounded **write backpressure** on
egress (a slow reader cannot force unbounded buffering, and a stalled write is
timed out). Write-side backpressure and slow-client timeouts are first-class, not
an afterthought. (RFC 010.)

#### 3.2.4 Resource exhaustion
Oversized request lines, oversized or innumerable headers, oversized bodies, huge
chunked streams, or too many connections. **Requirements (safe defaults, all
configurable):** max request-line length; max header count and max total header
bytes (→ `431 Request Header Fields Too Large`); max body size (→ `413 Payload Too
Large`, using iotakt's `tooLarge` signal); max concurrent connections (load-shed
via iotakt's connection cap); max chunk/extension sizes; bounded pending output.
None of these may be unbounded by default.

#### 3.2.5 Parser memory safety
Out-of-bounds reads on any length-prefixed or delimiter-scanned input.
**Requirement:** the parser is **bounds-safe by construction** and this is a
PROVEN property; combined with Lean's memory safety, there is no OOB/`unsafe` in
the parser. Fuzz harnesses target the request-line parser, the header parser, and
the chunked decoder.

#### 3.2.6 Algorithmic-complexity / hash-flooding
Adversarial header names or route keys driving worst-case behavior in maps.
**Requirement:** header and routing lookups use structures whose worst case is
bounded for adversarial input (or are sized so adversarial collisions cannot
degrade them); no unbounded per-request allocation driven by header count beyond
the header-count limit.

#### 3.2.7 Keep-alive state confusion
On a reused connection, mis-identifying where one request ends and the next begins
is itself a smuggling vector. **Requirement:** the keep-alive request-boundary
state machine is PROVEN to consume exactly one well-framed request before
considering the next, carrying any pipelined remainder correctly.

#### 3.2.8 Decompression bombs (forward)
Content compression is out of scope for v0.1 specifically because decompression
amplification is a DoS vector; when added, it MUST carry output-size limits. Noted
here so it is not added casually.

### 3.3 Security Non-Goals (explicitly out of scope)

1. Cryptographic security, TLS correctness, certificate handling — kroopt/HACL\*.
2. Kernel/TCP correctness, fd lifecycle — iotakt/OS.
3. Volumetric / network-layer DoS (SYN floods, amplification) — a deployment /
   network concern, not jemmet's.
4. Authentication, authorization, session security — application/handler concern.
5. Application-logic vulnerabilities in handlers — jemmet provides safe framing
   and validated input, not handler correctness.

### 3.4 Security Requirements Summary

jemmet MUST: resolve framing soundly and provably (no smuggling); validate header
names/values and encode output (no splitting); enforce timeouts on read and write
and bound egress buffering (slowloris, both directions); enforce request-line,
header, body, connection, and chunk limits with safe defaults and correct status
codes; keep the parser bounds-safe by construction (proven) and fuzzed; bound
adversarial map behavior; prove the keep-alive boundary state machine; keep
plaintext and TLS on separate listeners in v0.1; redact secrets and avoid logging
full attacker-controlled blobs; and map every malformed input to a deterministic
HTTP error rather than undefined behavior.

---

## 4. Acceptance Criteria for Requirements Completion

The requirements phase is complete when: the iotakt/kroopt/jemmet boundaries are
fixed and agreed; the byte-level iotakt consumption (no reuse of iotakt's HTTP
modules) is accepted; the `Conn` abstraction (with plaintext-consumption send
semantics, the heavy-instance effect model, and the unified error model) is
accepted as the keystone; framing soundness is accepted as the headline PROVEN
property and primary security requirement; the milestone split (plaintext edge
before TLS, TLS gated on kroopt's real-iotakt validation) is accepted; the
iotakt-v1.0 dependency decision is made (RFC 001); and the RFC breakdown is
accepted. The companion documents are `jemmet_external_design_v2.md` (§4 of the
deliverable) and `jemmet_rfc_roadmap_v2.md` (road map + RFC milestones).
