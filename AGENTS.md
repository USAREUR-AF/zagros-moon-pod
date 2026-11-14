# AGENTS.md

Instructions for AI coding agents, and a short version for anyone working here. [CONTRIBUTING.md](CONTRIBUTING.md) is the full process.

## What this repository is

zagros-moon-pod is the moon-pod: a small software bundle that a partner organization runs on its own hardware to exchange data in both directions with a [goat](https://github.com/USAREUR-AF/goatcore) data fabric. It holds a Zenoh router, an audit sink, host scripts, client examples in several languages, and an optional SPIRE overlay. The `zagros` profile is the sandbox; `profiles/production/` is a documented placeholder.

## Layout

| Path | What |
|---|---|
| `moon_pod_setup.sh` | bring-up, stand-up and verify, as one menu |
| `compose/` | the router and audit sink, and the SPIRE overlay |
| `host/` | first-boot script, router configuration template, service examples |
| `profiles/` | per-environment values that the join bundle does not carry |
| `clients/`, `examples/` | connection code and worked publish/subscribe examples |
| `spire/` | SPIRE server, agent and helper configuration |
| `tests/` | the local test scripts that CI runs |
| `docs/` | the partner contract, architecture, router configuration, run guide |
| `.claude/skills/` | agent skills: `pod-host-bringup`, `pod-standup`, `pod-verify` |

## Before you push

The workflows in `.github/workflows/` run these; most need Docker:

```bash
bash tests/audit-sink-local.sh
bash tests/fabric-peer-identity-local.sh
bash tests/router-forwarding-local.sh
bash tests/check-images-public.sh
```

The Compose stack, host scripts and templates hold no value that belongs to one environment. Every such value comes at run time from the signed join bundle or from the active profile under `profiles/`.

## Rules

1. **Nothing internal.** No link or path into a private repository, no internal hostname, mesh address, cloud account name or provisioning playbook, and no secret of any kind. The full list is in [CONTRIBUTING.md](CONTRIBUTING.md).
2. **Commits.** Conventional Commits subject (`fix(<component>): …`). Every commit is signed off (`git commit -s`, the DCO) and signed with a key GitHub verifies. The organization's required check `verified-commits` refuses a pull request that holds an unverified commit.
3. **Vulnerabilities** go through [SECURITY.md](SECURITY.md), never a public issue.

The contribution guide for goat as a whole is [goatcore CONTRIBUTING.md](https://github.com/USAREUR-AF/goatcore/blob/main/CONTRIBUTING.md).
