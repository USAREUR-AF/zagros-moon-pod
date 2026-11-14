# Partner-receiver contract — the seven requirements

Self-contained partner-facing summary of the contract a moon-pod meets at the boundary.
This is the reference vendored into this repo so the pod is documented end-to-end without
reaching into goat's internal design tree. The authoritative contract is maintained on the goat
side; this summary is kept faithful to it.

A conformant moon-pod meets all seven at the boundary. *How* each is met is the pod's (or a
vendor pod's) choice — the contract is the boundary behaviour, not a specific implementation.

## The "moon" metaphor

A moon-pod orbits the goat fabric and exchanges data with it, from hardware the partner runs.
The partner can read it, log it, fork it, and leave at any time. Running the box is not the same
as controlling what it exchanges: what a moon-pod is today, and what it does not give a partner,
is in the [README's status section](../README.md#status-what-a-moon-pod-is-today).

## The seven requirements

1. **Identity assurance + IdP standard.** Every operator who can read or publish the pod's
   namespace carries an identity from an IdP that emits standards-compliant assertions (OIDC
   discovery, or SAML 2.0 with an integration note). Floor: NIST SP 800-63 IAL2 / AAL2 (verified
   proofing + phishing-resistant MFA).

2. **Network / transport encryption.** Bytes between the partner edge and the goat edge are
   end-to-end encrypted with keys neither side delegates to a third party, and the partner-side
   handshake is silent at the public boundary. WireGuard preferred; IPsec acceptable; mTLS over
   public HTTPS acceptable as a documented fallback.

3. **Landing interface contract.** Data flows in and out at well-known Zenoh key-expressions
   under the pod's namespace, or at a documented adapter the partner runs that maps cleanly to
   those keys (REST / gRPC / MQTT / Kafka / file-drop / webhook / syslog / TAK CoT /
   MISP-STIX-TAXII / S3-object-drop). A native Zenoh peer is the preferred zero-translation
   shape.

4. **Audit retention.** The partner retains 90+ days of access logs covering reads and writes to
   the pod's namespace, queryable on demand ("who accessed topic X at time T as identity Y?").
   Format flexible. Goat does not require partners to ship logs to it.

5. **Schema declaration discipline.** Any topic the partner publishes carries a schema
   declaration on the `attest/schema/<topic>` convention. Undeclared publishes are rejected at
   the goat-side boundary by the schema-enforcer. No "declare it later" exemptions.

6. **Custody floor** — three nested invariants about what stays on the partner's side, all of
   which hold:
   - **(a) Data** lands at rest only on partner-controlled hardware/infrastructure.
   - **(b) Identity** — operator credentials live in the partner's controlled IdP. Goat may ship
     the IdP binary; once it runs on the partner's host the credential database is theirs.
   - **(c) Audit** logs live in partner storage. Goat does not aggregate partner audit by default.

   If any of the three flips, the floor does not hold. The floor is about where these three
   things live; it is not a sovereignty guarantee (see below).

7. **Reversibility / migration cleanliness.** A partner running a moon-pod can transition to
   operating their own coordination plane and router without re-onboarding under a different
   namespace, re-issuing identity, or re-issuing per-topic access. No architectural lock-in: the
   easy button is not a trap.

## What the custody floor does not cover

The floor says where data at rest, operator credentials and audit live. It does not make a pod
sovereign: the pod joins an environment someone else runs, and the goat-operated pieces below are
part of that environment. The [README's status section](../README.md#status-what-a-moon-pod-is-today) says what follows.

- **The goat-hosted coordination plane** (the partner-net mesh mgmt instance) enrols the pod and
  holds its connection metadata — WireGuard public keys, setup keys, peer addressing, last-seen.
- **The goat-operated boundary** processes the pod's data *in flight* (schema-enforcement,
  allowlist, conditioning, audit emission).
- **Goat-shipped binaries running on the partner host** (the pod bundle, IdP, translators): the
  partner rotates every shipped default key and credential at first boot.

## How the goat side receives a pod's data (Tier-2 ingress)

A moon-pod is a **Tier-2 peer** under goat's federated-peering trust model: partner-run,
possibly rooted in a different CA, so it is *not* the canonical goat↔goat (Tier-1) federation.
The pod's router does **not** federate directly into a goat core router. It connects to a
**goat-operated ingress gateway** that authenticates the pod's verified peering identity,
assigns it a stable origin scope, admits its data origin-scoped (so a pod can never write
another namespace or impersonate the fabric), and records provenance into the goat audit trail —
independent of, and complementary to, the pod's own local audit sink.

The pod is built to publish its own first-party namespace regardless; the admitted shape is the
receiver's concern. On the zagros sandbox the pod connects to whatever router endpoint the bundle
provides.
