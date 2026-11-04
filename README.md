# zagros-moon-pod

The **moon-pod** — the minimal, partner-custodial software bundle that lets a partner
organisation share data **bidirectionally and securely** with a goat data fabric, running on
**their own hardware, in their facility, under their custody and transparency**.

This repo is where the pod is developed with the partners who run it. The **content is
leak-free**: self-contained, with no goat-internal infrastructure, links, or credentials, so
everything here is safe to read, fork, and build against.

## In plain language — what this is and what it's for

A moon-pod is a **small, self-contained box of software you run** so you can securely exchange
data with the goat fabric — without joining the fabric wholesale and without a months-long
custom integration.

Think of it as a **sealed, two-way mailbox** both sides understand:

- **You run it on your own hardware, in your own facility, on your own power.** You have full
  custody and transparency — the code is Apache-2.0, yours to read, log, and fork. That's the sovereignty promise: nobody puts a black box on your
  network or pulls your data into someone else's cloud.
- **It speaks goat's language.** Even though it lives on your side, it is built to the fabric's
  security rules (identity, encryption, access control), so when data crosses, both sides trust
  the pipe.
- **Data flows both ways.** You publish under your own namespace; the fabric sends you data on
  your inbound prefix when the relationship is bilateral (`release/goat/**` is the production
  convention; on the zagros sandbox the inbound prefix falls back to your own slot until a
  bilateral grant exists).
- **Everything that crosses is observed** on your side — the v0 audit-sink subscribes to your
  namespace and exposes metrics (observe-only). A durable local log on your encrypted volume is
  the documented follow-up; until then, retention is a step you own (partner-contract req 4).

**What it's for:** a partner has data the fabric wants (sensor feeds, analytics, a data
product) — or needs data the fabric has. The moon-pod makes that **turnkey**: stand up the pod,
get granted a topic, declare it, and data flows securely in hours instead of a procurement
cycle.

The contract the pod meets at the boundary — the seven requirements, the sovereignty floor, and
how the goat side receives a pod's data — is documented self-contained in
[`docs/partner-contract.md`](docs/partner-contract.md).

## zagros is a sandbox

zagros is a sandbox goatnet for rapid onboarding of internal and external participants. The pod
here is calibrated against the zagros sandbox fabric:

- **Enrollment** mints everything in one act: your organisation's custodian runs
  `goat machine enroll` against a goat-seeded quota, which mints the slot, the mTLS identity,
  and a single-use NetBird setup-key (no silent control plane on the sandbox).
- **Zenoh identity** is the per-uuid **slot** that enrollment mints — your cert CN, your portal
  prefix, and your write namespace are all that slot anchor (a UUID, not a human-readable name).
- **Write namespace** is your slot (`<slot_id>/**`). A publish outside your slot is silently
  denied — declare and publish only within it.

None of the sandbox shape is the production shape; production deltas come from a production
profile + the signed bundle. See [`docs/zagros-vs-production.md`](docs/zagros-vs-production.md).

## What this bundle is (the "secure-pipe core")

The full moon-pod spec defines six pieces (network client, Zenoh router, translation engine,
local IdP, audit sink, operator web UI). This bundle ships the **minimal core that moves data
both ways securely and stays partner-custodial**, and defers the productization layers.

| Piece | Here | Deferred |
|---|---|---|
| Network client (mesh peer) | ✅ stock NetBird on the sandbox / `goat-clientd` host daemon for the production path — see [contract](docs/goat-client-v02-contract.md) | |
| Zenoh router | ✅ `eclipse/zenoh:1.9.0` (digest-pinned), mTLS, ACL-scoped | |
| Audit sink | ✅ `goat-audit-subscriber` in **observe-only** mode (subscribe + metrics) | durable NDJSON on LUKS / MinIO |
| Operator surface | ✅ `goat-cli` on host PATH (`doctor`, `pub`, `sub`, `health`) + `clients/` SDKs | |
| Translation engine | — | format adapters |
| Local IdP | — | Kanidm / Dex / Authelia / Zitadel overlays |
| Operator web UI | — | SPA |

Partner data egress today is **raw Zenoh via `goat-cli sub`** or one of the `clients/` SDKs; the
translator is a later productization layer.

## Shape

The one genuinely host-shaped thing (the WireGuard mesh client) runs on the **host** as a
service; the data-plane services run in a small **docker compose** bundle on host networking.

```
Host (systemd)
  mesh client (stock netbird on the sandbox, or goat-clientd for the production path)
  goat-cli                                  # operator surface (on PATH)

docker compose (network_mode: host)
  zenoh-router   eclipse/zenoh:1.9.0        data plane; mTLS; ACL <namespace>/**
  audit-sink     (goat-audit-subscriber)    observe-only (subscribe + metrics)

host systemd timer
  goat-doctor    goat-cli                    periodic `goat doctor --json` → status blob
```

The mesh client is on the host (not containerized) for kernel WireGuard, boot-persistence +
auto-reconnect, no privileged container, and no netns/restart coupling. Data-plane containers
use `network_mode: host` so they bind the pod's mesh IP directly.

## Layout

```
zagros-moon-pod/
├── README.md                       this file
├── LICENSE                         Apache-2.0
├── CONTRIBUTING.md                 how to contribute (+ the no-internal-leak rule)
├── moon_pod_setup.sh                all-in-one bring-up + stand-up + verify menu (see "Getting started")
├── docs/
│   ├── partner-contract.md         the seven requirements + Tier-2 ingress (self-contained)
│   ├── architecture.md             bundle shape + data flow
│   ├── router-config.md            the Zenoh router config: example, structure, create/manage/use
│   ├── pod-host-bringup.md         blank hardware -> pod-ready host (Pi 5 worked example)
│   ├── partner-run-guide.md        run the pod you were handed; enroll; declare; smoke-test
│   ├── goat-client-v02-contract.md mesh-daemon contract (production mesh path)
│   ├── zagros-vs-production.md       sandbox-vs-production deltas table
│   ├── transport-tls-vs-quic.md    TLS vs QUIC — know both, pick per endpoint
│   ├── quality-of-service.md       the QoS lanes + what a producer does to fit the model
│   ├── proof-out-tracks.md         candidate proof-out tracks (crawl -> walk -> run)
│   ├── workload-identity-spire-overlay.md  optional attested-workload-identity overlay (Phase 3+)
│   └── spire-federation-overlay.md the SPIRE/SPIFFE federation overlay in depth
├── .claude/skills/                 in-repo Claude Code skills: host bring-up, standup, verify
├── clients/                        connect SDKs (6 langs) + worked pub/sub/bridge examples
├── compose/                        zenoh-router + audit-sink (host networking) + .env.example + SPIRE overlay
├── profiles/
│   ├── zagros/                       concrete zagros sandbox profile
│   └── production/                 documented TODO seam
├── host/                           first-boot.sh, service units, zenoh-router template
├── spire/                          SPIRE server/agent + spiffe-helper confs for the overlay
├── examples/                       producer best-practice patterns (encoding, resilient sub, must-deliver, presence, reconcile)
└── tests/                          image-public guard + bidirectional smoke spec (not yet runnable)
```

## Getting started

- **Fastest path — the all-in-one setup script:** [`moon_pod_setup.sh`](moon_pod_setup.sh) merges
  bring-up + stand-up + verify into one interactive, re-runnable menu. On the pod host, from
  inside the repo clone:
  ```bash
  cd zagros-moon-pod
  sudo bash moon_pod_setup.sh
  ```
  Set `GOATNET`, `NETBIRD_MANAGEMENT_URL`, `PARTNER_NAMESPACE`, and `POD_ID` from your welcome
  package, in the `CONFIG` block near the top of the file or as env vars, before running; then
  pick Part 1, 2, or 3 from the menu — nothing runs until you confirm. Part 2 adds your goatnet's CA root to the
  pod's trust store — the `<prefix>-goat-cli-ca.pem` in your bundle tarball, or a root file you name in `CA_ROOT_PEM`
  (`goat` ships with no goatnet built in, so your bundle cannot be verified without it). It adds the root only
  after its fingerprint matches the one the goat side gave you: you confirm it at the prompt, or set
  `EXPECTED_CA_FINGERPRINT`. See the run guide's "Trust your goatnet's CA root". Pass `NETBIRD_SETUP_KEY` as an env var only; never write a real key into the
  file, since the file is what gets shared and committed. Prefer the docs below if you want the full explanation
  behind each step, or are troubleshooting a specific stage.
- **Starting from bare hardware:** [`docs/pod-host-bringup.md`](docs/pod-host-bringup.md) — blank
  machine to pod-ready host (Raspberry Pi 5 worked example), then the run guide.
- **Running a pod you were handed:** [`docs/partner-run-guide.md`](docs/partner-run-guide.md).
- **Writing a publisher / subscriber:** [`clients/README.md`](clients/README.md) — pick your
  language, copy the example, point it at your slot.
- **Producer best practices (encoding, catch-up, must-deliver, presence):**
  [`examples/README.md`](examples/README.md) — runnable patterns for resilient, self-describing data.
- **Transport — TLS vs QUIC (know both):** [`docs/transport-tls-vs-quic.md`](docs/transport-tls-vs-quic.md)
  + a runnable [`examples/transport_quic.py`](examples/transport_quic.py) — the same mTLS client over
  `quic/:7448` instead of `tls/:7447` (one line different); QUIC helps a lossy/mobile edge.
- **How Quality of Service protects what matters:** [`docs/quality-of-service.md`](docs/quality-of-service.md) —
  the lanes, the honest health gauge, and what you do as a producer to fit the model.
- **Understanding the router config:** [`docs/router-config.md`](docs/router-config.md) — a worked
  example of the rendered `config.json5`, what each section does, and how it's created/managed/used.
- **Understanding the boundary contract:** [`docs/partner-contract.md`](docs/partner-contract.md).
- **Attested workload identity (optional, experimental):**
  [`docs/workload-identity-spire-overlay.md`](docs/workload-identity-spire-overlay.md) for the
  why, [`docs/spire-federation-overlay.md`](docs/spire-federation-overlay.md) for the runnable
  overlay (not first-boot-wired; manual bring-up).
- **Choosing what to prove out (focus areas):** [`docs/proof-out-tracks.md`](docs/proof-out-tracks.md) —
  candidate tracks (sovereign sharing, QoS, time hygiene, releasability/graduated trust,
  operational use, identity/access), each with why it matters + crawl→walk→run work.
- **Co-developing this repo:** [`CONTRIBUTING.md`](CONTRIBUTING.md).

Working in [Claude Code](https://claude.com/claude-code)? The clone ships skills under
`.claude/skills/` that drive the bring-up, standup, and verification docs interactively.

Verification status (clean checkout, 2026-08-30): `tests/check-images-public.sh`
ran green - every pinned pod image is anonymously pullable. The pod bring-up
itself is unverified here; it needs the welcome package (enrollment quota,
namespace, setup key) and a pod host.

## Contributing

Keep it leak-free. This bundle is partner-custodial, so nothing goat-internal —
hostnames, credentials, RIDs, or infrastructure references — belongs in it; that
guarantee is what lets a partner read and build against the pod. The standup and
verification motions are captured as runnable skills under `.claude/skills/`
(`pod-standup`, `pod-verify`, `pod-host-bringup`); prefer them over
reimplementing the equivalent shell. `shellcheck -x` scripts you touch.


## License

`zagros-moon-pod` was written by U.S. Federal government employees. In the U.S. it is not subject to copyright and is in the public domain; in countries where copyright is recognized, it is released under the [Apache License 2.0](LICENSE). See [INTENT.md](INTENT.md).
