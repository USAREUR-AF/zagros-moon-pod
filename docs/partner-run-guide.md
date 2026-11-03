# Partner run guide — stand up the pod you were handed

Turnkey, idempotent path to bring a moon-pod up against the zagros fabric and verify it. You run
this on **your own host**. Everything environment-specific (which fabric, your identity, your
namespace) is carried in the **signed join bundle** you were given at onboarding — the only
value you copy by hand is your slot id (`PARTNER_NAMESPACE`) in
[Fill your profile](#fill-your-profile).

## What you receive at onboarding

1. A **signed join bundle** (`<your-handle>.cbor`) — carries your mesh setup-key, your fabric
   router endpoint, your mTLS identity (your zagros slot), and the CA roots your router trusts
   for fabric TLS. It is the single source of truth; the pod reads everything from it.
2. The **`goat` CLI binary** for your platform (linux-amd64 / linux-arm64).
3. **A clone of this repository.**

The bundle exists because a machine was enrolled: your organisation's custodian runs
`goat machine enroll <handle> --node-class <class>` against the enrollment quota the goat side
seeded at onboarding, and the enrollment mints the slot, the mTLS identity, and a single-use
mesh setup key in one act. The handle is the machine's name; keep the host's hostname equal to
it. A setup key that lapsed before the machine joined is re-minted quota-neutrally with
`goat machine mesh-key <handle>`; the machine does not need re-enrolling.

> Treat the bundle as a secret in transit. It activates on first use and expires; if it lapses,
> ask for a fresh one.

### If you have not received these

You are blocked, and nothing in this guide can unblock you. The bundle exists only after the
goat side has enrolled your pod and seeded the enrolment grant that authorizes it: no grant, no
bundle. Without the bundle and the slot id from your onboarding response there is nothing to
fill, nothing to join, and nothing for first-boot to verify. There is no self-service
workaround. A refused or silent response to an enrolment attempt is the rail working, not a
fault on your host. The fix is to contact the goat side and ask where your enrolment stands,
then wait for the package. (The operator's half of this exchange is
[`goat-side-enrollment.md`](goat-side-enrollment.md).)

## Prerequisites on your host

Starting from bare hardware? [`pod-host-bringup.md`](pod-host-bringup.md) takes you from a
blank machine (Raspberry Pi 5 worked example included) to every box below checked.

- A Linux host you control, with data on a **LUKS-encrypted volume** (the pod's state dir must
  live there — sovereignty requirement 6a).
- **Docker** + the compose plugin.
- A **mesh client**: stock NetBird is the zagros on-ramp (`netbird up` with the bundle's setup-key);
  the production path uses `goat-clientd` and first-boot drives it for you.
- The **`goat`** binary on `PATH`, and `envsubst` (from `gettext`).
- Your goatnet's **CA root** (a public-key `.pem` — usually already in your bundle tarball) and
  a fingerprint, from the goat side, to check it against.
  `goat` ships with no goatnet built in and cannot verify your bundle without it — see
  [Trust your goatnet's CA root](#trust-your-goatnets-ca-root).

## Fill your profile

The bundle carries your identity and endpoints, but one profile field anchors the pod to your
**slot** (the per-uuid namespace minted at enrollment), and the shipped profile carries it as a
`CHANGE-ME` placeholder. Fill it in a **local copy** — the copy is gitignored, so your slot id
never lands in a commit:

```
cp -r profiles/zagros profiles/zagros-local
$EDITOR profiles/zagros-local/profile.env
#   PARTNER_NAMESPACE=<your slot id>     # your write namespace (first-boot fails loud without it)
```

The value is the slot id from your onboarding response; your cert's CN already carries the same
slot and arrives in the bundle, so there is nothing else to copy. `first-boot.sh` refuses to run
with `PARTNER_NAMESPACE` unset, so a forgotten fill fails immediately rather than half-standing
the pod up.

## Bring-up

```
# 1. Join the mesh with the setup-key from your bundle (zagros sandbox path). The setup-key is
#    single-use — run this once, after the prerequisites and profile are in place:
sudo netbird up --management-url <mgmt-url-from-onboarding> --setup-key <setup-key-from-onboarding>

# 2. Tell goat which CA signs bundles for your goatnet: add its root to the POD's trust store
#    (once per goatnet; see "Trust your goatnet's CA root" below for where the file comes from).
#    GOAT_PROFILE_DIR is load-bearing — without it the root lands where first-boot never looks.
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat ca add <ca-id>.pem

# 3. Run first-boot with your filled profile + your bundle. This verifies the bundle, extracts your
#    mTLS identity, renders the Zenoh router config from the BUNDLE's router endpoint, and starts
#    the data plane. Re-runnable.
sudo ./host/first-boot.sh zagros-local /path/to/<your-handle>.cbor
```

first-boot prints six numbered steps, in order: [1/6] verify the bundle + extract certs
(`goat profile init`) → [2/6] lay the Zenoh mTLS material → [3/6] render the router config
(router endpoint **from the bundle**) → [4/6] import the bundle into `goat-clientd` — on the
zagros sandbox this step prints **skipped**, which is normal (stock NetBird is the sandbox mesh
client) → [5/6] start `zenoh-router` via compose (`audit-sink` is opt-in behind the
`audit` profile — see Trouble) → [6/6] install the `goat-doctor` health timer.

### Trust your goatnet's CA root

`goat` ships with **no goatnet built in**. Before it accepts a signed bundle it has to be told
which certificate authority signs bundles for your goatnet: you add that CA's **root** (a public
key, a small `.pem` file) once, and first-boot verifies your bundle against it. The CA roots
*inside* the bundle are a different thing — they are what your router trusts for fabric TLS,
and they cannot vouch for the bundle that carries them.

**Get the root.** Two places, in this order:

1. **Your onboarding tarball**, when the goat side configured it: `<prefix>-goat-cli-ca.pem`,
   next to the `<prefix>-goat-cli.cbor` it verifies. `moon_pod_setup.sh` unpacks the tarball for
   you and uses this file when `CA_ROOT_PEM` is unset, once you have confirmed its fingerprint
   (below). Check with
   `tar tzf <pod-id>-bundle.tar.gz | grep -- -goat-cli-ca.pem`.
2. **Your goatnet's download surface**, the same place the `goat` binary comes from, when the
   tarball has no such file (or to add a further goatnet later). It is mesh-only, so fetch it
   after step 1, or on your already-onboarded workstation and copy it over with the binary:

```
https://get.<goatnet>/ca-roots/
```

The page lists each root with its CA-ID and fingerprint. Take the one your bundle is signed by:
the goat side can tell you which, and first-boot names it when it is missing (`This bundle is
signed by <ca-id>`).

**Add it to the pod's trust store:**

```
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat ca add <ca-id>.pem
```

`GOAT_PROFILE_DIR` is load-bearing. goat keeps its trust store inside its profile directory, and
first-boot pins the pod's profile directory to the state volume (`/var/lib/goat-moon/goat-cli`,
or `<POD_STATE_DIR>/goat-cli` if your profile moves the state dir). A plain `goat ca add` writes
to `~/.goat/ca-roots` and `sudo goat ca add` to `/root/.goat/ca-roots`; first-boot reads
neither, and stops at [1/6] even though `goat ca ls` shows the root you just added. Put the
variable after `sudo`, as written: `sudo` drops variables set in front of it.

**Check the fingerprint.** `goat ca add` prints it. Compare it with one the goat side gave you
through a separate channel — not the tarball or page you took the file from — before you go on.
A root and a bundle from the same tarball agree with each other by construction, so the
comparison is the only check that the pair is genuine. The
root is a public key, so secrecy is not the point; that it is the *right* key is, and anyone
who can hand you a file can hand you a root.

`moon_pod_setup.sh` makes this check before it adds anything: step 2.5 reads the root's
fingerprint and trusts the root only when you type `yes` to it, or when it equals
`EXPECTED_CA_FINGERPRINT` (the `SHA256:<hex>` value the goat side gave you). Without a terminal
to answer on and without `EXPECTED_CA_FINGERPRINT`, it stops. To see what the pod trusts at any time:

```
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat ca ls
```

This is a once-per-goatnet step. It survives re-runs of first-boot and bundle rotations, and a
second goatnet is a second `goat ca add`, not a new `goat` binary.

## Verify

```
# Health — expect the cert/router checks green:
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat doctor --all

# Containers up:
sudo docker ps    # goat-moon-zenoh-router (audit-sink only if you opted into the audit profile)

# Round-trip publish on your own namespace (your slot), confirmed by the audit tail.
# Stop the pod router FIRST: the fabric allows exactly one transport per pod
# identity, and the running router holds it — a goat session under the same identity
# is refused (MAX_LINKS) while the router is connected. Restart it after.
sudo docker stop goat-moon-zenoh-router
echo hi > /tmp/ping
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat pub '<your-slot>/test/ping' --payload-file /tmp/ping
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat flow '<your-slot>/test/ping' --since 5m
sudo docker start goat-moon-zenoh-router
# Pass: the flow report's audit row reads "ok — 1 event(s)" — the fabric-side audit
# tail saw your publish arrive. Do NOT verify with `goat sub` after the pub: goat sub
# is a live subscriber and the fabric does not replay past events to it, so a sub
# started after the pub exits prints nothing (or, worse, prints unrelated live traffic
# in your slot and "passes" for the wrong reason). The one-transport rule is also why
# the sub can't simply run first in another terminal: a second concurrent goat session
# under the pod identity is the same MAX_LINKS collision.
```

If any command above wedges or errors, run `sudo docker start goat-moon-zenoh-router`
FIRST and debug afterwards — never leave the pod with its router stopped.

A `zenoh open failed … reason MAX_LINKS` on the pub or flow means the router was still holding
the identity's transport (or an earlier goat session had not reaped yet, ~seconds) — not a
credential or ACL fault. An intermittently *succeeding* pub with the router up is the same
collision won by luck during a router reconnect; do not trust it as a verify.

Your slot is the namespace your cert is bound to (the `PARTNER_NAMESPACE` first-boot reported). A
publish **outside** your slot is silently denied — that is expected; publish only within it.

The `sudo` in every command above is load-bearing: first-boot roots the state dir, so goat
needs root to read the profile. Forget it and goat 0.4.43 misreports the permission error as
`E_PROFILE_MISSING` ("no profile at ...") — if you see that at a path first-boot just wrote,
you dropped the `sudo`; the profile is there.

## Sending and receiving real data

- **From code:** pick your language under [`../clients/`](../clients/), copy the `publish` /
  `subscribe` example, point it at your slot. SDKs ship for C/C++, Go, Java, Python, Rust,
  TypeScript, plus legacy (Java 8, .NET Framework, C99, MATLAB) and file-drop / REST bridges.
- **Do it well:** [`../examples/`](../examples/README.md) has the producer best-practice patterns —
  set a self-describing encoding, recover after a partition, must-deliver a critical stream, and
  use liveliness for presence. Read [`quality-of-service.md`](quality-of-service.md) for which
  reliability each of your streams actually needs (don't over-buy guarantees).
- **Inbound (bilateral):** when a bilateral inbound channel is granted, subscribe to the
  `INBOUND_NAMESPACE` prefix from your profile (`release/goat/**` is the production convention;
  on zagros it falls back to your own slot until the grant exists).

## Declare your topics

The [partner contract](partner-contract.md) (req 5) requires a schema declaration for every
topic you publish — a machine-introspectable schema, or an explicit binary declaration for
formats that can't offer one. There are no "declare it later" exemptions. Declare through the
CLI you already have:

```
# Register the topic in the portal, then attach its schema body:
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat topic create --format protobuf:TempSample '<your-slot>/sensors/temp'
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat schema upload --version v1 '<your-slot>/sensors/temp' ./temp.proto
```

`goat schema ls` / `show` / `diff` read back what's registered. On the zagros sandbox the
goat-side schema-enforcer is **not live yet** (it's part of the boundary-conditioning layer —
see [`zagros-vs-production.md`](zagros-vs-production.md)), so an undeclared publish is not rejected
today — declare anyway; the contract requires it and production enforces it.

## Idempotency + teardown

- `first-boot.sh` is re-runnable: with the same bundle it skips the profile step entirely
  (re-rendering config only), a genuinely new bundle rotates the profile, and
  `docker compose up -d` is convergent.
- Tear the data plane down with `sudo docker compose -f compose/docker-compose.yml down` (sudo
  because `compose/.env` is root-owned); your state remains on your LUKS volume until you remove
  it.

## Trouble

- **first-boot stops at [1/6] with "no CA root is trusted", "This machine trusts no CA roots",
  or "this machine does not trust that CA":** the pod's trust store is missing your goatnet's
  root — see [Trust your goatnet's CA root](#trust-your-goatnets-ca-root). Your bundle is fine:
  verification is local and nothing was consumed, so do **not** ask for a fresh one. The usual
  cause is a root added without `GOAT_PROFILE_DIR`, which lands in `~/.goat` instead of the
  pod's state volume; the second is the root of a different goatnet than the one that signed
  your bundle (the error names the CA-ID it wants).
- **Where is `goat-moon-audit-sink`?** Audit observation is opt-in and currently broken
  upstream, so a plain `up` does not start it (the service sits behind the compose `audit`
  profile). Known v0 issue against the local router, two upstream defects: the subscriber
  image binds a competing TLS listener, and the pod's clientAuth-only leaf is rejected as a
  server cert by EKU-checking clients. Your data plane is unaffected — the router,
  `goat doctor`, and slot pub/sub all work. Nothing to fix on your host; once the upstream
  fixes ship, start it with `sudo docker compose -f compose/docker-compose.yml --profile audit up -d`.
- **`goat doctor` router check fails:** confirm the mesh is up (`netbird status` → Connected) and
  that the bundle hasn't expired (`goat profile show`). The router endpoint the pod uses comes
  from the bundle, so a stale bundle points at the wrong place — get a fresh one.
- **A container can't pull its image:** every pod image is public; run `tests/check-images-public.sh`
  to confirm reachability from your host.
- **A publish "succeeds" but nothing arrives:** check you published *inside* your slot. Denials
  are silent by design.
- **A `goat` command without `sudo` cannot find its profile:** first-boot roots the state dir, so
  goat needs root to read it (see the `sudo` note under Verify; goat 0.4.43 reports this as
  `E_PROFILE_MISSING`, not as a permission error). To pass a variable, put it after `sudo`, as in
  `sudo GOAT_PROFILE_DIR=… goat …`: `sudo` drops variables set in front of it.
- **Writing your own client/bridge, and worried about the router's one-transport-per-identity
  rule above?** That rule is about *the pod's own goat-cli sessions* (`goat pub`/`sub`/`flow`)
  dialing the fabric endpoint directly with the same identity the router already holds — it is
  not about clients in general. A client or bridge pointed at the **local** router
  (`GOAT_ROUTER=tls/127.0.0.1:7447`, per [`clients/README.md`](../clients/README.md)) is a
  *different* connection from the router's own outbound session to the fabric; the router is
  built to accept multiple simultaneous local clients this way (the audit-sink and a bridge at
  the same time). You do **not** need to stop the router for this — only for a `goat`
  command that dials the fabric endpoint directly under the pod's own identity.
