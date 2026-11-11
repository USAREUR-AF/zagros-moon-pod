---
name: pod-standup
description: Use when a signed join bundle (<handle>.cbor) is in hand and the host passes the pod-ready checklist - joining the mesh, filling the profile, running first-boot.sh, or when first-boot fails partway or refuses to start. Triggers - "stand up the pod", "run first boot", "I have my bundle", "join the mesh", "first-boot failed", "PARTNER_NAMESPACE must be set".
---

# Pod standup

Drive the Bring-up path of
[docs/partner-run-guide.md](../../../docs/partner-run-guide.md): bundle in hand to a running
pod. The doc is the source of truth for every command; this skill sequences it and protects
the one non-repeatable step.

## Pre-flight (all of it, before anything runs)

1. Pod-ready checklist from
   [docs/pod-host-bringup.md](../../../docs/pod-host-bringup.md) passes on this host. Any
   failure: switch to `pod-host-bringup` first.
2. The bundle file exists, and lives OUTSIDE the repo clone (`.gitignore` blocks `*.cbor`, but
   do not rely on it).
3. The user has their onboarding response at hand: slot id, mesh management URL, setup key.

If item 2 or 3 fails, the goat side has not finished its part and this host is hard-blocked:
no seeded enrolment grant means no bundle, and without the bundle and slot id nothing below
can start. There is no local workaround, and a refused or silent enrolment state is the rail
working. Stop, have the user contact the goat side, and resume only when the package arrives.

## The one thing this skill exists to prevent

The mesh setup key is **single-use**. `netbird up` spends it. Run it exactly once, only after
the whole pre-flight passes, with the URL and key the user provides. A failed join after the
key is spent is a re-issue conversation with the goat side, not a retry loop. Everything else
in this flow is re-runnable; this is the step to be slow on.

## Sequence

1. Profile fill, per the doc's "Fill your profile": `cp -r profiles/zagros profiles/zagros-local`,
   set `PARTNER_NAMESPACE` to the slot id. Confirm `git status` shows the
   copy as ignored.
2. Mesh join (the single-use step above). Verify: `netbird status` shows Connected.
3. Trust the goatnet's CA root, per the doc's "Trust your goatnet's CA root" (use the tarball's
   `<prefix>-goat-cli-ca.pem` if it has one, else the goatnet's `get.` page):
   `sudo GOAT_PROFILE_DIR=/var/lib/goat-moon/goat-cli goat ca add <ca-id>.pem`. The
   `GOAT_PROFILE_DIR` is not optional: without it the root lands in `~/.goat`, which first-boot
   never reads. Have the user confirm the printed fingerprint against one from the goat side.
4. `sudo ./host/first-boot.sh zagros-local /path/to/<handle>.cbor`. Watch the numbered steps;
   on the ZAGROS sandbox the goat-clientd step reporting skipped is normal, not a failure
   (stock NetBird is the sandbox mesh client).
5. Hand off to `pod-verify` for the health ladder. Do not declare the pod up from
   first-boot's exit code alone.

## When first-boot fails

It is `set -e`: it stops at the first broken step and names it. Fix the named thing and re-run;
it is idempotent (re-renders config, re-applies compose, rotates the profile if one exists).

| Message | Cause, owner, and next step |
|---|---|
| `required tool not found on PATH: ...` | pod-ready checklist was not actually green |
| `no such profile: .../profiles/<name>/profile.env` | profile name typo, or the fill step was skipped |
| `PARTNER_NAMESPACE must be set in the profile` | the variable is unset or empty — `profiles/zagros-local/profile.env` lost the line, or the profile name given to first-boot does not match the copy you filled |
| `PARTNER_NAMESPACE still carries the CHANGE-ME placeholder` | `profiles/zagros-local/profile.env` was copied but the slot id was never filled in |
| `no CA root is trusted under ...`, `This machine trusts no CA roots`, or `does not trust that CA` | the pod's trust store lacks the goatnet's root — sequence step 3 was skipped, or the root was added without `GOAT_PROFILE_DIR` and sits in `~/.goat`. The bundle is fine and nothing was consumed; do NOT request a new one |
| `pod identity check failed: certificate CN is missing or unsupported` | the issued pod certificate has no supported CN; the goat-side operator reissues it with a CN using the documented character set, then the partner re-runs first-boot |
| `fabric identity check failed: the TLS endpoint has no supported host:port` | the bundle/profile endpoint is malformed; the goat-side operator corrects the endpoint in a new bundle, or the partner corrects a hand-validation fallback, then re-runs |
| `fabric identity check failed: the CA-verified mTLS handshake did not verify` | first-boot could not authenticate and identify the upstream router; the partner confirms NetBird and endpoint reachability, the goat-side operator confirms the endpoint certificate and CA, then the partner re-runs |
| `fabric identity check failed: router certificate CN has unsupported characters` | the router identity cannot be represented safely in the ACL; the goat-side operator corrects its certificate, then the partner re-runs |
| `fabric identity check failed: ZENOH_FABRIC_CERT_CN contains unsupported characters` | the configured pin cannot be represented safely in the ACL; the goat-side operator confirms a CN using the documented character set, then the partner corrects the active profile and re-runs |
| `fabric identity check failed: router CN does not match the configured pin` | the TLS pin and presented router CN differ; the goat-side operator confirms the current CN, then the partner corrects the active profile and re-runs |
| `fabric identity check failed: fabric router certificate name changed` | first-boot left the running router and applied config untouched. The goat-side operator confirms the new name through the trusted onboarding channel; the partner sets only that confirmed value as `ZENOH_FABRIC_CERT_CN` and re-runs |
| `fabric identity check failed: QUIC endpoint has no router certificate CN pin` | OpenSSL cannot inspect QUIC; the goat-side operator supplies the expected CN through the trusted onboarding channel, then the partner sets `ZENOH_FABRIC_CERT_CN` and re-runs |
| `fabric identity check failed: endpoint transport must be tls or quic` | the bundle/profile names an unsupported transport; the goat-side operator corrects the endpoint in a new bundle, or the partner corrects a hand-validation fallback, then re-runs |
| `fabric identity check failed: router and pod certificate CNs are identical` | the ACL cannot separate pod and router privileges; the goat-side operator issues distinct identities, then the partner re-runs. Never substitute the pod CN for the router CN |
| bundle expiry / activation-deadline error | lapsed bundle; ask the goat side for a fresh one, do not edit the bundle |
| `The new configuration was rejected.` followed by `The previous configuration is running again.` | first-boot restored the last healthy configuration and exited non-zero. The partner checks profile inputs and re-runs after correction; the goat-side operator owns a confirmed problem with the router template or the fabric endpoint |
| `The previous configuration was not restored because its saved certificate identities could not be verified` | rollback cannot prove which identities the saved file admits, so the router is stopped. The goat-side operator confirms the intended identities; the partner corrects the bundle or profile and re-runs. Never restore the saved file by hand |
| `The previous configuration was not restored because its POD or fabric certificate identity differs` | rollback would re-admit an old identity, so the router is stopped. The goat-side operator confirms the intended identities; the partner corrects the bundle or profile and re-runs. Never restore the saved file by hand |
| `router failed to load...` or `router did not become healthy...` with no rollback message | no verified last-known-good file was available, or its own restart failed. The partner retains the displayed logs; the goat-side operator investigates after profile inputs are checked |

## Rules

- Never paste the setup key, slot id, or bundle contents into files in this repo, commit
  messages, or this skill.
- Never edit `profiles/zagros/profile.env` (the tracked template); the fill happens only in the
  `-local` copy.
