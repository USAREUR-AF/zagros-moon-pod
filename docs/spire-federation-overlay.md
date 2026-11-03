# SPIRE/SPIFFE federation overlay (optional, Phase 3+)

**Status: EXPERIMENTAL** — runnable config shape, **not yet run live and not wired into
first-boot** (bring-up is manual; see below). The pod side (this repo) and the reciprocal goat
side are both in place as design + config; a first pod↔zagros federation has not been run
end-to-end.

## What this is (and why federation, not "join goat's SPIRE")

The base pod meets the partner contract **without** workload identity. This overlay is the
first-class option for a partner that wants (or is required to have) **attested** workload
identity for the pod's own containers — and it does it the sovereignty-clean way:

- The pod runs its **own** SPIRE server = its **own** trust domain (`spiffe://<partner>.pod`) =
  its **own** root CA. It issues and rotates its workloads' SVIDs **locally**.
- It **federates** with the zagros trust domain (`spiffe://<goatnet-trust-domain>` — the
  concrete value comes from the goat side at federation setup), exchanging
  only **public trust bundles**. The partner CA private key never leaves the pod; goat hosts no
  partner SVIDs; the pod never calls the goat core to mint a cert.
- Each side's SPIRE is a single point of failure **for its own domain only** — federation
  *contains* the SPOF, it does not create or remove one. HA (a second server in a domain) is an
  orthogonal, per-side choice.

This is the partner-pod case from **ADR 0412 (addendum 2026-06-19)**.
It is **not** membership (the pod does not join zagros's trust domain) and **not** HA.

## Run it

```
docker compose -f compose/docker-compose.yml -f compose/docker-compose.spire.yml up -d
```

`first-boot.sh` does **not** render or start any of this yet — the overlay is not wired into the
scripted path. You render `spire/server.conf`, `spire/agent.conf`, `spire/spiffe-helper.conf`
into `${POD_STATE_DIR}/spire/` and set the profile vars yourself (see
[Manual bootstrap](#manual-bootstrap-until-first-boot-wiring-lands) below). Bring-up order:
server → (bootstrap bundles) → agent (with a one-time join token) → register entries →
spiffe-helper → router picks up the SPIRE-issued leaf.

### Env vars (set in `compose/.env` — root-owned, edit with sudo)

```
# --- SPIRE federation overlay (optional) ---
POD_TRUST_DOMAIN=spiffe://CHANGE-ME.pod          # the pod's own trust domain
ZAGROS_SPIRE_BUNDLE_ENDPOINT=<goatnet-spire-bundle-endpoint>:8443  # from the goat side at federation setup
# The router's SVID CN must equal the pod's zagros slot ACL subject — on zagros that is your slot id
# (the same value as PARTNER_NAMESPACE) — so the CN-keyed goat ACL admits the SPIRE leaf
# unchanged. Used as the -dnsName in the registration entry below.
POD_ROUTER_SVID_CN=${PARTNER_NAMESPACE}
```

### Manual bootstrap (until first-boot wiring lands)

Nothing scripted creates the overlay's state. Do this once, in order — every mounted path must
exist as a **file or directory of the right kind before compose runs**, because docker creates a
missing bind-mount source as a *directory*, which would shadow a conf file and fail the service:

```
# 1. State dirs + confs (compose mounts these exact paths):
sudo mkdir -p ${POD_STATE_DIR}/spire/{data/server,data/agent,agent-sock}
sudo cp spire/server.conf spire/agent.conf spire/spiffe-helper.conf ${POD_STATE_DIR}/spire/
# (-expandEnv in the compose commands resolves ${POD_TRUST_DOMAIN} etc. at start — no envsubst.)

# 2. Seed zagros's public bundle (obtained out-of-band from your goat contact) — must be a FILE:
sudo cp zagros-bundle.pem ${POD_STATE_DIR}/spire/zagros-bundle.pem

# 3. Server first:
sudo docker compose -f compose/docker-compose.yml -f compose/docker-compose.spire.yml up -d spire-server

# 4. Agent bootstrap trust (the agent verifies its own server with this bundle, not
#    insecure_bootstrap):
sudo docker exec goat-moon-spire-server /opt/spire/bin/spire-server bundle show -format pem \
  | sudo tee ${POD_STATE_DIR}/spire/data/agent/bootstrap-bundle.pem >/dev/null

# 5. One-time join token, then first-start the agent with it (subsequent restarts reuse the
#    agent's persisted identity):
sudo docker exec goat-moon-spire-server /opt/spire/bin/spire-server token generate \
  -spiffeID spiffe://<partner>.pod/agent
sudo docker compose -f compose/docker-compose.yml -f compose/docker-compose.spire.yml \
  run --rm spire-agent -config /run/spire/conf/agent.conf -expandEnv -joinToken <token>

# 6. Register the router workload (next section), then bring the whole overlay up:
sudo docker compose -f compose/docker-compose.yml -f compose/docker-compose.spire.yml up -d

#    Verify the helper actually came up and wrote the leaf — a config error crashloops it
#    silently under restart, and the router then never gets an SVID:
sudo docker logs goat-moon-spire-helper-router --tail 5
ls -l ${POD_STATE_DIR}/zenoh/tls/pod-cert.pem ${POD_STATE_DIR}/zenoh/tls/pod-domain-bundle.pem

# 7. The helper writes the SPIRE leaf into ${POD_STATE_DIR}/zenoh/tls (pod-cert.pem /
#    pod-key.pem only — ca-roots.pem is never touched). Restart the router once to load it,
#    and again after any rotation (zenohd reads TLS material at startup only):
sudo docker restart goat-moon-zenoh-router
```

### Register the router workload (CN-bearing SVID)

```
# The first -dnsName becomes the leaf's Subject CN (the bridge).
sudo docker exec goat-moon-spire-server /opt/spire/bin/spire-server entry create \
  -spiffeID  spiffe://<partner>.pod/zenoh-router \
  -parentID  spiffe://<partner>.pod/spire/agent/join_token/<token> \
  -selector  docker:label:com.docker.compose.service:zenoh-router \
  -dnsName   "<zagros-slot-CN>" \
  -federatesWith spiffe://<goatnet-trust-domain>
```

## The one-time bundle bootstrap

Federation refreshes bundles automatically once each side trusts the other's endpoint, but the
**first** exchange is out-of-band (neither side trusts the other yet):

```
# On the pod: export the pod's bundle, hand it to the goat operator.
sudo docker exec goat-moon-spire-server /opt/spire/bin/spire-server bundle show -format spiffe \
  > pod-bundle.spiffe.json

# On the pod: import zagros's bundle — the copy seeded in runbook step 2, which the compose file
# mounts into the server container at this path:
sudo docker exec goat-moon-spire-server /opt/spire/bin/spire-server bundle set -format pem \
  -id spiffe://<goatnet-trust-domain> -path /run/spire/conf/zagros-bundle.pem
```

## Reciprocal goat side (goat-side work, not here)

For the zagros server to trust the pod, the goat side configures its own SPIRE server to
federate with `spiffe://<partner>.pod` (a bundle endpoint plus a federates-with entry) and
imports the pod's bundle — gated per pod, per goatnet, reversible. The exact steps are goat-side
work; ask your goat contact when you reach this stage. For pod→goat peering the
goat-side ingress gateway verifies the pod's federated SVID off the core router (ADR 1020 Tier-2),
so the core ACL is not the only enforcement point.

## Status

- **Live today:** nothing here; no federation relationship exists yet.
- **This overlay:** runnable config shape, images to be digest-pinned, **first live run pending**.
- **Native end-state:** when an upstream Zenoh URI-SAN ACL matcher lands, the SVID's `spiffe://`
  SAN becomes the wire identity directly and the CN-bearing bridge retires.
