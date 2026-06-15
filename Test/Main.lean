/-
  Test.Main — entry point for the `jemmet-test` executable (`lake test`).
  Runs the RFC 002 `Conn` conformance suite; exits nonzero on any failure.
-/
import Test.Conformance

def main : IO UInt32 := Test.runAll
