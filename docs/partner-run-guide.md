# Partner run guide — stand up the pod you were handed

Turnkey, idempotent path to bring a moon-pod up against the zagros fabric and verify it. You run
this on **your own host**. Use `sudo bash moon_pod_setup.sh`; its **Configure inputs** menu
collects the onboarding values without changing a tracked file and reads the single-use key
without echoing it.

## What you receive at onboarding

| Input | Supplied by | Single-use |
|---|---|---|
| `GOATNET` | Goat side, in the welcome package | No |
| `NETBIRD_MANAGEMENT_URL` | Goat side, in the welcome package | No |
| `NETBIRD_SETUP_KEY` | Goat side, in the welcome package | Yes |
| `PARTNER_NAMESPACE` (the slot ID) | Goat side, in the welcome package | No |
| `POD_ID` | Goat side, in the welcome package | No |
| Signed join bundle (tarball or `.cbor`) | Goat side | No |
| CA root (`CA_ROOT_PEM`, or the `.pem` in the bundle tarball) | Goat side | No |
| `EXPECTED_CA_FINGERPRINT` | Goat side, through a different channel from the CA root | No |
| `goat` binary and its `.sha256` file | Goat side | No |
| Host, Docker, encrypted state volume | Partner, prepared in Part 1 | No |

`POD_ID` is the host name NetBird registers for this POD: 1-59 lowercase letters, digits, or
hyphens, starting and ending with a letter or digit.

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
  live there — custody-floor requirement 6a).
- **Docker** + the compose plugin.
- A **mesh client**: stock NetBird is the zagros on-ramp (`netbird up` with the bundle's setup-key);
  the production path uses `goat-clientd` and first-boot drives it for you.
- The **`goat`** binary on `PATH`, and `envsubst` (from `gettext`).
- **OpenSSL**, used by first-boot to verify and identify the fabric router before rendering its ACL.
- Your goatnet's **CA root** (a `.pem`, usually in your onboarding tarball) and
  a fingerprint, from the goat side, to check it against.
  `goat` ships with no goatnet built in and cannot verify your bundle without it — see
  [Trust your goatnet's CA root](#trust-your-goatnets-ca-root).

## Fill your profile (manual path)

The bundle carries your identity and endpoints, but the local profile anchors the pod to your
**slot ID** (the per-uuid namespace minted at enrollment) and enables zagros's documented
certificate/slot binding. The shipped profile carries the slot as a `CHANGE-ME` placeholder.
Fill it in a **local copy** — the copy is gitignored, so your slot ID never lands in a commit:

```
cp -r profiles/zagros profiles/zagros-local
$EDITOR profiles/zagros-local/profile.env
#   PARTNER_NAMESPACE=<your slot ID>  # compatibility variable; first-boot fails loud without it
#   VERIFY_CERT_SLOT_BINDING=1              # add this when upgrading an older zagros-local copy
```

The value is the slot ID from your onboarding response; your cert's CN already carries the same
value and arrives in the bundle, so there is nothing else to copy. `first-boot.sh` refuses to run
with `PARTNER_NAMESPACE` unset, so a forgotten fill fails immediately rather than half-standing
the pod up.

## Bring-up

The supported setup path is:

```sh
cd zagros-moon-pod
sudo bash moon_pod_setup.sh
# c: Configure inputs; 1: prepare host; 2: stand up; 3: verify
```

Part 1 never joins the mesh. **Configure inputs** reads the key without echo. Part 2 validates
the bundle location, slot, POD ID, CA root, fingerprint, and
certificate binding before it spends that key. If the key was entered at the prompt, it passes
through a mode-0600 file on the encrypted state volume, never a command argument. A protected
`NETBIRD_SETUP_KEY_FILE` is passed directly and is not copied or rewritten.

For a manual stand-up, put the key in a protected temporary file and use the same ordering:

```
# 1. Tell goat which key signs bundles for your goatnet, and verify its fingerprint first.
#    (once per goatnet; see "Trust your goatnet's CA root" below).
#    GOAT_PROFILE_DIR is load-bearing — without it the root lands where first-boot never looks.
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat ca add <ca-id>.pem

# 2. Join only after every other input validates. The key never appears in ps or shell history.
sudo install -m 600 /dev/null /run/netbird-setup-key
read -rs key; printf %s "$key" | sudo tee /run/netbird-setup-key >/dev/null; unset key
sudo netbird up --management-url <mgmt-url-from-onboarding> --setup-key-file /run/netbird-setup-key
sudo sh -c ': > /run/netbird-setup-key; unlink /run/netbird-setup-key'

# 3. Require exact management connectivity and a non-zero connected-peer count.
sudo netbird status

# 4. Run first-boot with your filled profile + your bundle. This verifies the bundle, extracts your
#    mTLS identity, renders the Zenoh router config from the BUNDLE's router endpoint, and starts
#    the data plane. Re-runnable.
sudo ./host/first-boot.sh zagros-local /path/to/<handle>.cbor
```

first-boot prints six numbered steps, in order: [1/6] verify the bundle + extract certs
(`goat profile init`) → [2/6] lay the Zenoh mTLS material → [3/6] import the bundle into
`goat-clientd` — on the zagros sandbox this step prints **skipped**, which is normal (stock
NetBird is the sandbox mesh client) → [4/6] verify the fabric peer and render the router config
(router endpoint **from the bundle**) → [5/6] start `zenoh-router` and `audit-sink` via compose →
[6/6] install the `goat-doctor` health timer.

During [4/6], first-boot makes a CA-verified mTLS connection to the bundle's router endpoint and
prints the fabric router certificate CN it bound into the ACL. If that identity cannot be
verified, rendering stops; check the mesh and endpoint rather than copying an unverified CN into
the profile. The zagros profile does not assume every endpoint role shares one certificate name.
Without an onboarding pin, it accepts the verified name on first use and records it only after
router health.

## Upgrade an existing pod for fabric forwarding

PODs installed before this router-ACL fix must re-render; restarting an old rendered config is
not enough. Keep the same local profile and bundle, update this repository, then run the same
first-boot command used originally:

```bash
git pull --ff-only
sudo ./host/first-boot.sh zagros-local /path/to/<your-handle>.cbor
sudo docker ps --filter name=goat-moon-zenoh-router
```

An unchanged bundle is not consumed again: first-boot reports `profile present and bundle
unchanged`. It replaces `config.json5` only when the rendered content changes and then restarts an
already-running router so zenohd loads the new ACL. It waits up to about two minutes for the router
to become healthy and records the render and fabric identity as applied only after that succeeds.
The upgrade also adds a deterministic router `id`, so the first run restarts once even when the
ACL inputs did not change; later unchanged runs do not restart. Confirm the file
contains the `fabric-interest` rule and distinct `pod-peer` and `fabric-peer` subjects; never edit
it by hand. Print both timestamps in UTC so they can be compared directly:

```bash
sudo date -u -r /var/lib/goat-moon/zenoh/config.json5 '+rendered %Y-%m-%dT%H:%M:%SZ'
sudo date -u -d "$(sudo docker inspect -f '{{.State.StartedAt}}' goat-moon-zenoh-router)" '+router started %Y-%m-%dT%H:%M:%SZ'
```

When the render changes, the router start time is later. When nothing changed, first-boot prints
`router config unchanged` and does not restart the router; the older render time is also the
expected passing state.

Before replacing an applied configuration, first-boot saves one mode-`0600` last-known-good copy.
If the new render is rejected and the POD and fabric certificate names are unchanged, it restores
that copy, restarts once, reports that the previous configuration is running, and exits non-zero.
Fix the named profile or template problem and re-run. It never rolls back across a certificate
identity change; in that case it leaves the router stopped until the goat-side operator confirms
the intended identities.

Rollback starts only when the router exits or fails its local port health probe. A configuration
that loads with a wrong access rule counts as healthy and is not rolled back; the running-router
delivery check below is what catches that case.

The router now accepts local sessions only when their certificate CN matches the POD certificate.
A different certificate signed by the same CA may complete TLS, but its operations are silently
denied; applications must use the certificate and key extracted from this POD's bundle.

To confirm fabric arrival, note your slot's `publish_count` in the portal catalog, publish one
message to a fixed test key through the **running local router** (`tls/127.0.0.1:7447`) using your
normal application or one of the clients in [`../clients/`](../clients/README.md), then refresh
for up to three minutes. Put a unique nonce in the payload, not the key. The slot-level count must
rise. Also confirm the local audit metric rises:

```bash
curl -fsS http://127.0.0.1:9303/metrics | grep '^goat_audit_samples_total'
```

A local metric rise with no catalog rise is **not confirmed fabric delivery**. Leave the router
running, retain the key and timestamp, and report the result to the goat-side operator. Do not
stop the router and publish directly to the fabric: that bypasses the path this check is meant to
prove.

If the endpoint presents a certificate name different from the last healthy run, first-boot stops
before rendering. The goat-side operator owns confirmation of the new name through the trusted
onboarding channel. The partner then sets the confirmed name as `ZENOH_FABRIC_CERT_CN` in the
active profile, re-runs first-boot, and repeats the timestamp and delivery checks above. Do not
copy the name from the error without that confirmation. An endpoint pool whose routers present
different CNs is not supported by this CN-bound ACL.

### Trust your goatnet's CA root

`goat` ships with **no goatnet built in**. Before it accepts a signed bundle it has to be told
which certificate authority signs bundles for your goatnet: you add its **CA root** (a small
`.pem`) once, and first-boot verifies your bundle against it. The CA roots inside the signed
bundle are different: the router uses them for fabric TLS, and they cannot vouch for the bundle
that carries them.

**Get the CA root.** Two places, in this order:

1. **Your onboarding tarball**, when the goat side configured it: `<prefix>-goat-cli-ca.pem`,
   next to the `<prefix>-goat-cli.cbor` it verifies. `moon_pod_setup.sh` unpacks the tarball for
   you and uses this file when `CA_ROOT_PEM` is unset, once you have confirmed its fingerprint
   (below). Check with
   `tar tzf <pod-id>-bundle.tar.gz | grep -- -goat-cli-ca.pem`.
2. **An already-enrolled workstation**, when the tarball has no such file. Copy the trusted
   CA root from that workstation along with the binary, or ask the goat side
   to send the root file. Do not join this POD to the mesh first merely to fetch trust:
   bundle verification intentionally precedes the single-use mesh join.

Take the root for the CA-ID that signs this bundle. The goat side can name it, and first-boot
names it when missing (`This bundle is signed by <ca-id>`).

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
A CA root and a bundle from the same tarball agree with each other by construction, so the
comparison is the only check that the pair is genuine. The
file is public, so secrecy is not the point; that it is the *right* root is, and anyone
who can hand you a file can hand you a substitute root.

`moon_pod_setup.sh` requires `EXPECTED_CA_FINGERPRINT` unless the POD already trusts a CA root. Before it adds anything, Part 2 reads the root's fingerprint and requires it to equal the `SHA256:<hex>` value the goat side supplied through the separate channel. To see what the pod trusts at any time:

```
sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat ca ls
```

This is a once-per-goatnet step. It survives re-runs of first-boot and bundle rotations, and a
second goatnet is a second `goat ca add`, not a new `goat` binary.

## Verify

```
cd zagros-moon-pod
sudo bash moon_pod_setup.sh   # choose Part 3
```

Part 3 baselines the local audit count and the slot's catalog `publish_count`, publishes one
message with a unique nonce to `<slot>/test/ping` through `tls/127.0.0.1:7447`, and waits up to
three minutes. Its delivery row reports the first applicable outcome:

| Outcome | Meaning |
|---|---|
| **Publish failed** | The local publish returned an error. This is a failure. |
| **Not delivered** | The readable local audit count did not rise. This is a failure even if the slot-wide catalog count rose. |
| **Not verified** | A required count could not be read, including a stopped audit sink or a refused, throttled, timed-out, or unreachable catalog. This is neither pass nor fail; follow the printed next step. |
| **Local only** | The local count rose but the slot-wide catalog count did not. This is a failure; send the printed key and UTC time to the goat side. |
| **Delivered** | Both counts rose. This passes, but the slot-wide count cannot prove which message caused the rise. |

The overall result is **Verified** only when every local check passes and delivery is
**Delivered**; **Not verified** when nothing failed but evidence could not be read; otherwise it
is **Failed**. Restart acceptance is outside Part 3 and requires a deliberate reboot.

Part 3 never stops or starts the router. A passing publish proves local delivery and that the fabric
recorded a publish under the slot; it does not prove bilateral inbound delivery, topic
declaration, durable audit retention, or that one particular payload produced the count rise.

### Live catalog check (partner-run; do not record secrets)

On an enrolled Linux POD, run Part 3 with the real POD profile and token. Record only the UTC
publish-start time, baseline and final `publish_count`, baseline and final `last_publish_at`, HTTP
status/cause if not verified, and the verdict rows. Never copy `portal.token`, request
headers, setup keys, bundle contents, or operator credentials into the record. A stub or CI run
is not live verification.

Your slot ID is the namespace your cert is bound to (the compatibility variable
`PARTNER_NAMESPACE` in the generated local profile). A
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
  `INBOUND_NAMESPACE` prefix from your profile (`release/goat/**` is the prefix a bilateral grant uses;
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
  CA root — see [Trust your goatnet's CA root](#trust-your-goatnets-ca-root). Your bundle is fine:
  verification is local and nothing was consumed, so do **not** ask for a fresh one. The usual
  cause is a root added without `GOAT_PROFILE_DIR`, which lands in `~/.goat` instead of the
  pod's state volume; the second is the root of a different goatnet than the one that signed
  your bundle (the error names the CA-ID it wants).
- **`goat-moon-audit-sink` is missing or restarting:** it starts with the router and
  subscribes to your namespace on the local router. Check it with
  `curl -s http://127.0.0.1:9303/metrics | grep ^goat_audit_`:
  `goat_audit_subscriber_session_state 1` means it is subscribed, and `goat_audit_samples_total`
  counts what it has seen. If it logs `Permission denied` while opening its session, it cannot
  read the TLS files: re-run first-boot, which lays them as `root:65532`, mode `0640`. The data
  plane does not depend on the sink, but local acceptance does.
- **`goat doctor` router check fails:** confirm `netbird status` reports exactly
  `Management: Connected` and a connected-peer count greater than zero, and
  that the bundle hasn't expired (`goat profile show`). The router endpoint the pod uses comes
  from the bundle, so a stale bundle points at the wrong place — get a fresh one.
- **first-boot says `fabric router certificate name changed`:** the running router and applied
  config were left untouched. The goat-side operator confirms the new name through the trusted
  onboarding channel; the partner puts that confirmed value in `ZENOH_FABRIC_CERT_CN` and
  re-runs. Do not accept the discovered value without confirmation.
- **first-boot says the new configuration was rejected and the previous one is running:** rollback
  preserved the data plane, but the run failed. Check the active profile for a bad value; if it is
  correct, the goat-side operator owns a confirmed problem with the router template or the fabric
  endpoint. Send the displayed router logs and re-run after correcting the cause.
- **first-boot says the saved certificate identities could not be verified:** the stopped router is
  the safe state. The goat-side operator confirms the intended POD and fabric identities; the
  partner corrects the bundle or profile and re-runs. Do not restore the saved file by hand.
- **first-boot says rollback was refused because an identity differs:** the stopped router is the
  safe state. The goat-side operator confirms the intended POD and fabric identities; the partner
  corrects the bundle or profile and re-runs. Do not restore the saved file by hand.
- **A container can't pull its image:** every pod image is public; run `tests/check-images-public.sh`
  to confirm reachability from your host.
- **A publish "succeeds" but nothing arrives:** check you published *inside* your slot. Denials
  are silent by design.
- **A `goat` command without `sudo` cannot find its profile:** first-boot roots the state dir, so
  goat needs root to read it (see the `sudo` note under Verify; goat 0.4.43 reports this as
  `E_PROFILE_MISSING`, not as a permission error). To pass a variable, put it after `sudo`, as in
  `sudo GOAT_PROFILE_DIR=… goat …`: `sudo` drops variables set in front of it.
- **Writing your own client/bridge, and worried about the router's one-transport-per-identity
  rule?** That rule is about *the pod's own goat-cli sessions* (`goat pub`/`sub`/`flow`)
  dialing the fabric endpoint directly with the same identity the router already holds — it is
  not about clients in general. A client or bridge pointed at the **local** router
  (`GOAT_ROUTER=tls/127.0.0.1:7447`, per [`clients/README.md`](../clients/README.md)) is a
  *different* connection from the router's own outbound session to the fabric; the router is
  built to accept multiple simultaneous local clients this way (the audit-sink and a bridge at
  the same time). You do **not** need to stop the router for this — only for a `goat`
  command that dials the fabric endpoint directly under the pod's own identity.
