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
| 4. Round-trip | `sudo docker stop goat-moon-zenoh-router`, then `sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat pub '<slot>/test/ping' --payload-file /tmp/ping` and `sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat flow '<slot>/test/ping' --since 5m`, then `sudo docker start goat-moon-zenoh-router` | flow's audit row: `ok — 1 event(s)` |
| 5. Doctor timer | `cat /var/lib/goat-moon/doctor/status.json`; check its timestamp advances across 60s | fresh status, no `status.json.last-fail` |

Step 4 stops the router on purpose: the fabric allows exactly one transport per pod identity
(the slot cert pins the session ZID), and the running router holds that transport. A pub/sub
under the same identity while the router is connected is refused with `MAX_LINKS` — and an
occasional success with the router up is the same collision won by luck during a router
reconnect, so it proves nothing. The confirmation reads the audit tail (`goat flow --since`)
rather than a live `goat sub`: the fabric does not replay past events to a subscriber, so a
sub started after the pub exits prints nothing — and a concurrent sub under the pod identity
is the same MAX_LINKS collision. Restarting the router after step 4 is part of the step —
and if any command in step 4 wedges or errors, run `sudo docker start goat-moon-zenoh-router`
FIRST, then debug; never leave the pod router stopped while investigating.

A pod is "up" when all five pass. Report which step failed and what it printed; never
summarize a failure as "network issues".

## Symptom routing

| Symptom | Go to |
|---|---|
| `zenoh open failed … reason MAX_LINKS` | your own pod router holds the identity's single fabric transport — rerun step 4 with the router stopped; if the router is already stopped, an earlier goat session is still reaping (~seconds) |
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
