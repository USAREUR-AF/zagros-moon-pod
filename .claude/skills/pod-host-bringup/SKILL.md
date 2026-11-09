---
name: pod-host-bringup
description: Use when preparing hardware to run the moon-pod - flashing a Raspberry Pi or readying any Linux host, installing Docker, goat, NetBird, envsubst, or OpenSSL, creating the LUKS state volume, or when a fresh host cannot be found on the network, refuses SSH, or has no internet. Triggers - "set up the pi", "flash a pod host", "prepare a host for the pod", "install the prerequisites", "pod-ready checklist".
---

# Pod host bring-up

Drive [docs/pod-host-bringup.md](../../../docs/pod-host-bringup.md) interactively: blank
hardware to a host that passes the pod-ready checklist. The doc is the source of truth for
every command; this skill sequences it and gates the dangerous step.

Do NOT join the mesh or run `first-boot.sh` here. That is `pod-standup`, and it needs the
bundle. This skill needs no credentials at all.

## Sequence

1. **Route by starting point.** Host already runs Linux: doc Part 1 only. Blank Raspberry Pi:
   doc Part 2 first, then Part 1 on the Pi. Other blank hardware: install any 64-bit Linux
   server OS by its own docs, then Part 1.
2. **Flashing (Part 2): the destructive-write gate.** Before ANY `dd`, print the full
   `lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL` output, state which device you believe is the
   target and why (USB transport, size, model), confirm it is not the workstation's root disk
   (`findmnt -n -o SOURCE /`), and get an explicit yes from the user naming that device. No
   confirmation, no write. Never infer the target from "it is usually /dev/sda".
3. **First boot (Part 2):** find the machine by ARP baseline diff, never by MAC prefix. Verify
   cloud-init completed and the root filesystem grew before blaming keys or the network.
4. **Prerequisites (Part 1):** install in doc order. Verify each with its check command before
   moving on; a failed check is a stop, not a note.
5. **LUKS volume (Part 1):** ask the user to choose the unlock policy (passphrase vs keyfile);
   the doc states the tradeoff. Verify with a real reboot, not by inspection.
6. **Finish:** run every row of the doc's pod-ready checklist and show the results. All rows
   pass: hand off to `pod-standup`. Any row fails: fix it now; the run guide assumes all of
   them.

## Failure routing

| Symptom | Where |
|---|---|
| No Broadcom device on `lsusb`, no `/dev/sdX` appears | doc Part 2, flash steps 2-3 |
| First SSH: `Permission denied (publickey)` | doc Part 2, the users-module collision note |
| Machine not found on the network | doc Part 2, "Find it on the wire" |
| `git clone` fails asking for a username | doc Part 1, "This repo" - access is per-GitHub-user; clone on the workstation and copy over |
| No LAN or DHCP for the machine | doc Part 2, "Find it on the wire" - workstation connection-sharing note |
| `tests/check-images-public.sh` fails | egress problem on this network; fix before continuing |
| `/var/lib/goat-moon` not on `/dev/mapper/...` after reboot | doc Part 1, crypttab/fstab lines |

## Rules

- The hostname is the handle from the user's onboarding. Ask for it before authoring
  cloud-init; do not invent one.
- Never write secrets, slot ids, or the user's handle into this repo or this skill.
