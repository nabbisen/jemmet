/-
  Jemmet.Observe — redacted structured access logging (RFC 016 / §3.4).

  The access log is a security surface: its entire input is attacker-controlled, so it must
  (a) never emit header values or body bytes (avoid logging secrets / blobs), and (b) never
  let attacker data inject log structure (a CR/LF in a path could forge a second log line).

  This module enforces both:
  - `AccessRecord` carries **only** safe fields (connection id, secure flag, a fixed method
    token, the request path, status, byte counts, timing). It has no field for header values
    or body bytes, and `ofExchange` reads only `req.method` and `req.target.path` — never
    `req.headers` or `req.body`. The no-leak guarantee is by construction.
  - `render` sanitizes the assembled line as a final pass: every control character (CR, LF,
    and all other C0/DEL) is replaced, so a rendered line can never contain an embedded
    newline. The log-injection defense is proven in `Jemmet.Proofs.ObserveSafe`.

  Query strings are deliberately not logged (secrets frequently ride in query params), and
  unknown methods collapse to `OTHER` rather than echoing an arbitrary token.
-/
import Jemmet.Http.Request

namespace Jemmet

/-- A control character: C0 (`< 0x20`) or DEL (`0x7f`). CR and LF are both C0. -/
def isCtl (c : Char) : Bool := c.toNat < 0x20 || c.toNat == 0x7f

/-- Replace a control character with `?`; pass everything else through. -/
def sanitizeChar (c : Char) : Char := if isCtl c then '?' else c

/-- Strip every control character from a string (the log-injection scrubber). -/
def sanitize (s : String) : String := ⟨s.data.map sanitizeChar⟩

/-- A fixed, safe token for each method — unknown methods collapse to `OTHER` so an
    attacker-chosen method token is never echoed into the log. -/
def logMethodToken : Method → String
  | .get => "GET" | .head => "HEAD" | .post => "POST" | .put => "PUT"
  | .delete => "DELETE" | .patch => "PATCH" | .options => "OPTIONS"
  | .connect => "CONNECT" | .trace => "TRACE" | .other _ => "OTHER"

/-- A structured access-log record with **only** safe fields — no header values, no body. -/
structure AccessRecord where
  connId     : Nat        -- server-assigned (FdKey.raw)
  secure     : Bool
  method     : String     -- a fixed token (see `methodToken`)
  path       : String     -- attacker-controlled → sanitized on render
  status     : Nat
  reqBytes   : Nat
  respBytes  : Nat
  durationMs : Nat

/-- Build a record from an exchange, reading only the method and path — never the headers
    or body (the no-leak guarantee). Sizes/status/timing are supplied by the driver. -/
def AccessRecord.ofExchange (connId : Nat) (secure : Bool) (req : HttpRequest)
    (status reqBytes respBytes durationMs : Nat) : AccessRecord :=
  { connId, secure, method := logMethodToken req.method, path := req.target.path,
    status, reqBytes, respBytes, durationMs }

/-- Assemble the raw logfmt line (before the final sanitization pass). -/
def AccessRecord.assemble (r : AccessRecord) : String :=
  "conn=" ++ toString r.connId ++
  " secure=" ++ (if r.secure then "1" else "0") ++
  " method=" ++ r.method ++
  " path=" ++ r.path ++
  " status=" ++ toString r.status ++
  " req=" ++ toString r.reqBytes ++
  " resp=" ++ toString r.respBytes ++
  " dur_ms=" ++ toString r.durationMs

/-- Render a record to a single log line, scrubbed of all control characters as a final
    pass — so no field (notably the attacker-controlled path) can inject a newline. The
    logger appends its own line terminator. -/
def AccessRecord.render (r : AccessRecord) : String := sanitize r.assemble

end Jemmet
