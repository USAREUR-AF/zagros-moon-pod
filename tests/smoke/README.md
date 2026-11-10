# moon-pod — bidirectional smoke tests

The self-contained router path is runnable as `../router-forwarding-local.sh`; the remaining
live-fabric checks below require an enrolled validation host.

## Two layers

### 1. Self-contained loopback (CI — no fabric needed)

`tests/router-forwarding-local.sh` stands up the pod's `zenoh-router` plus a **stub remote Zenoh**,
both mTLS, and asserts:

- **Outbound:** publish on `${PARTNER_NAMESPACE}/test/ping` at the pod side → received at the
  stub-remote side.
- **Inbound:** publish on `release/goat/test/pong` at the stub-remote side → received by a
  slot-authenticated client at the pod side.
- **ACL negative:** publish outside `${PARTNER_NAMESPACE}/**` → **denied** (default-deny holds).
- **Inbound direction:** with a distinct inbound prefix, a pod-local write into it is denied while
  fabric-originated data is delivered; with the sandbox's shared slot/inbound prefix, normal slot
  publishing remains allowed by the first-party rule.
- **Interest routing:** a fabric subscriber on `*/**` receives the outbound slot publish. A
  pod-local `**` subscription can match allowed traffic from another local pod session, but its
  broad interest is not propagated upstream.

`tests/fabric-peer-identity-local.sh` also exercises the exact certificate-discovery helper sourced
by first-boot: CA verification, TLS pin matching, endpoint parsing, safe CNs, and distinct pod/router
identities. `.github/workflows/router-forwarding.yml` runs both gates in CI. The separate
`tests/audit-sink-local.sh` workflow checks the observe-only sink's Prometheus counter.

### 2. Live zagros-sandbox validation (slow step, on the validation host)

Run the real `first-boot.sh zagros <bundle.cbor>` against the **live zagros sandbox fabric**
(sandbox router directly; no partner-net, no release-bridge — see
`../../docs/zagros-vs-production.md`), then:

- `goat doctor` → mesh up, router handshake, fabric reachable.
- `goat pub <your-slot>/test/...` → observed on the fabric (zagros writes are the per-uuid slot;
  `release/<partner>/**` is the production shape).
- `goat sub '<inbound-prefix>/**'` → observed at the pod (when a counterpart publishes; on zagros
  the inbound prefix falls back to your own slot until a bilateral grant exists).
- Audit: observe-only in v0 — check the sink's metrics; durable NDJSON on the LUKS volume is the
  follow-up.

The live walk is narrated end-to-end in [`../../docs/partner-run-guide.md`](../../docs/partner-run-guide.md).
