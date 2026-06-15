/-
  Jemmet.Http.Status — HTTP status codes and reason phrases (RFC 005).
-/
namespace Jemmet

/-- An HTTP status: numeric code plus reason phrase. -/
structure Status where
  code   : Nat
  reason : String
  deriving Repr, DecidableEq, BEq, Inhabited

namespace Status

def ok                    : Status := ⟨200, "OK"⟩
def created               : Status := ⟨201, "Created"⟩
def noContent             : Status := ⟨204, "No Content"⟩
def notModified           : Status := ⟨304, "Not Modified"⟩
def badRequest            : Status := ⟨400, "Bad Request"⟩
def notFound              : Status := ⟨404, "Not Found"⟩
def methodNotAllowed      : Status := ⟨405, "Method Not Allowed"⟩
def payloadTooLarge       : Status := ⟨413, "Payload Too Large"⟩
def uriTooLong            : Status := ⟨414, "URI Too Long"⟩
def headerFieldsTooLarge  : Status := ⟨431, "Request Header Fields Too Large"⟩
def internalServerError   : Status := ⟨500, "Internal Server Error"⟩
def httpVersionNotSupported : Status := ⟨505, "HTTP Version Not Supported"⟩

end Status
end Jemmet
