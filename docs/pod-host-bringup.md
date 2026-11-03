# Pod host bring-up — blank hardware to pod-ready host

[`partner-run-guide.md`](partner-run-guide.md) starts from "a Linux host you control" with the
prerequisites already in place. This guide gets you there from nothing: a blank machine, no OS,
none of the tools installed. It ends at a checklist; when every row passes, switch to the run
guide and never look back here.

Two parts:

1. **Any Linux host** — the prerequisites and the encrypted state volume, distro-agnostic.
2. **Worked example: Raspberry Pi 5** — flashing, first boot, and finding the machine on the
   wire, in enough detail to repeat without guesswork.

If your host already runs Linux and you administer it comfortably, skip the worked example.

## What "pod-ready" means

The run guide assumes all of this. Each row has a check that must pass:

| Requirement | Check |
|---|---|
| 64-bit Linux host you control | `uname -m` prints `aarch64` or `x86_64` |
| Docker Engine + compose plugin | `docker compose version` prints a version |
| `envsubst` | `envsubst --version` prints a version |
| `goat` binary on `PATH` | `goat --version` prints a version |
| Your goatnet's CA root file on the host | `ls <ca-id>.pem`, or `<prefix>-goat-cli-ca.pem` inside your bundle tarball (else fetch after the mesh join, like the goat binary) |
| Mesh client installed | `netbird version` prints a version (zagros sandbox path) |
| LUKS-backed state volume | `findmnt -n /var/lib/goat-moon` shows a `/dev/mapper/...` source |
| This repo cloned on the host | `ls host/first-boot.sh` from the clone root |
| Outbound reach for image pulls | `tests/check-images-public.sh` passes |

The hostname should be the handle you were assigned at onboarding (the name on your
`<handle>.cbor`), so the machine on the wire matches the record of the machine that enrolled.

## Part 1 — any Linux host

Commands below are for Debian/Ubuntu. On another distro, substitute your package manager; the
requirement is the tool, not the package name.

### Docker + compose plugin

Install Docker Engine with the compose *plugin* (the `docker compose` subcommand), per
[docs.docker.com/engine/install](https://docs.docker.com/engine/install/). The convenience
script works on most distros:

```sh
curl -fsSL https://get.docker.com | sudo sh
docker compose version        # must print a version
```

The repo's scripts and docs invoke compose as `docker compose` (the plugin). The legacy
standalone `docker-compose` binary also works if you already have it, but nothing here requires
it.

### envsubst

```sh
sudo apt-get install -y gettext-base     # provides envsubst
```

### Mesh client (zagros sandbox path)

Stock NetBird, from the official installer:

```sh
curl -fsSL https://pkgs.netbird.io/install.sh | sudo sh
netbird version
```

Install only. Do **not** run `netbird up` yet: the setup key from your bundle is single-use, and
the run guide tells you when to spend it.

**Reusing hardware that already has a NetBird identity?** `moon_pod_setup.sh`'s mesh-join step
only checks whether *any* peers are currently connected, not which identity they belong to - a
box already enrolled on this or another goatnet (a prior role, a different pod, an old test)
will report itself as "already joined" and silently skip spending your new setup key, leaving
the host on its **old** identity with the **old** mesh groups. There is no error; `netbird
status` just keeps showing the old FQDN. Confirm which identity is actually active before
trusting a "joined" result:

```sh
netbird status | grep -E 'FQDN|NetBird IP'
```

If that is not the identity your bundle expects, force a clean re-enrollment: stop the service,
move its persisted state aside (this discards the old peer's local key - the old peer entry
itself is cleaned up mesh-side separately, e.g. `goat machine revoke` if it was a goat-enrolled
machine), then bring it back up before spending the new setup key.

```sh
sudo netbird down
sudo systemctl stop netbird
sudo mv /var/lib/netbird/default.json /var/lib/netbird/default.json.bak   # path is per-profile;
                                                                            # "default" unless you use profiles
sudo systemctl start netbird
```

NetBird before 0.52 has no profiles and keeps this state in `/etc/netbird/config.json`; move that
file aside instead (`netbird version` tells you which you have).

(The production path replaces stock NetBird with `goat-clientd`, which arrives with your
production onboarding material; see
[`goat-client-v02-contract.md`](goat-client-v02-contract.md). On the sandbox you do not need it,
and `first-boot.sh` skips its step when it is absent.)

### goat CLI

The `goat` binary arrives with your onboarding material (linux-amd64 / linux-arm64). Put it on
`PATH`:

```sh
sudo install -m 755 goat /usr/local/bin/goat
goat --version
```

**Fetching the binary for the host's architecture.** Match the binary to the *host* you are
building, not the workstation you flashed from — an x86-64 workstation preparing an arm64 Pi
needs the arm64 build.

The get surface (`get.<goatnet>`) is **mesh-only**, like every goatnet surface: its name only
resolves through the mesh DNS. The pod host is not on the mesh at this point (the run guide
spends the setup key later), so fetching from the pod host here fails — and it fails
confusingly: the off-mesh lookup falls through to your LAN's DNS search domain, a wildcard
resolver answers with some local address, and the TLS handshake dies against the wrong box. A
resolution to a private LAN address, or to the name with your LAN's search domain appended, is
the off-mesh signature — not a get-surface outage.

Fetch on your **already-onboarded workstation** instead (it is on the mesh), then copy the
binary over with the repo tree, the same way the next section copies the repo:

```sh
# on the workstation, on the mesh:
BASE=https://get.<goatnet>              # e.g. get.zagros.example
curl -fsSLO "$BASE/goat-linux-arm64"                  # or goat-linux-amd64 for an x86-64 host
curl -fsSLO "$BASE/goat-linux-arm64.sha256"
scp goat-linux-arm64 goat-linux-arm64.sha256 <user>@<pod-host>:

# on the pod host:
sha256sum -c goat-linux-arm64.sha256                  # must print: goat-linux-arm64: OK
sudo install -m 755 goat-linux-arm64 /usr/local/bin/goat
goat --version
```

Alternatively, defer this whole step: the run guide's step 1 joins the pod host to the mesh,
and the fetch works from the pod host itself after that. If you script this part, either fetch
on the workstation or order the goat fetch **after** the mesh join — never between NetBird
install and `netbird up`.

Ordering after the join is necessary but not sufficient: `netbird up` returns when the
management connection is up, and mesh DNS applies asynchronously a few seconds later. A fetch
issued straight after `netbird up` still races DNS and falls through to the LAN resolver. And
"does the name resolve" is not a valid readiness gate — a wildcard LAN resolver answers with a
local address and the gate passes on the wrong answer. Ask the tool that knows: `netbird
status` reports its nameservers as Available once mesh DNS is actually applied. Wait on that,
then assert the name resolves to a **mesh address** — NetBird assigns from the CGNAT block
100.64.0.0/10 (100.64.0.0 through 100.127.255.255, not just 100.64.x.x):

```sh
for _ in $(seq 1 30); do
  netbird status | grep -Eq 'Nameservers: [1-9][0-9]*/[1-9][0-9]* Available' && break
  sleep 1
done
getent hosts "get.<goatnet>" | grep -Eq '^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.' \
  || { echo "mesh DNS not serving get.<goatnet>" >&2; exit 1; }
```

The download keeps the arch-suffixed name until it lands on `PATH`: the `.sha256` file names
`goat-linux-arm64`, so `sha256sum -c` looks for that exact filename in the working directory.

### Your goatnet's CA root

`goat` ships with no goatnet built in: it verifies your bundle only against a CA root you add
yourself. Check your bundle tarball first: it carries the root as `<prefix>-goat-cli-ca.pem`
beside the `.cbor` when the goat side configured it, and then there is nothing to fetch. If it
does not, the root is a public-key `.pem` served next to the binary, at `$BASE/ca-roots/` — a
page listing each root with its CA-ID and fingerprint. Fetch the one for your goatnet in the
same trip as the binary (it is mesh-only for the same reason) and copy it to the pod host:

```sh
# on the workstation, on the mesh — <ca-id> is the CA your bundle is signed by:
curl -fsSLO "$BASE/ca-roots/<ca-id>.pem"
scp <ca-id>.pem <user>@<pod-host>:
```

Only fetch it here. Adding it to the pod's trust store happens in the run guide
([Trust your goatnet's CA root](partner-run-guide.md#trust-your-goatnets-ca-root)), because the
trust store lives on the state volume and the command has to name it — a plain `goat ca add`
puts the root where `first-boot.sh` never looks.

### This repo

Clone this repository:

```sh
git clone https://github.com/usareur-af/zagros-moon-pod.git
cd zagros-moon-pod
```

If the pod host itself cannot reach GitHub, clone on your workstation and copy the tree over:

```sh
git -C zagros-moon-pod archive HEAD | ssh <user>@<pod-host> 'mkdir -p zagros-moon-pod && tar -x -C zagros-moon-pod'
```

### The LUKS state volume

The pod's state dir (`/var/lib/goat-moon` by default) must live on a LUKS-encrypted volume:
your keys, your audit log, and the router's storage sit there, and encryption at rest is
sovereignty requirement 6a in [`partner-contract.md`](partner-contract.md). `first-boot.sh`
warns if you skip this; it does not stop you. Meeting the contract is on you.

Two ways to provide it. A **dedicated partition** is the clean option if your disk layout has
one to give. A **file-backed container** works on any host without repartitioning — including a
Pi flashed from a stock image, where the root filesystem grows to fill the disk on first boot
and leaves no free space for new partitions. The container costs one loop device and is
otherwise equivalent.

File-backed container, sized to your retention needs (audit logs are the growing part; see the
contract's retention requirement):

Working over SSH with no console (the normal case for an appliance)? Use the keyfile path — it
formats non-interactively and is also what boots the box unattended. `luksFormat` with a
console passphrase prompt hangs an SSH session with nothing to answer it.

```sh
sudo fallocate -l 20G /var/goat-moon.img       # instant; use dd if=/dev/zero on filesystems without fallocate
sudo dd if=/dev/urandom of=/root/goat-moon.keyfile bs=64 count=1
sudo chmod 0400 /root/goat-moon.keyfile
sudo cryptsetup luksFormat --batch-mode --key-file /root/goat-moon.keyfile /var/goat-moon.img
sudo cryptsetup open --key-file /root/goat-moon.keyfile /var/goat-moon.img goat-moon
sudo mkfs.ext4 /dev/mapper/goat-moon
sudo mkdir -p /var/lib/goat-moon
sudo mount /dev/mapper/goat-moon /var/lib/goat-moon
```

At a physical console and want the key never to touch the disk? Drop the keyfile and use the
interactive form — `sudo cryptsetup luksFormat /var/goat-moon.img` (prompts and sets a
passphrase), then `sudo cryptsetup open /var/goat-moon.img goat-moon`; the boot trade-off is in
"Unlock at boot" below.

For a dedicated partition, replace the image file with the partition device in `luksFormat` and
skip the `fallocate`.

**Unlock at boot — decide deliberately.** A LUKS volume needs unlocking every boot, and the two
options trade security against availability:

- **Passphrase at the console.** Strongest: the key never touches the disk. But a headless box
  that loses power stays down until someone attends it. Wrong default for an appliance in a
  rack. If you choose it anyway, keep Docker from starting the pod before the volume is
  unlocked: the compose services are `restart: unless-stopped`, so on boot Docker starts first,
  creates plain directories where the state files should be, and the router crash-loops against
  them — mask the stack at boot or add a systemd ordering dependency on the mount, and unlock
  before starting it.
- **Keyfile on the root filesystem.** The box comes back up unattended. The honest cost: anyone
  who can read your root filesystem can read the keyfile, so this protects the state volume
  against the *disk or image leaving your custody separately*, not against root on the running
  host. For most pod deployments that is the threat the contract cares about, and it is the
  setup most partners run.

Make the keyfile boot-persistent — register it in `crypttab` + `fstab` so the volume unlocks
and mounts on every boot without a hand:

```sh
echo 'goat-moon /var/goat-moon.img /root/goat-moon.keyfile luks' | sudo tee -a /etc/crypttab
echo '/dev/mapper/goat-moon /var/lib/goat-moon ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
```

`nofail` keeps a failed unlock from dropping boot into emergency mode — which also means a
boot where the unlock fails (keyfile deleted, image moved) comes up **without** the mount, and
Docker then creates plain directories at `/var/lib/goat-moon` and crash-loops the router,
exactly the hazard described under the passphrase option, just silent. The same mitigations
apply (mask the stack at boot, or order it after the mount), and the reboot check below is the
guard: if `findmnt` shows the wrong device, fix the unlock before starting the stack.

If you formatted with a **console passphrase** above (no keyfile yet), create the keyfile now
and add it as a second unlock credential before those two lines, so the box still boots
unattended while your passphrase stays a recovery credential:

```sh
sudo dd if=/dev/urandom of=/root/goat-moon.keyfile bs=64 count=1
sudo chmod 0400 /root/goat-moon.keyfile
sudo cryptsetup luksAddKey /var/goat-moon.img /root/goat-moon.keyfile   # prompts for the passphrase once
```

Verify the whole chain survives a reboot before calling it done:

```sh
sudo reboot
# after it returns:
findmnt -n /var/lib/goat-moon     # expect /dev/mapper/goat-moon
```

### Image reachability

The pod's images are public by design. Confirm your network path can pull them, without needing
the Docker daemon:

```sh
tests/check-images-public.sh
```

If this fails, fix egress (proxy, firewall) before the run guide; compose will hit the same
wall later with a worse error message.

### Firewall / egress ports

Behind a corporate firewall, open these outbound before anything else — every one of them
presents as a hang or a silent failure, not a clean error:

| Direction | Port | For |
|---|---|---|
| outbound | TCP 443 | NetBird management + registries (ghcr.io, package installs) |
| outbound | UDP 51820 | WireGuard (the mesh's data path; falls back to relays over 443 if blocked, slower) |

Zenoh's ports (TCP 7447 TLS, UDP 7448 QUIC) ride **inside** the WireGuard tunnel and never
appear at your perimeter — do not ask a firewall admin to open them; they will find no such
traffic to allow.

## Part 2 — worked example: Raspberry Pi 5

Built against: Raspberry Pi 5, booting Ubuntu Server 24.04 preinstalled arm64
(`ubuntu-24.04.x-preinstalled-server-arm64+raspi.img.xz`), from either an SD card or an NVMe
drive on a HAT. The pod's images ship arm64 builds, so nothing else changes.

You need: the Pi, its official PSU, ethernet, an SD card **or** an NVMe HAT, and a workstation
to flash from.

The PSU is load-bearing: a Pi 5 with an NVMe HAT needs the official 27 W (5 V / 5 A) supply.
An underpowered supply does not fail cleanly — it presents as random hangs or reboots under
disk or container load while everything looks fine at idle. If the machine dies under load,
check before debugging anything else: `sudo dmesg | grep -i voltage` (look for "Undervoltage
detected!") or `vcgencmd get_throttled` (anything other than `throttled=0x0`).

### Flash the image

**SD card:** write the image with Raspberry Pi Imager or `dd` from your workstation, as with
any Pi. Then continue at "Author the first-boot config".

**NVMe on a HAT** (no removable media): the Pi's bootloader can export the NVMe to your
workstation as a USB mass-storage device.

1. Install the export tool on the workstation: `rpiboot`, from the `rpiboot` package where your
   distro has one, else [github.com/raspberrypi/usbboot](https://github.com/raspberrypi/usbboot).
2. Disconnect Pi power. Hold the Pi's power button; while holding it, connect USB-C from the
   workstation to the Pi's USB-C port. Release once the workstation enumerates a Broadcom
   device (`lsusb -d 0a5c:` shows it; empty means the button timing missed — pull the cable and
   retry).
3. Export the drive and find it:

```sh
sudo rpiboot -d /usr/share/rpiboot/mass-storage-gadget64
sleep 5; lsblk -o NAME,SIZE,TYPE,TRAN,RM,MODEL
```

The Pi's NVMe appears as a new disk with TRAN `usb` (typically `/dev/sda` on a workstation
whose own disk is NVMe). Nothing new within ~30 s means the gadget did not attach: power-cycle
the Pi and repeat from step 2.

4. **Identify the target beyond doubt before writing.** `dd` to the wrong node destroys the
   workstation. The target must be the USB-transport disk whose size and model match the Pi's
   drive, and it must not be the disk your root filesystem is on (`findmnt -n -o SOURCE /`).
   When in doubt, unplug it and watch which row disappears.

```sh
IMG=ubuntu-24.04.4-preinstalled-server-arm64+raspi.img.xz
sha256sum -c --ignore-missing SHA256SUMS                   # verify the download first
sudo sh -c "xzcat $IMG | dd of=/dev/sdX bs=4M status=progress conv=fsync"
sudo partprobe /dev/sdX; sleep 3
lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/sdX
```

Expect two partitions: `system-boot` (vfat) and `writable` (ext4).

A note on power: the workstation's USB-C powers the bootloader and the export gadget only. Every
real boot needs the PSU.

### Author the first-boot config

Ubuntu's preinstalled image reads cloud-init config from the `system-boot` partition. Mount it
and replace `user-data` (keep the stock file for diffing):

```sh
sudo mkdir -p /mnt/pi-boot && sudo mount /dev/sdX1 /mnt/pi-boot
sudo cp /mnt/pi-boot/user-data /mnt/pi-boot/user-data.stock
```

The shape that works:

```yaml
#cloud-config
hostname: <your-handle>          # the handle from your onboarding
manage_etc_hosts: true

ssh_pwauth: false

users:
- default
- name: pod
  gecos: Pod operator
  groups: [adm, sudo]
  shell: /bin/bash
  lock_passwd: true
  sudo: "ALL=(ALL) NOPASSWD:ALL"
  ssh_authorized_keys:
  - <contents of your .pub key>
```

Pick a username that is not an existing system group on the image. Debian and Ubuntu ship
legacy groups (`operator`, `staff`, `sys`, ...); naming your user after one makes cloud-init's
`useradd` collide with the group, which aborts the whole users module — the account is never
created and first SSH fails `Permission denied (publickey)`. If you must reuse such a name, add
`primary_group: <name>` explicitly. `pod` is safe.

Leave networking at the image default (DHCP on ethernet).

Finish clean, or the write is not actually on the disk:

```sh
sync
sudo umount /mnt/pi-boot
```

Unplug USB-C, connect PSU and ethernet, power on.

### Find it on the wire

First boot takes ~90 s (cloud-init plus growing the root filesystem to fill the drive). The
reliable way to find a fresh machine is an ARP diff, not a MAC-prefix filter — Pi 5s answer on
MAC ranges outside every published Raspberry Pi OUI list, so a filtered scan returns nothing
while the machine sits there answering.

No LAN to plug into? Your workstation can be the network: put its wired port in
connection-sharing mode (NetworkManager: a profile with `ipv4.method shared`) and cable the
machine directly. The workstation serves DHCP and routes the machine out its own uplink, which
also covers the package installs below.

```sh
sudo apt-get install -y arp-scan     # on the workstation; rarely preinstalled
# before powering on, from a workstation on the same segment:
sudo arp-scan --localnet | sort > /tmp/before
# power on, wait ~90 s, then:
sudo arp-scan --localnet | sort | comm -13 /tmp/before -
```

The new row is the Pi. Confirm by logging in, not by MAC. DHCP leases move across reboots:
re-resolve the address every session rather than writing it into anything, and clear a stale
host key with `ssh-keygen -R <ip>` instead of fighting it.

### First login and health check

```sh
ssh pod@<ip> \
 'echo "hostname:   $(hostname)"
  echo "os:         $(. /etc/os-release; echo $PRETTY_NAME)"
  echo "rootfs:     $(df -h / | awk "NR==2{print \$2\" total, \"\$4\" free\"}")"
  echo "cloud-init: $(cloud-init status | head -1)"'
```

Read the rootfs line: still ~3.4 GB total means the first-boot grow never ran and cloud-init is
suspect (`sudo cat /var/log/cloud-init.log` on the Pi). The full drive size means first boot
completed.

`Permission denied (publickey)` on a freshly flashed Pi is almost always the users-module
collision above, not a key problem.

### Finish the checklist

Run Part 1 on the Pi (Docker, envsubst, NetBird, `goat`, the LUKS volume, the repo clone), then
verify every row of the pod-ready table.

## Next

[`partner-run-guide.md`](partner-run-guide.md) — join the mesh, fill your profile, run
`first-boot.sh`, verify data flows.
