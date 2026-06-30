/-
  Jemmet.Http.Stream — chunked response streaming (RFC 005).

  Large or generated response bodies must not be fully serialized before backpressure can
  apply (the RFC 010 egress bound). This module adds a pull-based streaming interface: a
  body is a sequence of chunks emitted **one at a time** via `streamStep`, each framed with
  the proven chunk encoder. The driver appends one encoded chunk per step and flushes under
  the egress cap, so owned output stays bounded no matter how large the body is — the
  per-step addition is exactly one chunk (`Jemmet.Proofs.StreamBound`).

  The handler-facing source is `IO (Option ByteArray)` (pull the next chunk, or `none` when
  done); a `List ByteArray` backs it for proofs and tests.
-/
import Jemmet.Http.Chunked

namespace Jemmet

/-- A streaming response body modeled as the chunks still to emit (the real source is an
    `IO (Option ByteArray)` pull; this list backs it for proofs/tests). -/
abbrev ChunkStream := List ByteArray

/-- The chunked terminator: the final `0`-size chunk and the (empty) trailer. -/
def streamTerminator : ByteArray := "0\r\n\r\n".toUTF8

/-- Encode an entire chunk stream as a chunked body: each chunk framed, then the
    terminator. (Materializes the whole body — used as the round-trip oracle; the driver
    uses `streamStep` instead, which never materializes more than one chunk.) -/
def encodeStream (chunks : ChunkStream) : ByteArray :=
  (chunks.foldl (fun acc c => acc ++ encodeChunk c) ByteArray.empty) ++ streamTerminator

/-- One bounded streaming step: emit the next chunk's framing, or the terminator when the
    stream is exhausted. Returns `(bytes-to-send, remaining, done?)`. The per-step output
    is exactly one encoded chunk — the bound that keeps streaming within the egress cap. -/
def streamStep : ChunkStream → ByteArray × ChunkStream × Bool
  | []      => (streamTerminator, [], true)
  | c :: cs => (encodeChunk c, cs, false)

/-- The handler-facing streaming source: pull the next chunk, or `none` when finished. -/
abbrev StreamSource := IO (Option ByteArray)

/-- Back a `StreamSource` with an in-memory chunk list (for tests). The reference cell
    holds the remaining chunks; each pull pops one. -/
def StreamSource.ofList (chunks : ChunkStream) : IO StreamSource := do
  let ref ← IO.mkRef chunks
  pure do
    let cs ← ref.get
    match cs with
    | []      => pure none
    | c :: cs => ref.set cs; pure (some c)

end Jemmet
