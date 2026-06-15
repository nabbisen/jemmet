/-
  Test.Main — entry point for the `conformance` executable (`lake test`).
  Runs the RFC 002 Conn suite, the RFC 003/004 parser + smuggling + chunked suite, the
  RFC 005/006 routing + response + e2e suite, and the RFC 007 serve-loop suite; exits
  nonzero on any failure.
-/
import Test.Conformance
import Test.HttpConformance
import Test.IntegrationConformance
import Test.ServeConformance
import Test.EventConformance

def main : IO UInt32 := do
  let connCode ← Test.runAll
  IO.println ""
  let (httpFailed, _) ← Test.Http.run
  IO.println ""
  let (intFailed, _) ← Test.Integration.run
  IO.println ""
  let (srvFailed, _) ← Test.Serve.run
  IO.println ""
  let (evFailed, _) ← Test.Event.run
  pure (if connCode == 0 && httpFailed == 0 && intFailed == 0 && srvFailed == 0 && evFailed == 0 then 0 else 1)
