/-
  Jemmet.Http.Header — header name/value validation and the canonical `Headers`
  collection (RFC 004; feeds RFC 003's framing decision).

  Byte-class predicates are defined in terms of `UInt8.toNat` so they are total and
  decidable, and the parser built on them is bounds-safe by construction (no
  panicking indexing). Header names are canonicalized to lowercase ASCII at parse
  time (resolving RFC 004 open question 2 in favor of parse-time canonicalization),
  so case-insensitive duplicate detection — a smuggling danger zone (RFC 003) — is a
  simple list operation downstream.
-/

namespace Jemmet

/-! ### Byte classes (RFC 7230 token / field-value rules) -/

/-- `b.toNat ∈ [lo, hi]`. -/
@[inline] def inByteRange (b : UInt8) (lo hi : Nat) : Bool :=
  decide (lo ≤ b.toNat ∧ b.toNat ≤ hi)

@[inline] def isDigitByte (b : UInt8) : Bool := inByteRange b 0x30 0x39
@[inline] def isAlphaByte (b : UInt8) : Bool := inByteRange b 0x41 0x5A || inByteRange b 0x61 0x7A

/-- The RFC 7230 `tchar` special characters (besides ALPHA / DIGIT). -/
def tcharSpecials : List UInt8 :=
  [0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E]

/-- A `tchar`: valid in a header (field) name. -/
@[inline] def isTChar (b : UInt8) : Bool :=
  isAlphaByte b || isDigitByte b || tcharSpecials.contains b

/-- A byte allowed in a header *value*: visible ASCII (0x21–0x7E) or SP/HT. jemmet
    rejects bare control bytes, NUL, DEL, and 8-bit obs-text in v0.1 (stricter than
    RFC 7230's obs-text allowance — it removes ambiguity and keeps values ASCII). -/
@[inline] def isValueByte (b : UInt8) : Bool :=
  inByteRange b 0x21 0x7E || b == 0x20 || b == 0x09

/-- Optional whitespace (OWS): SP or HT. -/
@[inline] def isOWS (b : UInt8) : Bool := b == 0x20 || b == 0x09

/-! ### ASCII helpers -/

/-- Lowercase an ASCII string (bytes ≥ 0x80 untouched). Used to canonicalize names. -/
def asciiLower (s : String) : String :=
  String.mk (s.data.map fun c => if 'A' ≤ c ∧ c ≤ 'Z' then Char.ofNat (c.toNat + 32) else c)

/-- Interpret a validated (ASCII) byte array as a `String`. -/
def asciiString (b : ByteArray) : String :=
  String.mk (b.toList.map (fun u => Char.ofNat u.toNat))

/-! ### The canonical header collection -/

/--
An ordered header collection. Names are stored canonicalized (lowercase ASCII);
values are stored as parsed (trimmed of surrounding OWS). Duplicates are *kept*
(insertion order preserved) so the framing decision (RFC 003) can see every
`Content-Length` / `Transfer-Encoding` occurrence and reject conflicts rather than
silently collapsing them.

Representation is an association list for v0.1; RFC 004 open question 1 (assoc list
vs bounded map and its adversarial-complexity bound) is revisited with RFC 006's
routing keys. The header *count* is bounded by the parser (→ 431), so the list
length is bounded for adversarial input.
-/
structure Headers where
  entries : List (String × String)
  deriving Repr, Inhabited, BEq

namespace Headers

def empty : Headers := { entries := [] }

/-- Append a header. `name` is canonicalized to lowercase here. -/
def add (h : Headers) (name value : String) : Headers :=
  { entries := h.entries ++ [(asciiLower name, value)] }

/-- All values for a (case-insensitive) name, in order. -/
def getAll (h : Headers) (name : String) : List String :=
  let key := asciiLower name
  h.entries.filterMap (fun (n, v) => if n == key then some v else none)

/-- The first value for a name, if any. -/
def get? (h : Headers) (name : String) : Option String :=
  (h.getAll name).head?

/-- Number of header entries (counts duplicates). -/
def size (h : Headers) : Nat := h.entries.length

end Headers
end Jemmet
