/-
  Jemmet.Route.Handler — the request context and typed handler (RFC 006).
-/
import Jemmet.Http.Request
import Jemmet.Http.Response
import Jemmet.Route.Match

namespace Jemmet

/-- What a handler sees: the parsed head, captured path params, and the body. -/
structure RequestCtx where
  head   : RequestHead
  params : Params
  body   : ByteArray := ByteArray.empty
  deriving Inhabited

/-- A handler turns a request context into a response. -/
abbrev Handler := RequestCtx → IO HttpResponse

end Jemmet
