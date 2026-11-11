# zagros (sandbox validation reference) vs production goat-net — deltas

**Principle:** the pod hardcodes **nothing** stack-specific. Everything environment-specific comes
from the **signed join bundle** (the source of truth) + the active **profile**
(`profiles/<env>/`, a fallback for fields a bundle omits). The zagros profile is concrete (it's the
live sandbox); the production profile is a documented TODO seam — production specifics that aren't
settled are **not invented** here.

This is the central anti-over-specification guarantee: switching from zagros to production (or to
any other goatnet) is a different bundle + profile, never a code change to the pod.

| Axis | zagros (sandbox) | Production goat-net | How the pod stays agnostic |
|---|---|---|---|
| Zenoh topology | single router; peers dial it | per-site planes / multi-router + federation — **not fully settled** | router connect/listen endpoints come from the bundle (`router_endpoint`); pod does not assume a single router |
| Zenoh ACL subject identity | `cert_common_names` (CN-keyed); no default endpoint-name pin | likely URI-SAN or other — **TBD** | first-boot extracts the pod CN, verifies the connected fabric-router CN, and requires continuity with the last healthy run; a production axis change is a template change (reserved in the production profile TODO) |
| Zenoh key-expr namespace | per-uuid **slot** (`<slot_id>/**`); flat community-read | `release/<partner>/**` (egress) + `release/goat/**` (ingress) | the write namespace is `PARTNER_NAMESPACE` and the bilateral inbound is `INBOUND_NAMESPACE` — both profile-driven, neither hardcoded |
| Netbird / mesh mgmt | zagros sandbox mgmt + sandbox group taxonomy | **partner-net** (separate mgmt instance) + production group taxonomy | mgmt URL + setup key ride in the bundle (`InnerMeshSetup`); profile carries nothing site-internal |
| PKI roots | shared dev sandbox CA | per-site production CA | fabric-TLS trust is the bundle's `ca_roots`; the root that verifies the bundle itself is added per goatnet with `goat ca add`. Neither is compiled in |
| Audit retention | sandbox tier | prod tier (e.g. 7y cold) | v0 runs the audit-sink observe-only — no durable retention yet, so no knob; the production profile TODO reserves `AUDIT_RETENTION_DAYS` for when persistence lands |
| Boundary enforcement (receiver) | pod ↔ sandbox router directly (no gateway yet) | **ingress gateway** per ADR 1020: a moon-pod is a Tier-2 (non-goat↔goat) peer, so its egress is received by a goat-operated gateway that authenticates the verified peering identity, admits origin-scoped, and records provenance — never direct federation into a core router. **goat-side, not built yet** | pod connects to whatever `router_endpoint` the bundle gives; the gateway is a goat-side hop the pod is transparent to. The pod publishes its own namespace regardless; the *admitted* shape is the receiver's concern |
| Mesh client mode | `netbird-only` (no silent control plane on the sandbox) | likely `netbird-only` (cleaner partner on-ramp) — **production-profile TODO** | mode is profile-driven (`GOAT_CLIENT_MODE`) |

## How the bundle carries each per-environment value

The pod reads these straight from the signed bundle — it never derives them from a hardcoded
default:

- **Mesh enrollment** — `InnerMeshSetup.ManagementURL` + `.SetupKey` (the mgmt instance to join).
- **Fabric router endpoint** — `goat_cli_extras.router_endpoint` (written into `profile.toml` by
  `goat profile init`; first-boot reads it from there, profile var is fallback only).
- **Operator portal** — `goat_cli_extras.portal_endpoint` + `portal_token`.
- **mTLS identity** — `goat_cli_extras.mtls_cert` / `mtls_key` (the pod's Zenoh identity on the
  fabric — its slot CN on zagros).
- **CA roots** — `goat_cli_extras.ca_roots` (the fabric-TLS trust the pod's router and clients
  use; never compiled in).

One trust input deliberately does **not** ride in the bundle: the CA root that verifies the
bundle's own signature. A bundle cannot vouch for itself, and `goat` compiles in no goatnet, so
the operator adds that root once per goatnet (`goat ca add`, into the pod's profile dir) — see
[`partner-run-guide.md`](partner-run-guide.md#trust-your-goatnets-ca-root). It stays
stack-agnostic the same way: a production CA is another root file, not another build.

For a TLS router endpoint, first-boot derives the upstream router CN from a live, CA-verified mTLS
handshake. The public core-router policy declares one name at
[`cbf2cb7f`](https://github.com/USAREUR-AF/goatcore/blob/cbf2cb7f5147c5b7879f4d12420845b2e4d3a067/ops/ansible/roles/goat-zenoh/templates/config.json5.j2#L1624-L1634).
That does not prove every endpoint role a POD bundle may name shares the core-router identity, so
the zagros profile does not ship a default pin. It accepts a CA-verified name on first use, records
it only after router health, and refuses an unconfirmed later change. Any configured
`ZENOH_FABRIC_CERT_CN` must match TLS discovery. A
non-TLS endpoint must provide that value from the goat-side operator through the trusted
onboarding channel. The ACL never widens fabric subscription interest to every trusted peer.

The current ACL supports one router CN per rendered pod config. An endpoint pool whose routers
present different CNs is not supported: whichever CN was discovered would cause default-deny to
silently block every other router. A production multi-router design must give the pool one shared
authenticated identity or extend the profile/template to bind every approved router identity.

The only values that legitimately live in the profile are the ones the bundle does *not* carry:
the bilateral inbound prefix (`INBOUND_NAMESPACE`), audit retention, the mesh mode, and the
ACL subject axis (plus `ZENOH_FABRIC_CERT_CN` when non-TLS requires it or TLS is pinned) — and even
those are plain config, swappable per environment.

The router's own Zenoh ID is not an environment input. It is deterministically derived from the
POD certificate CN with a `moon-pod-router` suffix, so restarts preserve topology identity without
colliding with a slot-pinned publisher session. A failed changed render rolls back only when the
saved POD and fabric certificate identities still match; identity changes fail stopped instead.

## Goat-side dependencies the pod is built to plug into (not pod code)

- **partner-net** — a separate mesh mgmt instance for partners (production path). The pod enrolls
  against whatever mgmt the bundle's `InnerMeshSetup` names; on the sandbox that's the zagros mgmt.
- **ingress gateway** (ADR 1020) — the goat-side receiver for Tier-2 peered ingress, including
  moon-pods. It authenticates the verified peering identity, admits data origin-scoped, and
  records provenance. **goat-side, not built yet**; the sandbox validates pod ↔ router directly.
- **release-bridge / schema-enforcer / conditioning** — the broader boundary-conditioning layer;
  layers on top of the ingress gateway. Not built yet.

All recorded here so the pod's data path is built to accommodate them without rework.
