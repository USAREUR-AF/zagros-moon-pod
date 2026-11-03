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
- **License.** Contributions are under Apache-2.0 (see [`LICENSE`](LICENSE)).

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
