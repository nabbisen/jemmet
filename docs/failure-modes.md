# jemmet — Failure modes (RFC 016)

jemmet's entire input surface is attacker-controlled, so every failure must be a *defined*
outcome — a status code, a bounded close, or a refusal — never undefined behaviour. This
document is the operator-facing catalog: for each failure class, what jemmet does, where it
is enforced, and how it is verified. It complements the threat model (Requirements §3) and
the proof/trust/test matrix.

The governing rule: **every malformed input maps to a deterministic HTTP error or a clean
close, and a desync risk closes the connection rather than guessing.**

## Request-level failures (parsing / framing)

| Failure | jemmet's response | Enforced in | Verified by |
|---|---|---|---|
| Malformed request line | `400`, close | `Http/Request.parseRequestLine` | `LimitConformance`, interop corpus |
| Request line over limit | `414`, close | parser + `Limits.maxRequestLineBytes` | `LimitConformance` |
| Unsupported version (0.9, 2.0, 1.2) | `505`, close | `parseRequestLine` | interop corpus (method/version) |
| Missing / duplicate Host (HTTP/1.1) | `400`, close | `parseRequest` (RFC 9112 §3.2) | interop corpus (Host) |
| Header name/value with CR/LF/CTL | `400`, close | `Http/Request.parseHeaderLine` | interop corpus (injection) |
| Whitespace before colon / obs-fold | `400`, close | `parseHeaderLine` | interop corpus (injection) |
| Header count / total bytes over limit | `431`, close | parser + `Limits` | `LimitConformance` |
| Body over limit | `413`, close | `parseRequest` + `Limits.maxBodyBytes` | `LimitConformance` |
| CL+TE together, or duplicate/list CL | `400`, close (no guessing) | `Http/Framing.decideFraming` (proven) | `FramingSound*`, interop smuggling |
| Non-chunked / compound Transfer-Encoding | `400`, close | `decideFraming` | interop smuggling |
| Malformed chunk size / framing | `400`, close | `Http/Chunked` | `HttpConformance`, fuzz |

Each error's status is the proven `ParseError.statusCode` (`Proofs/LimitStatus`); the serve
loop emits the matching `errorResponse` and closes (`Serve/Loop.serveBuffer`) — a malformed
request is a desync risk, so there is no resync (RFC 003). The status-to-response agreement is
checked exhaustively (`IntegrationConformance`).

## Connection-level failures (slowloris / resources / transport)

| Failure | jemmet's response | Enforced in | Verified by |
|---|---|---|---|
| Slow header/body trickle (ingress slowloris) | read timeout → close | `ServeDriver.connTimedOut` (read timeout) | `IotaktConformance` |
| Idle keep-alive connection | idle timeout → close | `ServeDriver.connTimedOut` (idle timeout) | `IotaktConformance` |
| Peer refuses to drain a response (egress slowloris) | bounded owned output; stalled write → close | `Serve/Egress`, `ServeDriver.stepReadable` backpressure | `EgressBound` (proven), `IotaktConformance` |
| Too many headers / oversized streams | bounded by `Limits`, then `431`/`413` | parser + `Limits` | `LimitConformance` |
| Adversarial header/route keys | bounded lookups (assoc list, count-capped) | `Http/Header`, `Route` | `RouterTotal`, interop |
| Peer EOF mid-request | `truncated` → close | `Conn` error model, `stepReadable` | `Conformance`, `IotaktConformance` |
| Transport reset / errno | `ConnError` → close (uniform) | `Conn.recv/send` mapping | `Conformance`, `IotaktConformance` |
| Stale event for a torn-down fd | dropped (generation-filtered), counted | `ServeDriver.stepIo` | `EventSemantics` (proven) |

## Handler-level failures

| Failure | jemmet's response | Enforced in | Verified by |
|---|---|---|---|
| Handler throws / errors | `500`, close | `Serve/HandlerPolicy.failResponse` | `HandlerConformance`, `HenretConformance` |
| Handler exceeds its deadline | `503`, cancel + close | `HandlerPhase.response` (timedOut → 503) | `HandlerConformance` (deadline→503) |
| Handler completes after the connection closed | response dropped (no late write) | terminal phases absorb events | `HandlerPolicy.no_late_response` (proven) |
| In-flight tasks exceed the cap | new work bounded | `HandlerPool` cap | `HandlerConformance` |
| Slow handler on one connection | does not stall the loop (task hand-off / inline + loop deadline) | `Serve/HandlerPolicy`, driver | `HandlerPolicy` (proven), `HenretConformance` |

## Server lifecycle (RFC 016 graceful shutdown)

| Event | jemmet's behaviour | Enforced in | Verified by |
|---|---|---|---|
| Shutdown requested | stop accepting new connections | `ServeDriver.requestShutdown`; `phase.acceptsNew` gate | `LifecycleConformance`, `Proofs/Lifecycle` |
| In-flight connections during drain | finish current request, then close (no new keep-alive request) | `phase.admitsKeepAlive` gate in `stepReadable` | `LifecycleConformance` |
| Drain exceeds its deadline | force-close the remainder, reach `stopped` | `ServeDriver.sweepTimeouts` (mirrors proven model) | `Proofs/Lifecycle.drain_deadline_forces_stop`, `no_leak_after_forced_stop` |
| Drain completes early | stop cleanly once no connections remain | `sweepTimeouts` | `Proofs/Lifecycle.drain_empty_stops` |
| Repeated shutdown signal | idempotent | `requestShutdown`, `stepLifecycle` | `Proofs/Lifecycle.shutdown_idempotent` |

The drain is **bounded**: past the deadline the live set is cleared and the server reaches
`stopped` with zero live connections — proven, so shutdown cannot hang or leak connections.

## Resource-leak detection

The lifecycle model carries a `LeakReport` (live connections, owned output bytes, in-flight
tasks). `ServerState.audit` reports them and `LeakReport.clean` asserts all are zero; a forced
stop is proven to leave zero live connections (`Proofs/Lifecycle.no_leak_after_forced_stop`),
and the driver's `removeConn` is proven to drop a closed key from the table
(`Proofs/EventSemantics.removeConn_find_none`) — so a closed connection is never left dangling.

## Explicitly out of scope (deployment / sibling concern)

Cryptographic and TLS failures (kroopt/HACL\*), kernel/TCP and fd-lifecycle failures
(iotakt/OS), volumetric network DoS, and application-logic faults inside handlers are not
jemmet's to handle (Requirements §3.3). jemmet provides safe framing, validated input, and a
bounded, observable lifecycle around them.
