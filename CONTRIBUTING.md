# Contributing to zagros-moon-pod

This repo is the shared surface where goat maintainers and partners co-develop the moon-pod. The
content is deliberately **self-contained and leak-free** — everything here is safe to read, fork, and build against
without goat-internal access.

## The one hard rule: nothing goat-internal lands here

This repo is read by external partners. Do **not** commit anything that belongs to the goat
internal substrate. Concretely, a change must not introduce:

- Links to or paths inside the private goat monorepo — its repo URL, its design or ops trees,
  ADR/finding *files* (citing an ADR *number* in prose is fine).
- Internal hostnames, mesh IPs, AWS account names, S3 bucket names, `aws-vault` profiles,
  Terraform paths, or operator-provisioning playbooks. The pod is the *partner* side; how goat
  mints bundles stays goat-internal.
- Secrets of any kind — setup-keys, certs, private keys, tokens, bundle CBOR. The `.gitignore`
  blocks the obvious ones; do not defeat it.
- Stack-specific values hardcoded into the pod scaffold (see "No over-specification" below).

If you need to reference an internal decision, describe it in plain prose or summarize it into a
self-contained doc under `docs/` (as `docs/partner-contract.md` does for the boundary contract).

## No over-specification against any stack

The pod runs against multiple goatnets (zagros sandbox today; production later). The compose stack,
host scripts, and config templates **hardcode nothing stack-specific**. Every environment value —
the fabric router endpoint, the mesh mgmt URL + setup-key, the mTLS identity, the CA roots —
arrives at runtime from the **signed join bundle** (the source of truth) or, for the handful of
values the bundle does not carry, the active **profile** under `profiles/<env>/`.

When you add a feature, ask: *does this bake a zagros / production assumption into the
pod?* If so, lift it into the bundle contract or a profile var. The deltas table in
[`docs/zagros-vs-production.md`](docs/zagros-vs-production.md) is the reference for what varies per
stack and where it legitimately lives.

## How we work

- **Sync direction: this repo wins.** zagros-moon-pod is the canonical home of the pod. Land
  changes here first, then port scrubbed versions out to any goat-side tree that mirrors them —
  never copy a goat-tree snapshot back over this repo. Unmarked snapshot drift is the known
  failure mode this rule exists to prevent.
- **Branch + PR.** Open a PR against `main`; keep changes scoped and reviewable.
- **Conventional Commits**, signed-off (`git commit -s`) for DCO.
- **Keep it runnable.** `tests/check-images-public.sh` must pass (every image anonymously
  pullable), and the smoke test in `tests/smoke/` should keep describing a real bidirectional
  round-trip.
- **License and DCO.** See [Licence](#licence) and [Policy](#policy) below.

## Where things live

- `docs/partner-contract.md` — the boundary contract a pod meets (self-contained).
- `docs/pod-host-bringup.md` — blank hardware to pod-ready host (Pi 5 worked example).
- `docs/architecture.md` — the bundle shape + data flow.
- `docs/router-config.md` — the Zenoh router config (example, structure, create/manage/use).
- `docs/partner-run-guide.md` — how a partner runs a pod (enroll, declare, verify).
- `docs/zagros-vs-production.md` — what varies per stack and how the pod stays agnostic.
- `docs/goat-client-v02-contract.md` — the production mesh-daemon contract.
- `docs/transport-tls-vs-quic.md`, `docs/quality-of-service.md` — transport choice + QoS model.
- `docs/proof-out-tracks.md` — candidate proof-out tracks.
- `docs/workload-identity-spire-overlay.md`, `docs/spire-federation-overlay.md` — the optional
  SPIRE/SPIFFE overlay (design + federation detail).
- `clients/` — the connect SDKs + worked examples partners build against.
- `examples/` — producer best-practice patterns (encoding, resilience, must-deliver, presence).
- `profiles/` — per-environment config (the only place stack-specific values belong). Filled
  copies (`profiles/*-local/`) are gitignored; partner slot ids never land in a commit.
- `host/`, `compose/` — the stack-agnostic pod scaffold (first-boot, units, router template,
  compose bundle + the optional SPIRE overlay file).
- `spire/` — SPIRE server/agent + spiffe-helper configs consumed by the overlay.
- `tests/` — the image-public guard + the bidirectional smoke spec (not yet runnable).
- `.claude/skills/` — in-repo Claude Code skills driving the docs. Skills defer to `docs/` for
  content and carry no partner-specific values and nothing goat-internal, same as everything
  else here.

## Licence

Portions written by U.S. Federal government employees within the scope of their employment are not subject to copyright in the U.S.; in countries where copyright is recognized, they and all other contributions are licensed under the [Apache License 2.0](LICENSE). See [INTENT.md](INTENT.md). Contributions are accepted under the [Policy](#policy) below.

**NOTE: This CONTRIBUTING.md is for software contributions. You do not need to follow the Developer's Certificate of Origin (DCO) process for commenting on this repository's documentation, such as CONTRIBUTING.md, INTENT.md, etc. or for submitting issues.**

## Policy

### 1. Introduction

The project maintainer for this Project will only accept contributions using the Developer's Certificate of Origin 1.1 located at [developercertificate.org](https://developercertificate.org) ("DCO"). The DCO is a legally binding statement asserting that you are the creator of your contribution, or that you otherwise have the authority to distribute the contribution, and that you are intentionally making the contribution available under the license associated with the Project ("License").

### 2. Developer Certificate of Origin Process

Before submitting contributing code to this repository for the first time, you'll need to sign a Developer Certificate of Origin (DCO) (see below). To agree to the DCO, add a `Signed-off-by` line to every commit with `git commit -s`. At a high level, signing off tells us that you have the right to submit the work you're contributing and indicates that you consent to our treating the contribution in a way consistent with the license associated with this software (as described in [LICENSE](LICENSE) and [INTENT.md](INTENT.md)) and its documentation ("Project").

### 3. Important Points

Pseudonymous or anonymous contributions are permissible, but you must be reachable at the email address provided in the Signed-off-by line.

If your contribution is significant, you are also welcome to add your name and copyright date to the source file header.

U.S. Federal law prevents the government from accepting gratuitous services unless certain conditions are met. By submitting a pull request, you acknowledge that your services are offered without expectation of payment and that you expressly waive any future pay claims against the U.S. Federal government related to your contribution.

If you are a U.S. Federal government employee and use a `*.mil` or `*.gov` email address, we interpret your Signed-off-by to mean that the contribution was created in whole or in part by you and that your contribution is not subject to copyright protections.

### 4. DCO Text

The full text of the DCO is included below and is available online at [developercertificate.org](https://developercertificate.org):

```txt
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.
1 Letterman Drive
Suite D4700
San Francisco, CA, 94129

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.

Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```
