/-
  Jemmet.Http.Framing — the framing engine (RFC 003, the proof centerpiece).

  `decideFraming` resolves Content-Length / Transfer-Encoding into exactly one body
  framing or a hard rejection — it never guesses. The soundness lemmas (no ambiguous
  acceptance; ambiguous inputs rejected) live in `Jemmet.Proofs.FramingSound`; this
  module is the definition the parser (RFC 004) hands normalized `Headers` to.

  The structure is a single `match` on the two header lists so the soundness proof is
  a clean case split. Resolution rules (RFC 003):
    * both CL and TE present                      → reject (.both)
    * multiple Content-Length                     → reject (.multipleCL)
    * Transfer-Encoding present but not exactly
      `chunked` (only, final)                      → reject (.badTE)
    * a single Content-Length, all-digits, no OWS → contentLength n
    * neither                                      → none
-/
import Jemmet.Http.Header

namespace Jemmet

/-- The resolved body framing of a request. -/
inductive BodyFraming where
  | none
  | contentLength (n : Nat)
  | chunked
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Why a header set was rejected as un-frameable (all map to a hard error, never a
    guess). `both` = CL and TE together; `multipleCL` = duplicate Content-Length;
    `badCL` = malformed length; `badTE` = a Transfer-Encoding other than a lone
    `chunked`. -/
inductive FramingError where
  | both
  | multipleCL
  | badCL
  | badTE
  deriving Repr, DecidableEq, BEq, Inhabited

/-- Strict non-negative decimal: nonempty, all ASCII digits, no surrounding OWS
    (rejecting whitespace around the number is an RFC 003 danger-zone rule). -/
def parseDigits (s : String) : Option Nat :=
  if s.isEmpty then none
  else s.foldl (fun acc c =>
    match acc with
    | some n => if '0' ≤ c ∧ c ≤ '9' then some (n * 10 + (c.toNat - 48)) else none
    | none   => none) (some 0)

/-- The combined, normalized Transfer-Encoding coding list: all TE header values
    joined, split on commas, OWS-trimmed, lowercased, with empties dropped. jemmet
    accepts exactly `["chunked"]` (chunked only, and therefore final). -/
def teCodings (h : Headers) : List String :=
  let raw := String.intercalate "," (h.getAll "transfer-encoding")
  ((raw.splitOn ",").map (fun s => asciiLower s.trim)).filter (· ≠ "")

/-- The single-valued framing decision. -/
def decideFraming (h : Headers) : Except FramingError BodyFraming :=
  match h.getAll "content-length", h.getAll "transfer-encoding" with
  | [],        []     => .ok .none
  | _ :: _,    _ :: _ => .error .both
  | v :: [],   []     =>
    match parseDigits v with
    | some n => .ok (.contentLength n)
    | none   => .error .badCL
  | _ :: _ :: _, []   => .error .multipleCL
  | [],        _ :: _ =>
    if teCodings h == ["chunked"] then .ok .chunked else .error .badTE

end Jemmet
