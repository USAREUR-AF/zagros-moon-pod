---
name: pod-verify
description: Use when checking whether a running moon-pod is healthy or diagnosing one that is not - goat doctor failures, a container missing or restarting, a publish that seems to vanish, a subscription receiving nothing, image pull failures, or the mesh flapping. Triggers - "is the pod up", "verify the pod", "nothing arrives", "doctor fails", "publish disappeared", "container keeps restarting".
---

# Pod verify

Run the verification ladder from
[docs/partner-run-guide.md](../../../docs/partner-run-guide.md) (Verify and Trouble sections)
and route failures to the doc that owns them. The docs are the source of truth; this skill is
the order to check things in.

## First principle: silence is a verdict, not a bug

Publishes outside the pod's slot are **silently denied by design**. A publish that "succeeds"
with nothing arriving, or an empty subscription, is an ACL answer before it is a debugging
target. Check WHERE the data was published against the slot before touching any config.

## The ladder (in order, stop at the first failure)

| Step | Command | Pass looks like |
|---|---|---|
| 1. Mesh | `netbird status` | Connected |
| 2. Health | `sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat doctor --all` | cert + router checks green |
| 3. Containers | `sudo docker ps` | `goat-moon-zenoh-router` Up (`goat-moon-audit-sink` only with the opt-in `audit` profile) |
| 4. Real data path | Keep the router running. Note the slot's portal-catalog `publish_count`, publish one uniquely named message through `tls/127.0.0.1:7447` with the partner's normal application or a client under `clients/`, check `goat_audit_samples_total`, then refresh the catalog for up to three minutes | both the local audit count and slot catalog count rise |
| 5. Doctor timer | `cat /var/lib/goat-moon/doctor/status.json`; check its timestamp advances across 60s | fresh status, no `status.json.last-fail` |

Step 4 must exercise the local router. Stopping it and running `goat pub` directly against the
fabric bypasses the router ACL and cannot prove the partner data path. A local audit rise alone
proves only local delivery; without a catalog rise, fabric delivery is not confirmed. Leave the
router running and retain the test key and timestamp when handing an ambiguous result to the
goat-side operator.

A pod is "up" when all five pass. Report which step failed and what it printed; never
summarize a failure as "network issues".

## Symptom routing

| Symptom | Go to |
|---|---|
| `zenoh open failed … reason MAX_LINKS` | a host-side `goat pub` or `goat sub` is competing with the running router for the pod identity; use the local-router client path in step 4 instead |
| Local audit count rises but catalog count does not | local delivery worked but fabric delivery is not confirmed; retain the key and timestamp and report it to the goat-side operator |
| `fabric router certificate name changed` | first-boot stopped before rendering. The goat-side operator confirms the new name through the trusted onboarding channel; the partner sets the confirmed `ZENOH_FABRIC_CERT_CN`, re-runs, and verifies the restart |
| New router config was rejected; previous config is running | service was rolled back but the run failed. Check profile inputs, retain the displayed logs, correct the cause, and re-run |
| Rollback refused after an identity change | leave the router stopped. The goat-side operator confirms the intended POD and fabric identities; correct the bundle or profile and re-run. Never restore the saved file by hand |
| Publish vanishes / sub receives nothing inside the slot | [docs/router-config.md](../../../docs/router-config.md), ACL troubleshooting ladder |
| Doctor router check fails | run-guide Trouble: mesh up? bundle expired? (`goat profile show`) |
| Image pull failure | `tests/check-images-public.sh` from the repo root; egress problem if it fails |
| Container restarting | `docker logs <name>`; config render errors point at [docs/router-config.md](../../../docs/router-config.md) |
| Mesh disconnected / flapping | `netbird status -d`; the pod cannot be healthier than its mesh |
| Expecting inbound data, nothing on `INBOUND_NAMESPACE` | bilateral grant may not exist yet; that is a question for the goat side, not a pod fault |

## Rules

- Distinguish "no data" from "no access": the fabric refuses silently, so an empty result
  needs the ACL question answered before any debugging.
- Never "fix" a denial by publishing under a different namespace; the slot is the contract.
