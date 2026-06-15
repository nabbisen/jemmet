/-
  Jemmet.Route.Match — path patterns and total, deterministic segment matching
  (RFC 006). `matchPattern` recurses structurally on the pattern and path, so it is
  total and terminating by construction.
-/
namespace Jemmet

/-- A path-pattern segment: a literal or a captured parameter. -/
inductive Segment where
  | static (s : String)
  | param  (name : String)
  deriving Repr, DecidableEq, BEq, Inhabited

abbrev PathPattern := List Segment
abbrev Params := List (String × String)

/-- Split a path into non-empty segments (`/a/b/` → `["a","b"]`). -/
def splitPath (p : String) : List String :=
  (p.splitOn "/").filter (· ≠ "")

/-- Match a pattern against path segments. Returns captured params or `none`.
    Total and deterministic (structural recursion). -/
def matchPattern : PathPattern → List String → Option Params
  | [],               []          => some []
  | [],               _ :: _      => none
  | _ :: _,           []          => none
  | (.static s) :: ps, seg :: segs => if s == seg then matchPattern ps segs else none
  | (.param n) :: ps,  seg :: segs =>
    match matchPattern ps segs with
    | some rest => some ((n, seg) :: rest)
    | none      => none

end Jemmet
