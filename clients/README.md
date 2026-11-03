# clients — send & receive data with a goat-moon-pod

This tree is for **the people consuming the pod**: how to publish data to the goat fabric and
receive data from it, in your language and with your tooling. Pick the path that fits you:

| You are… | Start here |
|---|---|
| A modern dev (Python/TS/Go/Rust/Java/C++) | [`examples/modern/<lang>/`](examples/modern/) |
| Working in an older / less-common stack (C, Java 8, .NET Framework, MATLAB) | [`examples/legacy-protocols/`](examples/legacy-protocols/) |
| Want to use a protocol you already speak (HTTP, MQTT, Kafka, files) — no Zenoh code | [`examples/bridges/`](examples/bridges/) |
| Just want the minimal connect snippet | [`connect/<lang>/`](connect/) |

## The whole model in 30 seconds

The pod runs a **Zenoh router** on your machine. You talk to it as a **Zenoh client over mTLS**.
Three operations, that's the whole API:

1. **Publish** (`put`) to keys under **your namespace** — e.g. `<your-namespace>/sensors/temp`.
2. **Subscribe** (`sub`) to keys you're allowed to read — your own, plus your inbound prefix
   for data goat sends you (when the relationship is bilateral).
3. **Query** (`get`) for the latest/historical value of a key (optional).

> **zagros note:** on the zagros sandbox your namespace is the per-uuid **slot** from your bundle
> (not `release/<you>`), and inbound falls back to that same slot until a bilateral grant
> exists — a `release/goat/**` subscription is simply empty there. The `release/...` forms in
> the examples are the production convention; substitute your slot on zagros.

Keys are slash-paths (`a/b/c`); subscriptions can use `*` (one segment) and `**` (any depth).

## What you need (from your pod operator / OOB bundle)

Every example reads the same five things — **from environment variables**, so you never hardcode
secrets:

| Env var | What it is | Example |
|---|---|---|
| `GOAT_ROUTER` | the pod's Zenoh endpoint | `tls/127.0.0.1:7447` (the pod is on your box) |
| `GOAT_CERT` | your mTLS client certificate (PEM) | `/etc/goat/mycert.pem` |
| `GOAT_KEY` | your mTLS private key (PEM) | `/etc/goat/mykey.pem` |
| `GOAT_CA` | the CA root that signs the router (PEM) | `/etc/goat/ca-root.pem` |
| `GOAT_NAMESPACE` | the prefix you own (publish under this) | `release/acme` |

> **On the pod host**, first-boot writes these under `/var/lib/goat-moon/goat-cli/contexts/<ctx>/`
> (`mtls.cert.pem`, `mtls.key.pem`, `ca-roots.pem`) — root-owned, so point at them with sudo or
> copy them out for your user. **On your own workstation** (you ran `goat profile init` yourself
> with an operator-handed bundle), they land at `~/.goat/contexts/default/`. **If the pod is on
> your machine, `GOAT_ROUTER` is `tls/127.0.0.1:7447`.** If you connect to a remote pod/router
> over the mesh, it's that host's mesh IP.

A copy-paste setup (pod host; swap the prefix for `$HOME/.goat` on a workstation):

```sh
export GOAT_ROUTER="tls/127.0.0.1:7447"
export GOAT_CERT="/var/lib/goat-moon/goat-cli/contexts/default/mtls.cert.pem"
export GOAT_KEY="/var/lib/goat-moon/goat-cli/contexts/default/mtls.key.pem"
export GOAT_CA="/var/lib/goat-moon/goat-cli/contexts/default/ca-roots.pem"
export GOAT_NAMESPACE="<your-slot-on-zagros>"   # release/acme is the production shape
```

## The one connection gotcha (read this — it bites everyone)

Zenoh's TLS config must be inserted as **one whole block**, with **`enable_mtls: true`**. Setting
the sub-keys one at a time (`transport/link/tls/connect_certificate`, etc.) silently does **not**
turn on the client-cert send path on Zenoh 1.x — your session opens but the router rejects you, or
you connect read-only. Every `connect/` helper here does it the working way. Also: when the
router cert's SAN binds an **IP/mesh address** rather than the DNS name you dial, set
`verify_name_on_connect: false` (the pod's local router is reached at `127.0.0.1`, so its examples
use `false`; a DNS-named remote router keeps it `true`).

## Versions

Examples target **Zenoh 1.9.0** (the fleet-pinned version — see the pod's
`compose/docker-compose.yml`). Use the matching-major client library for your language
(`eclipse-zenoh` 1.x). The bridges pin their own images by digest.

## Layout

```
clients/
├── connect/            minimal "bundle → Zenoh session" helper per language (the only goat-specific bit)
├── examples/
│   ├── modern/         idiomatic pub / sub / request-reply per language
│   ├── legacy-protocols/ older toolchains, offline/air-gapped, file/HTTP fallbacks
│   └── bridges/        use a protocol you already speak — no Zenoh code in your app
└── README.md           this file
```

Each subdirectory has its own README with exact build/run commands, including **offline / no-
internet** dependency instructions where relevant.
