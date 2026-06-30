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
import Test.IotaktConformance
import Test.HandlerConformance
import Test.Fuzz
import Test.LimitConformance
import Test.ObserveConformance
import Test.HenretConformance
import Test.InteropCorpus
import Test.LifecycleConformance

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
  IO.println ""
  let (iotFailed, _) ← Test.Iotakt.run
  IO.println ""
  let (hdlFailed, _) ← Test.Handler.run
  IO.println ""
  let (limFailed, _) ← Test.Limit.run
  IO.println ""
  let (obsFailed, _) ← Test.Observe.run
  IO.println ""
  let (henFailed, _) ← Test.Henret.run
  IO.println ""
  let (corpusFailed, _) ← Test.Interop.run
  IO.println ""
  let (lifeFailed, _) ← Test.Lifecycle.run
  IO.println ""
  let (fuzzFailed, _) ← Test.Fuzz.run
  pure (if connCode == 0 && httpFailed == 0 && intFailed == 0 && srvFailed == 0 && evFailed == 0 && iotFailed == 0 && hdlFailed == 0 && limFailed == 0 && obsFailed == 0 && henFailed == 0 && corpusFailed == 0 && lifeFailed == 0 && fuzzFailed == 0 then 0 else 1)
