/-
  Jemmet — a small, auditable, formally-disciplined HTTP/1.1 edge server for Lean 4.

  Root facade. As RFCs land, their modules are imported here.

  Planned module tree (External Design §4.2); modules appear as their RFCs are
  implemented, so the build stays green at every milestone:

    Jemmet/
      Conn/   Conn.lean (RFC 002 ✓) · Plain.lean (RFC 008, M2) · Tls.lean (RFC 009, M3)
              Fake.lean (RFC 002 ✓)
      Http/   Bytes/Request/Framing/Chunked/Response/Status/Header (RFC 003–005, M1)
      Route/  Router/Handler/Match (RFC 006, M1)
      Serve/  Loop/ConnState/Backpressure/Config (RFC 007/010/014/015, M2)
      Proofs/ FramingSound/ParserBounds/RouterTotal/ResponseWf/KeepAlive/…

  Currently implemented: RFC 002 (the connection keystone + FakeConn).
-/
import Jemmet.Conn.Conn
import Jemmet.Conn.Fake
import Jemmet.Http
import Jemmet.Route
import Jemmet.Serve
