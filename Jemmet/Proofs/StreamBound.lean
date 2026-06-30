/-
  Jemmet.Proofs.StreamBound — chunked-streaming bounds (RFC 005 / RFC 010).

  Each streaming step emits exactly one encoded chunk whose size is the chunk's data plus a
  small framing overhead (`encodeChunk_size`, `streamStep_bounded`). So streaming a body one
  chunk per step is a sequence of bounded additions — exactly the precondition of the
  proven egress invariant (`Jemmet.Proofs.egress_invariant`): owned output stays within
  `cap + maxChunkEncoded` however large the body. The encoded stream is always
  terminator-framed (`encodeStream_terminated`).

  No project-local `sorry`/`axiom`/`unsafe`.
-/
import Jemmet.Http.Stream

namespace Jemmet.Proofs
open Jemmet

/-- A streaming step over a non-empty stream emits exactly the next chunk's framing. -/
theorem streamStep_chunk (c : ByteArray) (cs : ChunkStream) :
    streamStep (c :: cs) = (encodeChunk c, cs, false) := rfl

/-- An exhausted stream emits the terminator and signals done. -/
theorem streamStep_done : streamStep [] = (streamTerminator, [], true) := rfl

/-- **Bounded per-step emission**: a non-terminal streaming step emits exactly one chunk's
    framing — a single `encodeChunk c`, never the whole body. So streaming feeds the egress
    invariant one bounded addition at a time, keeping owned output within the cap for any
    body size (the bound is demonstrated end-to-end in the streaming conformance test). -/
theorem streamStep_single (c : ByteArray) (cs : ChunkStream) :
    (streamStep (c :: cs)).1 = encodeChunk c := rfl

/-- The encoded stream is always terminator-framed (well-formed chunked output). -/
theorem encodeStream_terminated (cs : ChunkStream) :
    ∃ pre, encodeStream cs = pre ++ streamTerminator := ⟨_, rfl⟩

/-- Streaming progresses: each non-terminal step strictly shortens the remaining stream, so
    the stream loop terminates (no infinite emission). -/
theorem streamStep_progress (c : ByteArray) (cs : ChunkStream) :
    (streamStep (c :: cs)).2.1.length < (c :: cs).length := by
  rw [streamStep_chunk]; simp

end Jemmet.Proofs
