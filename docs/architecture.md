# moon-pod — v0 architecture

The v0 "secure-pipe core": the smallest bundle that moves data **both directions** securely
and stays **partner-custodial**. See [`../README.md`](../README.md) for scope and [`partner-contract.md`](partner-contract.md) for the
boundary contract.

## Component placement: host vs compose

The single genuinely host-shaped component (the WireGuard mesh client) runs on the **host**;
the data-plane services run in a small **docker compose** bundle on host networking.

```
┌─ Partner host (their hardware, their facility, LUKS-encrypted data volume) ──────────┐
│                                                                                      │
│  systemd:                                                                            │
│    goat-clientd --headless --mode ${GOAT_CLIENT_MODE}   ← WireGuard mesh peer        │
│    (kernel WireGuard; boot-persistent; auto-reconnect)                               │
│                                                                                      │
│  on PATH:                                                                            │
│    goat-cli            ← operator surface: doctor, topic ls, pub, sub, health        │
│    goat-doctor.timer   ← host systemd timer: goat doctor --json → status blob        │
│                          (goat-cli is no-daemon, ADR 1019; no container image)       │
│                                                                                      │
│  docker compose (network_mode: host — binds the pod's mesh IP directly):             │
│    ┌─────────────┐   ┌────────────┐                                                  │
│    │ zenoh-router│──▶│ audit-sink │   (published images, no local build)            │
│    └─────┬───────┘   └─────┬──────┘                                                  │
│          │ mTLS, ACL       │ subscribe <ns>/** over mTLS (observe-only in v0;        │
│          │ <ns>/**         │ durable NDJSON/MinIO is a v0.x follow-up)               │
│          ▼                 ▼                                                          │
│   (over the mesh maintained by goat-clientd)                                          │
└──────────────────────────────────────────────────────────────────────────────────────┘
            │ WireGuard mesh
            ▼
   goat fabric (the sandbox router directly;
   later: partner-net + release-bridge boundary)
```

### Why the mesh client is on the host, not in a container

- Kernel WireGuard via `wg-quick` (container path is usually forced to slower userspace `wireguard-go`).
- systemd gives boot-persistence + auto-reconnect-on-network-change for free.
- No privileged container (`NET_ADMIN` + `/dev/net/tun`); no isolation thrown away.
- No netns/restart coupling (a sidecar's restart would drop every dependent container's network).
- Matches goat-client's own design (systemd/launchd/Windows-Service daemon) and is the shape
  the goat-client design doc already names for moon-pods.

Data-plane containers use `network_mode: host` so they bind the pod's mesh IP directly — the
same clean routing a netns sidecar would give, but coupled to the stable host.

## Startup ordering

1. Host: LUKS unlock → Docker up → the mesh client (stock NetBird on the sandbox, `goat-clientd`
   on the production path) brings the mesh up.
2. `first-boot.sh` (once, six steps in this order): [1] verify bundle + extract certs
   (`goat profile init`) → [2] lay the Zenoh mTLS material → [3] render the router config →
   [4] `goat-clientd` import + mesh service (skipped on the sandbox) → [5] write `compose/.env` +
   `docker compose up -d` → [6] install the `goat-doctor` timer.
3. compose: `zenoh-router` (dials the fabric over the mesh) → `audit-sink` (subscribes once the
   router is local). `goat-doctor` runs as a HOST systemd timer (not compose) since goat-cli is
   no-daemon and has no container image.

The router config rendered in step 2 — a worked example, a section-by-section walkthrough, and the
create/manage/use lifecycle — is documented in [`router-config.md`](router-config.md).

### Service images (corrected from the v0 scaffold)

Both compose services use **already-published images** — no local Dockerfile/build context:
- `zenoh-router`: upstream `eclipse/zenoh:1.9.0` (digest-pinned, ADR 0858).
- `audit-sink`: the published `ghcr.io/usareur-af/goat-audit-subscriber` image (the standalone Rust
  Zenoh client), run in **observe-only** mode in v0 (subscribe + Prometheus metrics, no S3
  endpoint → no durable write). Durable local audit (NDJSON on the LUKS volume, or a co-located
  MinIO) is a documented v0.x follow-up.

The earlier `../audit` and `../doctor` build-context stubs were an oversight (no Dockerfiles →
`docker compose up` would fail); removed in favor of the published image + the host doctor timer.

## Data flow (bidirectional)

- **Outbound** (partner → fabric): partner publishes under `<PARTNER_NAMESPACE>/**` — on the
  zagros sandbox that is the per-uuid slot minted at enrollment; `release/<partner>/**` is the
  production shape. The pod's Zenoh router carries it over the mesh **to the goat-side ingress
  gateway** (see "Receiver side" below), not directly into a core router. Observed locally by
  `audit-sink`.
- **Inbound** (fabric → partner): the partner subscribes to the `<INBOUND_NAMESPACE>` prefix
  (`release/goat/**` is the production convention; on the sandbox it falls back to the pod's own
  slot until a bilateral grant exists); v0 consumption is **raw Zenoh via `goat-cli sub`**
  (translator is post-v0).

## Receiver side (goat-side — how we ingest what the pod sends)

A moon-pod is a **Tier-2 peer** under the federated-peering trust model
(ADR 1020):
it is partner-custodial and may be rooted in a different CA, so it is **not** the canonical
goat↔goat (Tier-1) federation. That has a concrete consequence for the data path:

- The pod's router does **not** federate directly into a goat core router. It connects to a
  **goat-operated ingress gateway** that holds goat's own identity.
- The gateway authenticates the pod's *verified* peering identity (its cert), assigns a stable
  `<peering-id>`, and admits the pod's data **origin-scoped** — the gateway is the only writer
  the core router's ACL sees, so a pod can never squat another namespace or impersonate the
  fabric. The required ACL change (ingress/egress `put` split, default-deny on un-scoped
  ingress) is in ADR 1020.
- Every admitted sample carries provenance (verified peering identity, original key,
  timestamps) into the goat audit trail — independent of, and complementary to, the pod's own
  local audit-sink.

**Open reconciliation (a decision for the receiver build, not invented here):** an onboarded
moon-pod publishing *its own first-party* data under `release/<partner>/**` is authorized and
origin-scoped, unlike the un-onboarded **relay** case ADR 1020's quarantine namespace
(`<entity>/<peering-id>/<original-key>`) was written for. The receiver must decide whether the
moon-pod's first-party `release/<partner>/**` is admitted **directly** (origin-scoped, since it
*is* onboarded end-to-end) while only *relayed third-party* traffic is quarantine-rewritten —
or whether all pod ingress flows through the same rewrite. This is tracked as receiver-side
work; the pod is built to publish `release/<partner>/**` regardless, and the
admitted shape is the receiver's concern.

## Trust + custody

- Fabric-TLS CA trust comes from the **bundle** (`ca_roots`), never compiled in — a partner pod
  may be rooted in a production CA, not the dev sandbox CA. (`--trust-roots` is `goat-clientd`'s
  own flag, not `goat`'s.)
- The bundle's **own signature** is verified by `goat` against a CA root the operator added to
  the pod's trust store (`goat ca add`, under the pod's profile dir on the state volume). That
  root is never compiled in either, and never taken from the bundle it verifies.
- The v0 audit-sink is **observe-only** (subscribe + metrics); durable append-only NDJSON on the
  partner's **LUKS-encrypted** volume is the documented v0.x follow-up, and retention until then
  is the partner's own contractual step (req 4). Goat does not aggregate partner audit either
  way. (MinIO + Object-Lock is a later hardening upgrade.)
- The pod is one mesh peer; the partner can `systemctl`/`journalctl`/`docker logs` everything.

### Workload identity (optional overlay, Phase 3+)

The pod's containers can additionally carry **attested workload identity** via a SPIRE/SPIFFE overlay — a **first-class optional overlay**, layered like the local-IdP choice. It is **not** required: the base pod meets the partner-receiver contract without it, and the easy deploy path stays an honest default. A partner who wants (or is required to have) cryptographically-attested workload identity reaches for the overlay; offering the simple default does not withhold the capability. SPIRE runs inside the pod (sovereignty-clean — goat hosts no partner SVIDs); federation exchanges only public trust bundles so the goat-side ingress gateway can verify the pod router's identity. Design + rationale: [`workload-identity-spire-overlay.md`](workload-identity-spire-overlay.md); the runnable overlay itself (compose file, SPIRE configs, federation model, manual bring-up — experimental, not first-boot-wired): [`spire-federation-overlay.md`](spire-federation-overlay.md).

## Profiles (environment shape)

`profiles/<env>/` carries everything that differs between deployments (endpoints, ACL subject
axis, namespace, retention, goat-client mode). `zagros/` is concrete; `production/` is a
documented TODO seam (ADR 0844 unsettled). The compose stack + scripts are identical across
environments; only the profile + the signed bundle change. See
[`zagros-vs-production.md`](zagros-vs-production.md).

## Provenance + self-containment

This is the moon-pod, derived from the goat moon-pod reference implementation. Design
principles that keep it cleanly standalone:

- **Self-contained:** no runtime reach into goat-internal paths. Reused upstream artifacts (Zenoh
  image, audit-subscriber, goat-cli, the mesh daemon) are consumed as **released binaries /
  pinned images**, not source-relative imports.
- **Apache-2.0** licensed.
- **Stack-agnostic pod, env-specific bundle.** The compose stack, host scripts, and config
  templates hardcode **nothing** stack-specific (no zagros / production values). Every
  environment value — router endpoint, namespaces, ACL subject axis, CA roots, mesh enrollment —
  arrives at first-boot from the **signed join bundle** plus the active **profile**
  (`profiles/<env>/`). Switching stacks is a different bundle + profile, never a code change.

The boundary contract (the seven requirements + Tier-2 ingress) is documented self-contained in
[`partner-contract.md`](partner-contract.md).
