/-
  Jemmet.Route.Router — method+path dispatch to a handler, 404, or 405 (RFC 006).

  `dispatch` is total and deterministic: it resolves to exactly one `Dispatch` for
  every request. `found` is the first route whose method and pattern both match;
  a path match with no method match yields 405 (with the `Allow` set); no path match
  yields 404. Proven in `Jemmet.Proofs.RouterTotal`.
-/
import Jemmet.Route.Handler

namespace Jemmet

/-- A route: a method, a path pattern, and a handler. -/
structure Route where
  method  : Method
  pattern : PathPattern
  handler : Handler

/-- A routing table. -/
structure Router where
  routes : List Route

/-- The result of dispatch: a handler with params, 404, or 405 (with allowed methods). -/
inductive Dispatch where
  | found (h : Handler) (params : Params)
  | notFound
  | methodNotAllowed (allow : List Method)

/-- First route whose method and pattern both match. -/
def findHandler (m : Method) (path : List String) : List Route → Option (Handler × Params)
  | []        => none
  | rt :: rest =>
    if rt.method = m then
      match matchPattern rt.pattern path with
      | some ps => some (rt.handler, ps)
      | none    => findHandler m path rest
    else findHandler m path rest

/-- Methods whose route pattern matches the path (the `Allow` set for 405). -/
def allowedMethods (path : List String) : List Route → List Method
  | []        => []
  | rt :: rest =>
    if (matchPattern rt.pattern path).isSome then rt.method :: allowedMethods path rest
    else allowedMethods path rest

/-- Total, deterministic dispatch. -/
def Router.dispatch (rtr : Router) (req : RequestHead) : Dispatch :=
  match findHandler req.method (splitPath req.target.path) rtr.routes with
  | some (h, ps) => .found h ps
  | none =>
    match allowedMethods (splitPath req.target.path) rtr.routes with
    | []          => .notFound
    | a :: allow  => .methodNotAllowed (a :: allow)

end Jemmet
