/-
  Test.Main — entry point for the `conformance` executable (`lake test`).
  Runs the RFC 002 Conn suite, the RFC 003/004 parser + smuggling suite, and the
  RFC 005/006 routing + response + end-to-end suite; exits nonzero on any failure.
-/
import Test.Conformance
import Test.HttpConformance
import Test.IntegrationConformance

def main : IO UInt32 := do
  let connCode ← Test.runAll
  IO.println ""
  let (httpFailed, _) ← Test.Http.run
  IO.println ""
  let (intFailed, _) ← Test.Integration.run
  pure (if connCode == 0 && httpFailed == 0 && intFailed == 0 then 0 else 1)
