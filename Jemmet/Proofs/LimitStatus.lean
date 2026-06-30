/-
  Jemmet.Proofs.LimitStatus — the limit/error → HTTP status mapping (RFC 010).

  Every malformed-input / limit-exceeded case maps to a single, deterministic HTTP error
  status — never undefined behaviour and never a 2xx/3xx. These lemmas pin the mapping so a
  regression that changed a status code (or returned a success code for an error) fails the
  build, and `statusCode_is_error` proves the whole mapping lands in the 4xx/5xx range.
-/
import Jemmet.Http.Request

namespace Jemmet.Proofs
open Jemmet

theorem statusCode_uriTooLong :
    ParseError.uriTooLong.statusCode = 414 := rfl
theorem statusCode_badVersion :
    ParseError.badVersion.statusCode = 505 := rfl
theorem statusCode_headerFieldsTooLarge :
    ParseError.headerFieldsTooLarge.statusCode = 431 := rfl
theorem statusCode_bodyTooLarge :
    ParseError.bodyTooLarge.statusCode = 413 := rfl
theorem statusCode_badRequestLine :
    ParseError.badRequestLine.statusCode = 400 := rfl
theorem statusCode_badHeader :
    ParseError.badHeader.statusCode = 400 := rfl
theorem statusCode_badLineDiscipline :
    ParseError.badLineDiscipline.statusCode = 400 := rfl
theorem statusCode_badFraming :
    ParseError.badFraming.statusCode = 400 := rfl
theorem statusCode_badChunk :
    ParseError.badChunk.statusCode = 400 := rfl
theorem statusCode_badHost :
    ParseError.badHost.statusCode = 400 := rfl

/-- **Every parse error maps to a valid HTTP error status** (4xx/5xx) — never a 2xx/3xx,
    never undefined. The malformed-input → status map is total and lands in the error
    range. -/
theorem statusCode_is_error (e : ParseError) : 400 ≤ e.statusCode ∧ e.statusCode ≤ 505 := by
  cases e <;> exact ⟨by decide, by decide⟩

end Jemmet.Proofs
