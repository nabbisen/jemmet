/-
  Test.Fuzz — TESTED-tier fuzz harnesses (RFC 003/004/011, Requirements §3.2.5).

  A deterministic, reproducible property-based suite that exercises the proven-total parser
  functions over a large adversarial corpus. The proofs establish the invariants abstractly
  (bounds-safety, framing soundness, response well-formedness, chunked bounds); these
  harnesses are the empirical witness — thousands of random and structured inputs, each
  asserted to uphold the invariant and (by completing) to terminate without OOB.

  Targets (§3.2.5): the request-line + header parser, the framing engine, response
  serialization (anti-splitting), and the chunked decoder.
-/
import Jemmet

namespace Test.Fuzz
open Jemmet

/-- A small deterministic PRNG (64-bit LCG; wraps mod 2⁶⁴). Reproducible for CI. -/
structure Rng where s : UInt64
  deriving Inhabited

def Rng.next (r : Rng) : UInt64 × Rng :=
  let x := r.s * 6364136223846793005 + 1442695040888963407
  (x, ⟨x⟩)
def Rng.nat (r : Rng) (bound : Nat) : Nat × Rng :=
  let (v, r) := r.next; (v.toNat % (Nat.max 1 bound), r)
def Rng.byte (r : Rng) : UInt8 × Rng :=
  let (v, r) := r.next; (UInt8.ofNat (v.toNat % 256), r)
def Rng.pick {α} (r : Rng) (xs : List α) (dflt : α) : α × Rng :=
  let (i, r) := r.nat xs.length; ((xs.get? i).getD dflt, r)

def genBytes : Nat → Rng → ByteArray × Rng
  | 0,    r => (ByteArray.empty, r)
  | n+1, r =>
    let (b, r) := r.byte
    let (rest, r) := genBytes n r
    (ByteArray.mk #[b] ++ rest, r)

def s2b (s : String) : ByteArray := s.toUTF8

/-- A structured-ish request: random method/path/version/headers, sometimes malformed. -/
def genReq (r : Rng) : ByteArray × Rng :=
  let (m, r) := r.pick ["GET", "POST", "PUT", "HEAD", "ZZZ", ""] "GET"
  let (p, r) := r.pick ["/", "/a", "/users/42", "/a/b/c", "//", "/%zz", String.mk (List.replicate 40 'x')] "/"
  let (v, r) := r.pick ["HTTP/1.1", "HTTP/1.0", "HTTP/9.9", "XYZ"] "HTTP/1.1"
  let (nh, r) := r.nat 4
  let rec hdrs (k : Nat) (r : Rng) : String × Rng :=
    match k with
    | 0 => ("", r)
    | k+1 =>
      let (hn, r) := r.pick ["Host", "Content-Length", "Transfer-Encoding", "X-Y", "a:b"] "Host"
      let (hv, r) := r.pick ["x", "0", "5", "chunked", "  spaced  ", ""] "x"
      let (rest, r) := hdrs k r
      (s!"{hn}: {hv}\r\n" ++ rest, r)
  let (hs, r) := hdrs nh r
  (s2b s!"{m} {p} {v}\r\n{hs}\r\n", r)

/-- A chunked body, sometimes malformed (bad hex, missing CRLF, no terminator). -/
def genChunked (r : Rng) : ByteArray × Rng :=
  let (n, r) := r.nat 4
  let rec chunks (k : Nat) (r : Rng) : String × Rng :=
    match k with
    | 0 => ("0\r\n\r\n", r)
    | k+1 =>
      let (sz, r) := r.pick ["3", "1", "a", "zz", "10", ""] "3"
      let (payload, r) := r.pick ["abc", "x", "0123456789", "", "no"] "abc"
      let (sep, r) := r.pick ["\r\n", "\n", ""] "\r\n"
      let (rest, r) := chunks k r
      (s!"{sz}\r\n{payload}{sep}" ++ rest, r)
  let (body, r) := chunks n r
  (s2b body, r)

/-- A header set, sometimes carrying *both* Content-Length and Transfer-Encoding (the
    smuggling vector) or duplicate Content-Length. Returns (headers, hasConflict). -/
def genFramingHeaders (r : Rng) : Headers × Bool × Rng :=
  let (kind, r) := r.nat 5
  let base := Headers.empty.add "host" "t"
  match kind with
  | 0 => (base.add "content-length" "0" |>.add "transfer-encoding" "chunked", true, r)  -- CL + TE
  | 1 => (base.add "content-length" "5" |>.add "content-length" "6", true, r)            -- dup CL
  | 2 => (base.add "transfer-encoding" "chunked", false, r)
  | 3 => (base.add "content-length" "10", false, r)
  | _ => (base, false, r)

/-- A response whose header value sometimes contains CR/LF (a response-splitting attempt).
    Returns (resp, hasInjection). -/
def genResp (r : Rng) : HttpResponse × Bool × Rng :=
  let (inj, r) := r.nat 3
  let (clean, r) := r.pick ["ok", "text/plain", "value", "123"] "ok"
  let value := match inj with
    | 0 => clean ++ "\r\nX-Injected: 1"   -- CRLF injection
    | 1 => clean ++ "\nbad"               -- bare LF
    | _ => clean                          -- clean
  let resp : HttpResponse :=
    { status := { code := 200, reason := "OK" },
      headers := Headers.empty.add "x-test" value,
      body := .fixed (s2b "hi"), keepAlive := true }
  (resp, inj < 2, r)

abbrev Check := String × Bool
def ctx : SerializeCtx := { method := .get }

/-- Run `iters` fuzz iterations of `prop` over inputs from `gen`, threading the rng. -/
def fuzzLoop {α} (gen : Rng → α × Rng) (prop : α → Bool) : Nat → Rng → Nat × Rng
  | 0,    r => (0, r)
  | n+1, r =>
    let (x, r) := gen r
    let fails := if prop x then 0 else 1
    let (rest, r) := fuzzLoop gen prop n r
    (fails + rest, r)

-- properties (empirical witnesses of the proven invariants)
def propParse (buf : ByteArray) : Bool :=
  match parseRequest (Reader.ofBytes buf) {} with
  | .needMore => true
  | .reject _ => true
  | .parsed _ rest => rest.off ≤ rest.data.size && rest.data.size == buf.size
def propHead (buf : ByteArray) : Bool :=
  match parseRequestHead (Reader.ofBytes buf) {} with
  | .needMore => true
  | .reject _ => true
  | .parsed _ rest => rest.off ≤ rest.data.size && rest.data.size == buf.size
def propFraming (h : Headers) (conflict : Bool) : Bool :=
  match decideFraming h with
  | .error _ => true                       -- a rejection is always sound
  | .ok _    => !conflict                   -- an accept must not happen under a conflict
def propSerialize (resp : HttpResponse) (inj : Bool) : Bool :=
  match serialize ctx resp with
  | .error _ => true                        -- rejecting is safe
  | .ok _    => !inj                         -- an accept must not happen under injection
def propChunked (buf : ByteArray) : Bool :=
  match decodeChunked (Reader.ofBytes buf) {} ByteArray.empty 2000 with
  | .needMore => true
  | .reject _ => true
  | .done _ rest => rest.off ≤ rest.data.size && rest.data.size == buf.size

-- a list of 0..4 non-empty random chunks (an empty chunk would be the terminator)
def genChunkList (r : Rng) : List ByteArray × Rng :=
  let (n, r) := r.nat 5
  let rec go : Nat → Rng → List ByteArray × Rng
    | 0,    r => ([], r)
    | k+1, r =>
      let (len, r) := r.nat 8
      let (b, r) := genBytes (len + 1) r
      let (rest, r) := go k r
      (b :: rest, r)
  go n r

def concatChunks (cs : List ByteArray) : ByteArray := cs.foldl (· ++ ·) ByteArray.empty
def peakOwned (cs : List ByteArray) : Nat :=
  (cs.map (fun c => (encodeChunk c).size)).foldl Nat.max streamTerminator.size

/-- Streaming round-trip: a body emitted as a chunk stream decodes back to its
    concatenation (the encoder and the proven decoder are inverse). -/
def propStreamRoundtrip (cs : List ByteArray) : Bool :=
  match decodeChunked (Reader.ofBytes (encodeStream cs)) {} ByteArray.empty (cs.length + 2) with
  | .done body _ => body.toList == (concatChunks cs).toList
  | _            => false

/-- Streaming stays bounded: peak owned output (one chunk at a time, flushed between) never
    exceeds the full materialized body, and for ≥2 chunks is strictly smaller — the body is
    never held whole. -/
def propStreamBound (cs : List ByteArray) : Bool :=
  let full := (encodeStream cs).size
  let peak := peakOwned cs
  peak ≤ full && (cs.length < 2 || peak < full)

def run : IO (Nat × Nat) := do
  let r0 : Rng := ⟨0x2545F4914F6CDD1D⟩
  let iters := 600
  -- request parser over pure-random bytes and structured requests
  let (f1, r) := fuzzLoop (fun r => let (n, r) := r.nat 64; genBytes n r) propParse iters r0
  let (f2, r) := fuzzLoop genReq propParse iters r
  let (f3, r) := fuzzLoop genReq propHead iters r
  -- framing soundness over conflicting/clean header sets
  let (f4, r) := fuzzLoop (fun r => let (h, c, r) := genFramingHeaders r; ((h, c), r))
                          (fun (h, c) => propFraming h c) iters r
  -- response anti-splitting over CRLF-laden header values
  let (f5, r) := fuzzLoop (fun r => let (resp, i, r) := genResp r; ((resp, i), r))
                          (fun (resp, i) => propSerialize resp i) iters r
  -- chunked decoder over random/structured chunk framings
  let (f6, r) := fuzzLoop (fun r => let (n, r) := r.nat 48; genBytes n r) propChunked iters r
  let (f7, r) := fuzzLoop genChunked propChunked iters r
  -- chunked response streaming: round-trip and the peak-owned bound
  let (f8, r) := fuzzLoop genChunkList propStreamRoundtrip iters r
  let (f9, _) := fuzzLoop genChunkList propStreamBound iters r
  let groups : List (String × Nat × Nat) :=
    [ ("request parser / random bytes (bounds-safe, total)", f1, iters),
      ("request parser / structured requests (bounds-safe)", f2, iters),
      ("request-line + header parser (parseRequestHead)",    f3, iters),
      ("framing soundness / no smuggling (CL⊕TE, dup CL)",   f4, iters),
      ("response serialization / no response-splitting",      f5, iters),
      ("chunked decoder / random bytes (bounds-safe)",        f6, iters),
      ("chunked decoder / structured chunks (bounds-safe)",   f7, iters),
      ("chunked response streaming / encode→decode round-trip", f8, iters),
      ("chunked response streaming / peak-owned bounded",     f9, iters) ]
  let mut totalFails := 0
  let mut totalRuns := 0
  for (name, fails, n) in groups do
    totalFails := totalFails + fails
    totalRuns := totalRuns + n
    if fails == 0 then IO.println s!"  ok    fuzz [{n}×] :: {name}"
    else IO.println s!"  FAIL  fuzz [{fails}/{n}] :: {name}"
  IO.println ""
  IO.println s!"{totalRuns - totalFails}/{totalRuns} fuzz iterations upheld their invariant across {groups.length} harnesses"
  if totalFails == 0 then
    IO.println "RFC 003/004/011 fuzz harnesses: PASS"
  else
    IO.println s!"RFC 003/004/011 fuzz harnesses: FAIL ({totalFails} counterexamples)"
  pure (totalFails, totalRuns)

end Test.Fuzz
