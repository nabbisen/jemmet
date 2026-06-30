/-
  Jemmet.Http.Bytes — the bounds-safe byte reader (RFC 004, the parser foundation).

  A `Reader` is a byte buffer plus a read offset, with the invariant `off ≤ size`.
  Every read goes through `ByteArray.get?` (total) or a clamped `extract`, and `off`
  is only ever advanced by a clamped/`min`'d amount or under an explicit
  `off + n ≤ size` guard — so reads never index out of bounds *by construction*
  (proved in `Jemmet.Proofs.ParserBounds`). Line reading enforces a single line
  discipline (strict CRLF; bare CR or bare LF is rejected — an RFC 003 danger zone)
  and a per-line length bound.
-/
import Jemmet.Http.Header

namespace Jemmet

/-- Bounds-safe byte access: `none` exactly when `i` is out of range. The only way
    the parser reads individual bytes — there is no panicking indexing anywhere. -/
@[inline] def byteAt (b : ByteArray) (i : Nat) : Option UInt8 :=
  if h : i < b.size then some b[i] else none

/-- A bounds-safe reader over an accumulating byte buffer. Invariant: `off ≤ data.size`. -/
structure Reader where
  data : ByteArray
  off  : Nat
  deriving Inhabited

namespace Reader

/-- A reader positioned at the start of `b`. -/
def ofBytes (b : ByteArray) : Reader := { data := b, off := 0 }

/-- Total bytes in the buffer. -/
@[inline] def size (r : Reader) : Nat := r.data.size

/-- Bytes remaining from the current offset. -/
@[inline] def remaining (r : Reader) : Nat := r.data.size - r.off


/-- The remaining suffix — the carried remainder for pipelining. -/
@[inline] def rest (r : Reader) : ByteArray := r.data.extract r.off r.data.size

/-- Advance by `k`, clamped so `off ≤ size`. -/
@[inline] def advance (r : Reader) (k : Nat) : Reader :=
  { r with off := Nat.min r.data.size (r.off + k) }

/-- Read exactly `n` bytes if available; `none` (need more) otherwise. The returned
    reader satisfies `off' = off + n ≤ size`. -/
def takeN (r : Reader) (n : Nat) : Option (ByteArray × Reader) :=
  if r.off + n ≤ r.data.size then
    some (r.data.extract r.off (r.off + n), { r with off := r.off + n })
  else
    none

/-- Why a line read was rejected. -/
inductive LineError where
  | tooLong
  | bareCR
  | bareLF
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Result of expecting a literal CRLF (used for chunk terminators, where the data is
    binary and cannot be line-scanned). -/
inductive CrlfResult where
  | ok (r : Reader)
  | needMore
  | reject
  deriving Inhabited

/-- Consume a literal `\r\n` at the read head (binary chunk data cannot be
    line-scanned). On success `off' = off + 2 ≤ size`, reusing `takeN`. -/
def takeCRLF (r : Reader) : CrlfResult :=
  match r.takeN 2 with
  | none          => .needMore
  | some (bs, r') => if bs.toList == [0x0D, 0x0A] then .ok r' else .reject

/-- Result of reading one CRLF-terminated line. -/
inductive LineResult where
  /-- A line (content excludes the terminating CRLF) and the reader past the CRLF. -/
  | line (content : ByteArray) (r : Reader)
  /-- No complete line yet; a longer buffer may complete it. -/
  | needMore
  /-- A hard rejection (bare CR/LF, or line exceeded `maxLen`). -/
  | reject (e : LineError)
  deriving Inhabited

/-- Scan from offset `i` for a strict CRLF terminator, allowing at most `fuel-1`
    content bytes. Bare LF (not preceded by CR) and bare CR (not followed by LF) are
    rejected. Terminates: structural on `fuel`. -/
def scanLine (r : Reader) : Nat → Nat → LineResult
  | _, 0 => .reject .tooLong
  | i, fuel + 1 =>
    match byteAt r.data i with
    | none => .needMore
    | some b =>
      if b == 0x0D then
        match byteAt r.data (i + 1) with
        | none      => .needMore
        | some b2   =>
          if b2 == 0x0A then
            .line (r.data.extract r.off i) { r with off := Nat.min r.data.size (i + 2) }
          else
            .reject .bareCR
      else if b == 0x0A then
        .reject .bareLF
      else
        scanLine r (i + 1) fuel

/-- Read one CRLF-terminated line, content length bounded by `maxLen`. -/
@[inline] def takeLine (r : Reader) (maxLen : Nat) : LineResult :=
  scanLine r r.off (maxLen + 1)

end Reader
end Jemmet
