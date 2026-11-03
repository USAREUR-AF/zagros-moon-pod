# moon-pod — bidirectional smoke test (spec — not yet runnable)

Specifies the gate that proves the v0 core: data moves **both directions** securely through the
pod. This is a **spec with TODOs**, not a runnable harness yet — the assertions below are the
acceptance bar for the `loopback.sh` implementation.

## Two layers

### 1. Self-contained loopback (CI — no fabric needed)

Stand up the pod's `zenoh-router` plus a **stub remote Zenoh** in one compose, both mTLS, and
assert:

- **Outbound:** publish on `${PARTNER_NAMESPACE}/test/ping` at the pod side → received at the
  stub-remote side.
- **Inbound:** publish on `release/goat/test/pong` at the stub-remote side → received via
  `goat-cli sub` at the pod side.
- **ACL negative:** publish outside `${PARTNER_NAMESPACE}/**` → **denied** (default-deny holds).
- **Audit:** TODO — becomes assertable once the audit-sink writes durable NDJSON (v0 is
  observe-only; check the sink's Prometheus counters instead until then).

This is the gate that will run in CI. TODO: implement `loopback.sh` + a stub-remote compose
overlay.

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
