# The pod's Zenoh router config

What the pod's Zenoh router configuration looks like, why it is as small as it is, and how it
gets created, managed, and used. If you just want to run a pod you were handed, you never touch
this file — it is generated for you. This doc is for understanding what got generated and why.

## TL;DR

- The pod router config is **JSON5** (JSON with comments + trailing commas), about 140 lines.
- **You do not hand-write it.** A committed *template* (`host/zenoh-router.json5.tmpl`) is
  rendered into the final `config.json5` by `host/first-boot.sh`, filling placeholders from the
  **signed join bundle** (source of truth) plus the active **profile** (`profiles/<env>/`).
- It is deliberately **simple**: the pod is your *single-tenant* box. It only needs to dial the
  fabric, listen for your local clients, and default-deny everything outside your namespace. The
  heavy multi-tenant access control lives on the **goat side** (the ingress gateway, ADR 1020),
  not here.
- Fabric audit and catalog services subscribe across slots. Their router may declare that broad
  interest to the pod, but only the authenticated fabric-router certificate gets that grant;
  data operations remain restricted to the pod and inbound namespaces.
- To change it, change a **profile var or the bundle** and re-run first-boot. It atomically
  re-renders the file and restarts a running router when the content changed. A rejected render
  rolls back to the last healthy configuration when the certificate identities are unchanged.
  Never edit the rendered file by hand.

## The fabric endpoint

If all you want is the address the pod dials to reach the zagros fabric: it comes from
your **bundle** (`router_endpoint`, echoed in the bundle's NOTES.md), and has the shape:

```
tls/<goatnet-router>:7447
```

Read it as three parts: `tls/` is the Zenoh transport (mTLS-encrypted TCP), the host is the
goat-side router reachable over the mesh, and `7447` is Zenoh's standard router port. Your pod
**dials out** to this; it is never dialled into.

You normally never type this value. Your **signed join bundle** carries it as
`goat_cli_extras.router_endpoint`, and `host/first-boot.sh` reads it from there — the bundle is the
source of truth. The same literal also lives in [`profiles/zagros/profile.env`](../profiles/zagros/profile.env)
as `ZENOH_FABRIC_ENDPOINT`, but only as a **fallback** for hand-driven validation when a bundle is
absent; the bundle's value wins whenever present. Pointed at a different stack (production), the
endpoint is whatever that stack's bundle carries — switching is a different bundle, never an edit
here.

A few connection facts that go with the endpoint:

| Fact | Value | Why |
|---|---|---|
| Transport | mTLS over TCP (`tls/`) | every peer presents a cert rooted in the bundle's CA |
| Port | `7447` | Zenoh's standard router port (also the pod's local listen port) |
| Cert name check | `verify_name_on_connect: false` | the goat router cert's SAN binds a mesh IP, not this DNS name |
| Reachability | over the netbird mesh | the host resolves and routes only once your mesh client is up |

If the pod cannot reach it, the mesh is the first thing to check (`goat doctor`), not the config —
the endpoint above is correct by construction once your bundle is loaded.

## A complete worked example

Below is a representative *rendered* `config.json5` for a zagros sandbox pod — i.e. the template
after `first-boot.sh` has substituted the placeholders. The example slot anchor
`0123abcd4567ef890123abcd4567ef89` stands in for the per-uuid slot minted at enrollment;
your real one comes from your bundle.

```json5
{
  id: "<stable-id-derived-from-the-pod-certificate-cn>",
  mode: "router",

  // (1) Local listen — pod-side clients (goat-cli pub/sub, the audit-sink) connect here over mTLS.
  listen: {
    endpoints: ["tls/0.0.0.0:7447"],
  },

  // (2) Dial OUT to the goat-side receiver over the mesh. The pod is a Tier-2 peer; the goat side
  //     decides the admitted shape. Endpoint comes from the bundle (router_endpoint).
  connect: {
    endpoints: ["tls/<goatnet-router-from-bundle>:7447"],
  },

  // (3) mTLS identity for BOTH directions — same leaf cert as listener and as connector.
  transport: {
    link: {
      tls: {
        listen_certificate:  "/etc/zenoh/tls/pod-cert.pem",
        listen_private_key:  "/etc/zenoh/tls/pod-key.pem",
        connect_certificate: "/etc/zenoh/tls/pod-cert.pem",
        connect_private_key: "/etc/zenoh/tls/pod-key.pem",
        root_ca_certificate: "/etc/zenoh/tls/ca-roots.pem",
        enable_mtls: true,
        verify_name_on_connect: false,
      },
    },
  },

  // (4) Load the upstream plugins shipped in the stock image (REST, storage_manager).
  plugins_loading: {
    enabled: true,
    search_dirs: ["/", "/opt/zenoh/plugins"],
  },

  // (5) Pod-side ACL — default-deny, mTLS-gated. This is YOUR boundary on YOUR box; the
  //     load-bearing fabric enforcement is goat-side. We default-deny here as good hygiene.
  access_control: {
    enabled: true,
    default_permission: "deny",
    rules: [
      {
        // Your own first-party data: publish + subscribe within your slot, both flows.
        id: "pod-firstparty",
        messages: ["put", "delete", "declare_subscriber", "query", "declare_queryable", "reply", "liveliness_token", "declare_liveliness_subscriber", "liveliness_query"],
        flows: ["egress", "ingress"],
        permission: "allow",
        key_exprs: ["0123abcd4567ef890123abcd4567ef89/**"],
      },
      {
        // Inbound bilateral data the fabric publishes TO you. Rendered from ${INBOUND_NAMESPACE};
        // on the zagros sandbox that falls back to your own slot (as here) until a bilateral grant
        // exists — release/goat/** is the production convention.
        id: "pod-inbound-local-interest",
        messages: ["declare_subscriber", "query", "declare_liveliness_subscriber", "liveliness_query"],
        flows: ["ingress"],
        permission: "allow",
        key_exprs: ["0123abcd4567ef890123abcd4567ef89/**"],
      },
      {
        id: "pod-inbound-local-delivery",
        messages: ["put", "declare_queryable", "reply", "liveliness_token"],
        flows: ["egress"],
        permission: "allow",
        key_exprs: ["0123abcd4567ef890123abcd4567ef89/**"],
      },
      {
        id: "pod-inbound-fabric-data",
        messages: ["put", "declare_queryable", "reply", "liveliness_token"],
        flows: ["ingress"],
        permission: "allow",
        key_exprs: ["0123abcd4567ef890123abcd4567ef89/**"],
      },
      {
        id: "pod-inbound-fabric-interest",
        messages: ["declare_subscriber", "query", "declare_liveliness_subscriber", "liveliness_query"],
        flows: ["egress"],
        permission: "allow",
        key_exprs: ["0123abcd4567ef890123abcd4567ef89/**"],
      },
      {
        // The fabric router may advertise cross-slot audit/catalog interest to this router.
        // This grants no put, delete, query, reply, or liveliness operation.
        id: "fabric-interest",
        messages: ["declare_subscriber"],
        flows: ["ingress"],
        permission: "allow",
        key_exprs: ["**"],
      },
    ],
    subjects: [
      {
        id: "pod-peer",
        cert_common_names: ["0123abcd4567ef890123abcd4567ef89"],
        link_protocols: ["tls", "quic"],
      },
      {
        id: "fabric-peer",
        cert_common_names: ["<verified-fabric-router-cn>"],
        link_protocols: ["tls", "quic"],
      },
    ],
    policies: [
      { rules: ["pod-firstparty"], subjects: ["pod-peer", "fabric-peer"] },
      { rules: ["pod-inbound-local-interest", "pod-inbound-local-delivery"], subjects: ["pod-peer"] },
      { rules: ["pod-inbound-fabric-data", "pod-inbound-fabric-interest"], subjects: ["fabric-peer"] },
      { rules: ["fabric-interest"], subjects: ["fabric-peer"] },
    ],
  },
}
```

That is the whole file. There is no rocksdb storage block, no per-tenant rule fan-out, no
adminspace — see [Complexity](#why-it-is-this-small-complexity) for why.

## Section-by-section

| # | Block | What it does |
|---|---|---|
| 1 | `listen` | The local mTLS endpoint your own clients connect to (`goat-cli`, the audit-sink). Binds `0.0.0.0` *inside the container*; `network_mode: host` in compose puts it on the pod's mesh IP. |
| 2 | `connect` | The goat-side endpoint the pod **dials out** to over the mesh. The pod initiates; it is not dialled into. |
| 3 | `transport.link.tls` | The pod's single mTLS leaf identity, used as both listener and connector. `enable_mtls: true` means every peer must present a cert rooted in `root_ca_certificate`. `verify_name_on_connect: false` because the goat router cert's SAN binds a mesh IP, not the DNS name dialled. |
| 4 | `plugins_loading` | Tells zenohd where to find the plugins bundled in the stock `eclipse/zenoh` image. `"/"` is where upstream ships REST + storage_manager; `/opt/zenoh/plugins` is where an optional rocksdb backend `.so` would go (not used in v0). |
| 5 | `access_control` | Default-deny floor. A **rule** says *what* (messages + key expressions + flow direction); a **subject** says *who* (the pod or fabric certificate CN); a **policy** binds rules to subjects. |

### How the ACL three-part shape reads

Zenoh's ACL is three lists that compose:

- **rules** — named permission grants. `pod-firstparty` allows pub/sub on `<your-slot>/**`. The
  four `pod-inbound-*` rules let local clients declare interest and receive data while only the
  fabric peer can originate data and responses in `${INBOUND_NAMESPACE}` (your own slot on the
  sandbox; `release/goat/**` once bilateral in production).
- **subjects** — named identity matchers. `pod-peer` matches the pod leaf's certificate CN;
  `fabric-peer` matches the independently verified CN presented by the upstream router. The CA
  still authenticates both certificates, while the CN keeps fabric-wide interest off local client
  sessions.
- **policies** — bindings: "these subjects get these rules." Anything not granted falls through to
  `default_permission: "deny"`.

The direction split matters: `flows: ["ingress"]` is *into* the router (a publish or declaration),
`flows: ["egress"]` is *out of* the router (delivery to a subscriber). The pod grants both within
your namespace so you can publish and read your own data locally.

### Security review: why fabric-wide interest is safe

Zenoh forwards a publish only toward a matching declared subscriber. Fabric audit and catalog
services use cross-slot expressions such as `*/**`; rejecting those declarations makes a valid
slot publish stay on the pod. The `fabric-interest` rule therefore accepts `declare_subscriber`
on `**`, ingress only.

That allowance is not attached to every mTLS peer. `first-boot.sh` verifies the upstream TLS
certificate against the bundle CA and records its CN in the rendered `fabric-peer` subject. It
also records that name only after the router is healthy. A later unpinned discovery must match the
record. If it differs, rendering stops until the goat-side operator confirms the new name through
the trusted onboarding channel and the partner supplies it as `ZENOH_FABRIC_CERT_CN`. An explicit
pin must still match live TLS discovery, so it cannot conceal a different endpoint certificate.
On the first unpinned run, first-boot says that the discovery was accepted on first use and how to
pin it. The
pod leaf CN separately identifies local clients, and rendering refuses identical CNs because they
would collapse the two subjects. The router denies a local `**` declaration, so it neither
receives data through the router nor propagates broad interest upstream. Only the authenticated
`fabric-peer` may declare it. A narrower expression would not cover all
authorized fabric consumers: `*/**` is the current audit/catalog shape and future permitted
cross-slot expressions must also be representable. Widening the declaration key changes routing
interest only; `put`, `delete`, `query`, `reply`, and queryable permissions remain limited to
`${PARTNER_NAMESPACE}/**` and `${INBOUND_NAMESPACE}/**`. Fabric liveliness subscribers and
liveliness queries on `*/**` and `**` already see a POD-local token because those expressions
intersect the fabric peer's existing `${PARTNER_NAMESPACE}/**` liveliness grant; no broad rule is
needed. A slot-scoped expression sees the same token, while a POD-local client or a same-CA client
with another CN gets no `**` liveliness view. Plain `query` on `**` remains denied.

Every local client presents the POD certificate and private key. The fabric therefore sees one
identity for the whole POD, and anything holding that key can do everything the POD can do. Keep
the key readable only by local services that need it, and never copy it to another host. The
goat-side receiver remains the load-bearing authorization boundary.

The inbound namespace is directional when it differs from the partner namespace: a local client
can subscribe or query there and receive fabric data, but cannot publish there. This prevents the
new broad fabric-interest declaration from carrying a pod-originated write into the namespace the
fabric uses to send data to the pod. This template also adds `declare_queryable` to the inbound
rules: a local query can reach a fabric queryable, and its reply can return to the local client.
The namespace and direction limits apply to both operations. When both namespaces are the pod
slot, as on the sandbox, `pod-firstparty` intentionally still permits normal slot publishing.

## Why it is this small (complexity)

The pod router is about 140 lines and intentionally so. Three reasons:

1. **Single-tenant.** It is *your* box. The ACL distinguishes only the pod identity from its one
   authenticated upstream router — not a per-tenant fan-out.
2. **Enforcement is goat-side.** A moon-pod is a **Tier-2 peer** (ADR 1020): it does not federate
   directly into a goat core router. It dials a goat-operated **ingress gateway** that
   authenticates the pod's cert, admits its data origin-scoped, and records provenance. So the
   pod's own ACL is hygiene, not the load-bearing control — the fabric does not trust the pod to
   police itself.
3. **No storage in v0.** The pod does not persist fabric data to rocksdb; basic pub/sub needs no
   storage backend. (Durable local audit is the audit-sink's job, and durable replay is a
   documented v0.x follow-up.) That removes the entire `plugins.storage_manager` block — volumes,
   per-prefix storages, retention/TTL, garbage-collection — that a persisting router carries.

The router also has a deterministic Zenoh ID. First-boot hashes
`<pod-certificate-CN>|moon-pod-router`, keeps the first 32 lowercase hexadecimal characters, and
removes leading zeros before rendering. The separate suffix prevents a collision with local
publisher sessions that use the slot anchor as their ID. The value is stable across router
restarts and is not an authorization identity; the certificate subjects above remain the ACL
axis. This follows the core router's public stable-ID and leading-zero rule
([source](https://github.com/USAREUR-AF/goatcore/blob/cbf2cb7f5147c5b7879f4d12420845b2e4d3a067/ops/ansible/roles/goat-zenoh/defaults/main.yml#L140-L158))
while staying distinct from the CLI's slot-pinned publisher session
([source](https://github.com/USAREUR-AF/goatcore/blob/cbf2cb7f5147c5b7879f4d12420845b2e4d3a067/crates/goat-cli/src/cmd/pubsub.rs#L1207-L1227)).

For contrast: a goat-side **core** router config is much larger because it carries all of the
above — many tenants, many per-namespace rules, rocksdb storages with retention, an adminspace
for live onboarding, a pinned router ZID, and HLC timestamping. The pod deliberately carries none
of that weight. You are running the edge, not the core.

## Lifecycle: create, manage, use

### Create — how the file comes to exist

```
host/zenoh-router.json5.tmpl   ──envsubst──▶   ${POD_STATE_DIR}/zenoh/config.json5
   (committed template,            (in            (rendered, gitignored, on the
    placeholders)              first-boot.sh)       LUKS volume)
```

`first-boot.sh` step [4/6] runs `envsubst` over the template, substituting these placeholders:

| Placeholder | Comes from | Notes |
|---|---|---|
| `${ZENOH_LISTEN_PORT}` | profile (default `7447`) | local listen port |
| `${POD_ROUTER_ZID}` | derived from the pod certificate CN | deterministic router ID; validated as 1-32 lowercase hex characters with no leading zero |
| `${ZENOH_FABRIC_ENDPOINT}` | **bundle** `router_endpoint` (profile is fallback only) | the goat-side endpoint dialled |
| `${PARTNER_NAMESPACE}` | profile (your slot anchor) | your write/read prefix |
| `${INBOUND_NAMESPACE}` | profile (defaults to your namespace when unset) | bilateral inbound prefix |
| `${POD_CERT_CN}` | pod leaf extracted from the bundle | identifies local pod clients |
| `${FABRIC_ROUTER_CERT_CN}` | CA-verified handshake to the TLS bundle endpoint, or a required non-TLS pin | identifies the upstream router; a TLS `ZENOH_FABRIC_CERT_CN` is an optional pin and must match discovery |
| `${POD_CERT_PEM}` / `${POD_KEY_PEM}` / `${CA_ROOTS_PEM}` | **bundle** (extracted by `goat profile init`) | in-container cert paths |

The cert/key/CA values are extracted from the signed bundle by `goat profile init` and laid down
under the pod's LUKS-encrypted state dir — they are never compiled in and never committed. The
**bundle is the source of truth**; the profile only supplies what the bundle does not carry. This
is why the same scaffold runs against zagros today and production later with no code change — a
different bundle + profile is the only difference.

### Manage — how to change it

**Never edit the rendered `config.json5` by hand** — first-boot restores it from its inputs on the
next run. Change the input instead:

| You want to change | Change this | Then |
|---|---|---|
| Your write namespace / slot | `PARTNER_NAMESPACE` in `profiles/<env>/profile.env` | re-run first-boot |
| The fabric endpoint you dial | the **bundle** (preferred), or `ZENOH_FABRIC_ENDPOINT` fallback | re-run first-boot |
| The expected fabric certificate name | `ZENOH_FABRIC_CERT_CN` in the profile, after confirmation through the trusted onboarding channel | re-run first-boot |
| Add a bilateral inbound channel | uncomment/set `INBOUND_NAMESPACE` in the profile | re-run first-boot |
| Local listen port | `ZENOH_LISTEN_PORT` in the profile | re-run first-boot |
| The ACL shape itself (rare) | `host/zenoh-router.json5.tmpl` (the template) | open a PR — this is a scaffold change |

Re-running `first-boot.sh <profile> <bundle>` is idempotent: it renders to a temporary file,
replaces `config.json5` only when its content changed, applies the compose stack, and restarts an
already-running router after a changed render or when it was not healthy. Before replacing a
previously applied file, it saves one mode-`0600` last-known-good copy. It then waits up to about
two minutes for the router to become healthy and records the rendered config and fabric identity
as applied only after that succeeds. A profile change is a re-render; a template
change is a code change that goes through a PR (per `CONTRIBUTING.md`), because it affects every
pod.

For the default TLS fabric endpoint, re-rendering performs a mutually authenticated handshake to
discover the router CN. The handshake must validate against the bundle's CA or rendering stops.
Every core router uses the public name declared by the router certificate policy at
[`cbf2cb7f`](https://github.com/USAREUR-AF/goatcore/blob/cbf2cb7f5147c5b7879f4d12420845b2e4d3a067/ops/ansible/roles/goat-zenoh/templates/config.json5.j2#L1624-L1634),
but a POD bundle may name another endpoint role and no public source proves that every endpoint
the zagros profile can reach shares that identity. The profile therefore leaves the pin commented
instead of baking in a value observed from one POD. Its first TLS run accepts the CA-verified name
on first use; later discovery must match the healthy recorded name. A configured TLS
`ZENOH_FABRIC_CERT_CN` must equal the discovered CN. For a QUIC endpoint, obtain
the expected router CN from the goat-side operator through the trusted onboarding channel and put
it in `ZENOH_FABRIC_CERT_CN`; the script will not fall back to trusting every peer.
The ACL subjects match certificate CNs on both TLS and QUIC links. The forwarding regression test
exercises TLS; it does not currently exercise a QUIC link.

### Use — how the running pod consumes it

`compose/docker-compose.yml` mounts the rendered file **read-only** into the router container and
points zenohd at it:

```yaml
volumes:
  - ${POD_STATE_DIR}/zenoh/config.json5:/etc/zenoh/config.json5:ro
command: ["-c", "/etc/zenoh/config.json5"]
```

zenohd reads it once at startup; `docker compose up -d` alone does not reload a changed bind-mounted
file. Apply a change by re-running first-boot. It restarts the router when the rendered content
changed and otherwise leaves it running. Compare the render and process start in UTC:

```sh
sudo date -u -r /var/lib/goat-moon/zenoh/config.json5 '+rendered %Y-%m-%dT%H:%M:%SZ'
sudo date -u -d "$(sudo docker inspect -f '{{.State.StartedAt}}' goat-moon-zenoh-router)" '+router started %Y-%m-%dT%H:%M:%SZ'
```

After a changed render, the router start time is later. If first-boot prints
`router config unchanged`, it does not restart the router; an older render time is then the
expected passing state.

If a changed render fails and the saved POD and fabric certificate names still match the current
inputs, first-boot restores the last-known-good file, restarts once, waits through the same bounded
health check, and exits non-zero while reporting that the previous configuration is running. The
applied hash always names that restored running file. Correct the input or template and re-run.
Rollback starts only when the router exits or fails its local port health probe; a configuration
that loads with a wrong access rule counts as healthy and is not rolled back, so use the
running-router delivery check in the partner run guide to catch that case.
If the saved identities differ, first-boot does not restore: doing so could re-admit a certificate
the operator just replaced. It leaves the router stopped and asks the goat-side operator to confirm
the identities. It also refuses restoration when the saved identities are missing or cannot be
verified. A first installation has no prior file to restore and therefore keeps the failed state
and diagnostics.

## Validate + troubleshoot

- **Is the JSON5 well-formed?** `sudo docker compose logs zenoh-router` — a parse error fails the
  container at startup with a line/column. JSON5 allows comments and trailing commas, so a stray
  comma is not an error, but a missing brace is.
- **Did the substitution work?** Open the rendered `${POD_STATE_DIR}/zenoh/config.json5` and
  confirm no `${...}` placeholders remain and the slot anchor is your real one (not
  `CHANGE-ME-...`). An unset profile var leaves the literal placeholder behind.
- **A publish "succeeds" but nothing arrives.** Zenoh ACL denial is **silent** — there is no
  error to the publisher. Check that your key starts with `${PARTNER_NAMESPACE}/` exactly; a
  publish outside your namespace is dropped by the goat-side ACL with no signal. Confirm reach and
  identity with `goat doctor`, then use the running-router delivery check in the partner run guide
  with your normal application or a client under `clients/`.
- **Rendering cannot verify the fabric router CN.** Confirm the mesh is connected and the bundle's
  router endpoint is reachable, then re-run first-boot. Do not bypass the check with the pod's own
  CN: that would let local clients advertise fabric-wide interest.
- **First-boot says the fabric router certificate name changed.** Rendering has stopped before it
  touched the running configuration. The goat-side operator owns confirmation of the new name
  through the trusted onboarding channel. The partner sets the confirmed value as
  `ZENOH_FABRIC_CERT_CN` in the active profile and re-runs. Do not copy the newly discovered value
  from the error into the profile without that confirmation.
- **A changed render was rejected and the previous configuration is running.** The automatic
  rollback preserved service, but first-boot still exits non-zero. The partner checks the active
  profile for a bad value; otherwise the goat-side operator owns a confirmed problem with the
  router template or the fabric endpoint. Correct the cause and re-run first-boot.
- **Rollback was refused because an identity changed.** The router is intentionally stopped. The
  goat-side operator confirms the intended POD and fabric identities; the partner then corrects
  the bundle or profile and re-runs. Do not copy the last-known-good file over `config.json5`.
- **mTLS handshake fails on connect.** The cert under `/etc/zenoh/tls/` must be rooted in the
  same CA as the goat side (it is, when it came from your bundle). A stale cert from a previous
  bundle is the usual cause — re-run first-boot to rotate.

## See also

- [`architecture.md`](architecture.md) — where the router sits in the bundle and the data flow.
- [`partner-contract.md`](partner-contract.md) — the Tier-2 ingress model the ACL is sized
  against.
- [`zagros-vs-production.md`](zagros-vs-production.md) — what varies per stack and where it lives.
- [`partner-run-guide.md`](partner-run-guide.md) — running a pod end-to-end.
- `host/zenoh-router.json5.tmpl` — the committed template this doc explains.
