---
name: pod-verify
description: Use when checking whether a running moon-pod is healthy or diagnosing one that is not - goat doctor failures, a container missing or restarting, a publish that seems to vanish, a subscription receiving nothing, image pull failures, or the mesh flapping. Triggers - "is the pod up", "verify the pod", "nothing arrives", "doctor fails", "publish disappeared", "container keeps restarting".
---

# Pod verify

Run the verification flow from
[docs/partner-run-guide.md](../../../docs/partner-run-guide.md) (Verify and Trouble sections)
and route failures to the doc that owns them. The docs are the source of truth; this skill is
the order to check things in.

## First principle: report what the evidence proves

Publishes outside the slot ID are silently denied by design, but a missing catalog update is
not proof of denial. Refused, throttled, timed-out, missing, or unreachable evidence is
**Not verified** with the cause named. Never give a POD token operator audit access.

## The verification command

Run `sudo bash moon_pod_setup.sh` and choose Part 3. Preserve the overall `Verified`,
`Not verified`, or `Failed` result and the delivery outcome: `Publish failed`, `Not delivered`,
`Not verified`, `Local only`, or `Delivered`. The mesh passes only with the exact management
state and peers greater than zero. Delivery baselines both counts, uses the fixed
`<slot>/test/ping` key with a unique payload nonce through the running local router, and treats
the catalog as aggregate slot evidence.

Part 3 never stops or starts the router. Report each
verdict and its printed cause; do not collapse them into “network issues” or “POD verified.”

## Symptom routing

| Symptom | Go to |
|---|---|
| `zenoh open failed … reason MAX_LINKS` | a host-side `goat pub` or `goat sub` is competing with the running router for the pod identity; use the local-router client path in step 4 instead |
| Local audit count rises but catalog count does not | local delivery worked but fabric delivery is not confirmed; retain the key and timestamp and report it to the goat-side operator |
| `fabric router certificate name changed` | first-boot stopped before rendering. The goat-side operator confirms the new name through the trusted onboarding channel; the partner sets the confirmed `ZENOH_FABRIC_CERT_CN`, re-runs, and verifies the restart |
| New router config was rejected; previous config is running | service was rolled back but the run failed. Check profile inputs, retain the displayed logs, correct the cause, and re-run |
| Rollback refused after an identity change | leave the router stopped. The goat-side operator confirms the intended POD and fabric identities; correct the bundle or profile and re-run. Never restore the saved file by hand |
| Delivery is `Not verified` | follow the printed next step; share the cause and UTC test time if it persists |
| Delivery is `Local only` | share the printed key, nonce, and UTC test time; do not infer an ACL denial |
| Publish vanishes / sub receives nothing inside the slot | [docs/router-config.md](../../../docs/router-config.md), ACL troubleshooting ladder |
| Doctor router check fails | run-guide Trouble: mesh up? bundle expired? (`goat profile show`) |
| Image pull failure | `tests/check-images-public.sh` from the repo root; egress problem if it fails |
| Container restarting | `docker logs <name>`; config render errors point at [docs/router-config.md](../../../docs/router-config.md) |
| Mesh disconnected / flapping | `netbird status -d`; the pod cannot be healthier than its mesh |
| Expecting inbound data, nothing on `INBOUND_NAMESPACE` | bilateral grant may not exist yet; that is a question for the goat side, not a pod fault |

## Rules

- Distinguish “Not verified” from “denied”; the catalog count is aggregate slot evidence, not a
  per-message receipt.
- Never "fix" a denial by publishing under a different namespace; the slot is the contract.
