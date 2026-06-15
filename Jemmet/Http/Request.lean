/-
  Jemmet.Http.Request — the HTTP/1.1 request model and the request-head parser
  (RFC 004; hands normalized headers to RFC 003's framing engine).

  `parseRequestHead` reads the request line and header block from a `Reader` and
  returns one of `needMore` / `reject e` / `parsed head rest`. It is total over all
  byte inputs (header loop bounded by fuel = header-count limit), validates names and
  values (rejecting CRLF/control injection and obs-fold — RFC 003 danger zones), and
  enforces the request-line / header-count / header-size limits with the right status
  taxonomy. Incomplete input yields `needMore` (the serve loop reads more); there is
  no partial-parse state to confuse boundaries.
-/
import Jemmet.Http.Bytes
import Jemmet.Http.Framing

namespace Jemmet

/-! ### Request model -/

/-- HTTP request method. Unknown tokens are preserved verbatim in `other`. -/
inductive Method where
  | get | head | post | put | delete | patch | options | connect | trace
  | other (token : String)
  deriving Repr, DecidableEq, BEq, Inhabited

def Method.ofString : String → Method
  | "GET" => .get | "HEAD" => .head | "POST" => .post | "PUT" => .put
  | "DELETE" => .delete | "PATCH" => .patch | "OPTIONS" => .options
  | "CONNECT" => .connect | "TRACE" => .trace
  | s => .other s

/-- HTTP version. jemmet serves 1.0/1.1; anything else is rejected (→ 505). -/
inductive Version where
  | http10 | http11
  deriving Repr, DecidableEq, BEq, Inhabited

def Version.ofString? : String → Option Version
  | "HTTP/1.0" => some .http10
  | "HTTP/1.1" => some .http11
  | _          => none

/-- An origin-form request target: the raw target plus its split path/query. -/
structure RequestTarget where
  raw   : String
  path  : String
  query : Option String
  deriving Repr, DecidableEq, BEq, Inhabited

def RequestTarget.ofString (s : String) : RequestTarget :=
  match s.splitOn "?" with
  | p :: rest@(_ :: _) => { raw := s, path := p, query := some (String.intercalate "?" rest) }
  | _                  => { raw := s, path := s, query := none }

/-- The parsed request head (line + headers), before body framing/consumption. -/
structure RequestHead where
  method  : Method
  target  : RequestTarget
  version : Version
  headers : Headers
  deriving Repr, Inhabited

/-- The body framing this head implies (RFC 003). -/
def RequestHead.framing (h : RequestHead) : Except FramingError BodyFraming :=
  decideFraming h.headers

/-- The full request model (External Design §4.4.2). Body assembly (Content-Length
    via `takeN`, chunked via the decoder) lands with the response/chunked work; this
    phase produces the head and the framing decision. -/
structure HttpRequest where
  method  : Method
  target  : RequestTarget
  version : Version
  headers : Headers
  framing : BodyFraming
  body    : ByteArray
  deriving Inhabited

/-! ### Errors and limits -/

/-- Parser rejection taxonomy, each mapping to an HTTP status. -/
inductive ParseError where
  | badRequestLine        -- 400
  | uriTooLong            -- 414
  | badVersion            -- 505
  | headerFieldsTooLarge  -- 431
  | badHeader             -- 400 (bad name/value, ws-before-colon, obs-fold)
  | badLineDiscipline     -- 400 (bare CR/LF)
  | badFraming            -- 400 (CL+TE, multiple CL, bad TE — a smuggling refusal)
  | badChunk              -- 400 (malformed chunk size/data/terminator/trailer)
  | bodyTooLarge          -- 413
  deriving Repr, DecidableEq, BEq, Inhabited

def ParseError.statusCode : ParseError → Nat
  | .uriTooLong           => 414
  | .badVersion           => 505
  | .headerFieldsTooLarge => 431
  | .bodyTooLarge         => 413
  | _                     => 400

/-- Request limits with safe defaults (Requirements §3.2.4). -/
structure Limits where
  maxRequestLineBytes : Nat := 8192
  maxHeaderCount      : Nat := 100
  maxHeaderBytes      : Nat := 16384
  maxHeaderLineBytes  : Nat := 8192
  maxBodyBytes        : Nat := 1048576   -- 1 MiB assembled body cap (→ 413)
  maxChunkLineBytes   : Nat := 8192      -- chunk-size line incl. extensions (→ 400)
  deriving Repr, Inhabited

/-- Outcome of parsing a request head. -/
inductive ParseHeadResult where
  | needMore
  | reject (e : ParseError)
  | parsed (head : RequestHead) (rest : Reader)
  deriving Inhabited

/-! ### Byte helpers -/

@[inline] def allBytes (p : UInt8 → Bool) (b : ByteArray) : Bool := b.toList.all p

/-- A printable-ASCII request-line byte (no controls, no 8-bit). -/
@[inline] def isReqLineByte (b : UInt8) : Bool := inByteRange b 0x20 0x7E

/-- Trim leading/trailing OWS (SP/HT) from a byte array. -/
def trimOWS (b : ByteArray) : ByteArray :=
  let l := b.toList.dropWhile isOWS
  ⟨((l.reverse.dropWhile isOWS).reverse).toArray⟩

/-! ### Request-line parser -/

/-- Parse the request line: exactly `METHOD SP target SP HTTP-version`, all
    printable ASCII, single spaces, three fields. -/
def parseRequestLine (content : ByteArray) : Except ParseError (Method × RequestTarget × Version) :=
  if !allBytes isReqLineByte content then .error .badRequestLine
  else
    let s := asciiString content
    match s.splitOn " " with
    | [m, t, v] =>
      if m.isEmpty || t.isEmpty then .error .badRequestLine
      else if !(m.data.all (fun c => isTChar c.toNat.toUInt8)) then .error .badRequestLine
      else
        match Version.ofString? v with
        | some ver => .ok (Method.ofString m, RequestTarget.ofString t, ver)
        | none     => .error .badVersion
    | _ => .error .badRequestLine

/-! ### Header parser -/

/-- Parse one header line's content (already CRLF-stripped, nonempty) into a
    `(name, value)` pair, applying the validation/danger-zone rules. -/
def parseHeaderLine (content : ByteArray) : Except ParseError (String × String) :=
  -- obs-fold / leading whitespace: a header line may not start with SP/HT.
  match byteAt content 0 with
  | some c0 => if isOWS c0 then .error .badHeader else
    match content.toList.findIdx? (· == 0x3A) with   -- first ':'
    | none => .error .badHeader
    | some ci =>
      let name := content.extract 0 ci
      let value := content.extract (ci + 1) content.size
      -- whitespace before colon → reject (last name byte is OWS)
      let nameBad :=
        name.isEmpty
        || (match byteAt name (name.size - 1) with | some lb => isOWS lb | none => true)
        || !allBytes isTChar name
      if nameBad then .error .badHeader
      else
        let v := trimOWS value
        if !allBytes isValueByte v then .error .badHeader
        else .ok (asciiString name, asciiString v)
  | none => .error .badHeader   -- empty handled by caller; defensive

/-- The header loop. `fuel` bounds the header count; `used` accumulates header-section
    bytes for the total-size limit. Returns `needMore`, a rejection, or the assembled
    headers with the reader positioned after the blank line. -/
def parseHeaderLines (r : Reader) (lim : Limits) (acc : Headers) (used : Nat) :
    Nat → ParseHeadResult
  | 0 => .reject .headerFieldsTooLarge
  | fuel + 1 =>
    match r.takeLine lim.maxHeaderLineBytes with
    | .needMore        => .needMore
    | .reject .tooLong => .reject .headerFieldsTooLarge
    | .reject _        => .reject .badLineDiscipline
    | .line content r' =>
      if content.isEmpty then
        -- blank line: end of headers. (`head` filled in by the caller.)
        .parsed { method := .get, target := ⟨"", "", none⟩, version := .http11, headers := acc } r'
      else
        let used' := used + content.size + 2
        if used' > lim.maxHeaderBytes then .reject .headerFieldsTooLarge
        else if acc.size + 1 > lim.maxHeaderCount then .reject .headerFieldsTooLarge
        else
          match parseHeaderLine content with
          | .error e        => .reject e
          | .ok (name, val) => parseHeaderLines r' lim (acc.add name val) used' fuel

/-- Parse a request head from `r0`. -/
def parseRequestHead (r0 : Reader) (lim : Limits := {}) : ParseHeadResult :=
  match r0.takeLine lim.maxRequestLineBytes with
  | .needMore        => .needMore
  | .reject .tooLong => .reject .uriTooLong
  | .reject _        => .reject .badLineDiscipline
  | .line content r1 =>
    match parseRequestLine content with
    | .error e          => .reject e
    | .ok (m, t, v)     =>
      match parseHeaderLines r1 lim Headers.empty 0 (lim.maxHeaderCount + 1) with
      | .needMore          => .needMore
      | .reject e          => .reject e
      | .parsed head rest  =>
        .parsed { head with method := m, target := t, version := v } rest

end Jemmet
