/-
  Jemmet.Http.Chunked — chunked transfer decoding (request) and encoding (response),
  plus full-request body assembly (RFC 003 §danger-zones, RFC 004).

  Decoding is bounds-safe by construction (every read goes through the `Reader`
  primitives) and deterministic: a malformed chunk size / data / terminator / trailer
  is rejected (`badChunk`), an over-cap body is rejected (`bodyTooLarge`), and an
  incomplete stream yields `needMore`. Extensions are ignored but bounded (the size
  line is length-capped); trailers are consumed and bounded. The body-suffix /
  bounds properties are proven in `Jemmet.Proofs.ChunkedBounds`.
-/
import Jemmet.Http.Request
import Jemmet.Http.Framing

namespace Jemmet

/-! ### Chunk-size line parsing (hex prefix, extensions ignored) -/

/-- Hex digit value, or `none`. -/
def hexVal (b : UInt8) : Option Nat :=
  if 0x30 ≤ b && b ≤ 0x39 then some (b.toNat - 0x30)
  else if 0x41 ≤ b && b ≤ 0x46 then some (b.toNat - 0x41 + 10)
  else if 0x61 ≤ b && b ≤ 0x66 then some (b.toNat - 0x61 + 10)
  else none

/-- Parse the hex prefix of a chunk-size line. Requires ≥1 hex digit; a `;` begins an
    (ignored) extension; any other non-hex byte is a rejection. -/
def parseChunkSizeAux (line : ByteArray) (i acc : Nat) (saw : Bool) : Nat → Option Nat
  | 0 => if saw then some acc else none
  | fuel + 1 =>
    match byteAt line i with
    | none   => if saw then some acc else none
    | some b =>
      if b == 0x3B then (if saw then some acc else none)   -- ';' extension start
      else match hexVal b with
        | some v => parseChunkSizeAux line (i + 1) (acc * 16 + v) true fuel
        | none   => none

def parseChunkSize (line : ByteArray) : Option Nat :=
  parseChunkSizeAux line 0 0 false line.size

/-! ### Decoding -/

inductive ChunkResult where
  | needMore
  | reject (e : ParseError)
  | done (body : ByteArray) (rest : Reader)
  deriving Inhabited

inductive TrailerResult where
  | needMore
  | reject (e : ParseError)
  | done (rest : Reader)
  deriving Inhabited

/-- Consume trailer lines (bounded) until a blank line ends the trailer section. -/
def consumeTrailers (r : Reader) (lim : Limits) : Nat → TrailerResult
  | 0 => .reject .badChunk
  | fuel + 1 =>
    match r.takeLine lim.maxChunkLineBytes with
    | .needMore       => .needMore
    | .reject _       => .reject .badChunk
    | .line content r1 =>
      if content.isEmpty then .done r1
      else consumeTrailers r1 lim fuel

/-- Decode a chunked body, accumulating into `acc`. Bounded by `fuel` (chunk count). -/
def decodeChunked (r : Reader) (lim : Limits) (acc : ByteArray) : Nat → ChunkResult
  | 0 => .reject .badChunk
  | fuel + 1 =>
    match r.takeLine lim.maxChunkLineBytes with
    | .needMore        => .needMore
    | .reject _        => .reject .badChunk
    | .line sizeLine r1 =>
      match parseChunkSize sizeLine with
      | none    => .reject .badChunk
      | some sz =>
        if sz = 0 then
          match consumeTrailers r1 lim (lim.maxHeaderCount + 1) with
          | .needMore => .needMore
          | .reject e => .reject e
          | .done r2  => .done acc r2
        else
          if acc.size + sz > lim.maxBodyBytes then .reject .bodyTooLarge
          else
            match r1.takeN sz with
            | none => .needMore
            | some (data, r2) =>
              match r2.takeCRLF with
              | .needMore => .needMore
              | .reject   => .reject .badChunk
              | .ok r3    => decodeChunked r3 lim (acc ++ data) fuel

/-! ### Encoding (response direction) -/

def natToHexAux (n : Nat) (acc : List Char) : Nat → List Char
  | 0        => if acc.isEmpty then ['0'] else acc
  | fuel + 1 =>
    if n == 0 then (if acc.isEmpty then ['0'] else acc)
    else
      let d := n % 16
      let c := if d < 10 then Char.ofNat (0x30 + d) else Char.ofNat (0x61 + (d - 10))
      natToHexAux (n / 16) (c :: acc) fuel

def natToHex (n : Nat) : String := ⟨natToHexAux n [] (n + 1)⟩

/-- Encode one non-empty data chunk: `<hex-size>\r\n<data>\r\n`. -/
def encodeChunk (b : ByteArray) : ByteArray :=
  (natToHex b.size).toUTF8 ++ "\r\n".toUTF8 ++ b ++ "\r\n".toUTF8

/-- Encode a complete chunked body (one data chunk if non-empty, then the terminator). -/
def encodeChunked (b : ByteArray) : ByteArray :=
  (if b.isEmpty then ByteArray.empty else encodeChunk b) ++ "0\r\n\r\n".toUTF8

/-! ### Full-request body assembly: head → framing → body -/

inductive RequestResult where
  | needMore
  | reject (e : ParseError)
  | parsed (req : HttpRequest) (rest : Reader)
  deriving Inhabited

/-- Parse a complete request: the head (RFC 004), the framing decision (RFC 003),
    and the body consumed per that decision. -/
def parseRequest (r0 : Reader) (lim : Limits := {}) : RequestResult :=
  match parseRequestHead r0 lim with
  | .needMore       => .needMore
  | .reject e       => .reject e
  | .parsed head r1 =>
    -- RFC 9112 §3.2: an HTTP/1.1 request MUST carry exactly one Host header; any request
    -- with more than one Host is rejected. (Host value well-formedness is covered by header
    -- value validation.)
    let hostCount := (head.headers.getAll "host").length
    if (head.version == .http11 && hostCount != 1) || hostCount > 1 then .reject .badHost
    else
    match decideFraming head.headers with
    | .error _ => .reject .badFraming
    | .ok fr =>
      match fr with
      | .none =>
        .parsed { method := head.method, target := head.target, version := head.version,
                  headers := head.headers, framing := .none, body := ByteArray.empty } r1
      | .contentLength n =>
        if n > lim.maxBodyBytes then .reject .bodyTooLarge
        else
          match r1.takeN n with
          | none => .needMore
          | some (body, r2) =>
            .parsed { method := head.method, target := head.target, version := head.version,
                      headers := head.headers, framing := .contentLength n, body := body } r2
      | .chunked =>
        match decodeChunked r1 lim ByteArray.empty (lim.maxBodyBytes + 2) with
        | .needMore => .needMore
        | .reject e => .reject e
        | .done body r2 =>
          .parsed { method := head.method, target := head.target, version := head.version,
                    headers := head.headers, framing := .chunked, body := body } r2

end Jemmet
