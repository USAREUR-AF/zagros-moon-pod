#!/usr/bin/env bash
# moon_pod_setup.sh - bringup + standup + verify, all in one, one place to edit.
#
# Run ON the pod host (the Pi), FROM INSIDE the repo clone:
#   cd zagros-moon-pod && sudo bash moon_pod_setup.sh
#
# Merges pod-host-bringup.sh + pod-standup.sh + pod-verify.sh. The underlying
# commands (netbird, docker, goat, cryptsetup, first-boot.sh...) are UNCHANGED -
# this file only unifies config and wraps the 3 parts in an interactive menu.
#
# Opens a control-center menu: pick PART 1, 2, or 3, see exactly what it needs
# and whether you already have it (live checkmarks), then start it or back out.
# Nothing runs until you explicitly say so - no silent multi-minute polling.
#
# Re-runnable: every install step checks "is it already there / already
# running" before doing anything, exactly like the 3 source scripts did.
#
#   sudo NETBIRD_SETUP_KEY=<key> PARTNER_NAMESPACE=<slot> POD_ID=<id> CA_ROOT_PEM=<root.pem> \
#        EXPECTED_CA_FINGERPRINT=SHA256:<hex> bash moon_pod_setup.sh
#
# NETBIRD_SETUP_KEY is single-use - fill it only right before running, blank
# it again after (or pass via env instead of editing the file).

set -uo pipefail

# =============================================================================
#  CONFIG - the ONLY block you should ever need to touch. Used by all 3 parts.
# =============================================================================
GOATNET="${GOATNET:-your.goatnet.domain}"         # from your welcome package; the placeholder skips the goat download
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Under sudo, $HOME is root's home - resolve the real invoking user so bundle
# defaults below point at the account that actually received the tarball.
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"

LUKS_IMG="/var/goat-moon.img"
LUKS_KEYFILE="/root/goat-moon.keyfile"
LUKS_SIZE="20G"                                   # sized to your audit-log retention needs
STATE_DIR="/var/lib/goat-moon"
GOAT_PROFILE_DIR="${STATE_DIR}/goat-cli"          # used by goat CLI in Part 2 + Part 3

NETBIRD_MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-}"    # from your welcome package; the mesh management URL is never hardcoded here
NETBIRD_SETUP_KEY="${NETBIRD_SETUP_KEY:-}"        # single-use - see header; never leave a real key in this file

PROFILE_NAME="zagros-local"
SOURCE_PROFILE="zagros"
PARTNER_NAMESPACE="${PARTNER_NAMESPACE:-CHANGE-ME-zagros-uuid-slot}"   # your slot id, from your bundle; never commit a real one
POD_ID="${POD_ID:-moon-pod}"

# Bundle locations derive from POD_ID / PARTNER_NAMESPACE above - change those
# two, not these, unless your bundle really lives somewhere non-standard.
BUNDLE_TARBALL="${BUNDLE_TARBALL:-$REAL_HOME/${POD_ID}-bundle.tar.gz}"
BUNDLE_PATH="${BUNDLE_PATH:-$REAL_HOME/goat-bundle/${PARTNER_NAMESPACE}-goat-cli.cbor}"

# Your goatnet's CA root (a PUBLIC key .pem). goat ships with no goatnet built in, so the bundle
# cannot be verified until the pod trusts this root. Leave it blank and step 2.5 uses the
# <prefix>-goat-cli-ca.pem your bundle tarball carries beside the .cbor, when there is one;
# otherwise set it to a root fetched from https://get.<goatnet>/ca-roots/. Leave it blank too if
# you already ran 'sudo GOAT_PROFILE_DIR=<state>/goat-cli goat ca add <root.pem>' yourself.
CA_ROOT_PEM="${CA_ROOT_PEM:-}"

# The root's fingerprint as the goat side gave it to you, through a channel other than the one
# that brought the root ('goat ca ls' prints it: SHA256:<hex>). Set it and step 2.5 compares for
# you; leave it blank and step 2.5 shows the fingerprint and waits for you to type yes. Either
# way the pod trusts nothing until the two match.
EXPECTED_CA_FINGERPRINT="${EXPECTED_CA_FINGERPRINT:-}"

ROUND_TRIP_TIMEOUT=20                              # verify: seconds allowed for each pub / audit-tail attempt

# --- waiting / retrying knobs (only for waits WITHIN a part, not between them) -
MESH_WAIT_INTERVAL=3      ; MESH_WAIT_TRIES=10      # mesh connect:      3s x 10  = 30s
DOCKER_WAIT_INTERVAL=2    ; DOCKER_WAIT_TRIES=15    # docker daemon up:  2s x 15  = 30s
CONTAINERS_WAIT_INTERVAL=5; CONTAINERS_WAIT_TRIES=12 # containers up:    5s x 12  = 60s
# audit-tail ingestion is eventually consistent (a portal-side read, not a live subscription) -
# one immediate check right after a fresh publish is a coin flip, not a verdict. Retry a few
# times before concluding the event never arrived.
ROUND_TRIP_FLOW_TRIES=4   ; ROUND_TRIP_FLOW_RETRY_DELAY=5  # audit-tail retry:  4 tries, 5s apart
# the doctor timer's FIRST tick after being enabled can land up to OnBootSec(30s) + one full
# OnUnitActiveSec(60s) =~ 90s out. A fixed sleep-then-check (the old DOCTOR_TIMER_WINDOW=65)
# false-negatives on a timer Part 2 *just* installed. Poll with early exit instead: no slower
# on a system whose timer has been running a while, no false fail on one that hasn't ticked yet.
DOCTOR_TIMER_POLL_INTERVAL=5; DOCTOR_TIMER_TRIES=26 # doctor timer advance: 5s x 26 = 130s budget
# =============================================================================

# --- colors + status helpers --------------------------------------------------
GREEN=$(tput setaf 2 2>/dev/null || true); RED=$(tput setaf 1 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true); BLUE=$(tput setaf 4 2>/dev/null || true)
MAGENTA=$(tput setaf 5 2>/dev/null || true); CYAN=$(tput setaf 6 2>/dev/null || true)
BOLD=$(tput bold 2>/dev/null || true); DIM=$(tput dim 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)

ok()   { echo "${GREEN}${BOLD}[ OK ]${RESET} $*"; }
warn() { echo "${YELLOW}${BOLD}[WARN]${RESET} $*"; }
fail() { echo "${RED}${BOLD}[FAIL]${RESET} $*"; FAILED=1; }
info() { echo "${BLUE}${BOLD}[INFO]${RESET} $*"; }
step() { echo; echo "${MAGENTA}${BOLD}>> $*${RESET}"; }

banner() {
    local title="$1" color="${2:-$CYAN}" width=78
    local text=" $title "
    local pad_total=$(( width - 2 - ${#text} )); [ "$pad_total" -lt 0 ] && pad_total=0
    local pad_left=$(( pad_total / 2 )) pad_right=$(( pad_total - pad_total / 2 ))
    echo; echo "${color}${BOLD}$(printf '#%.0s' $(seq 1 $width))${RESET}"
    printf "%s#%*s%s%*s#%s\n" "${color}${BOLD}" "$pad_left" "" "$text" "$pad_right" "" "${RESET}"
    echo "${color}${BOLD}$(printf '#%.0s' $(seq 1 $width))${RESET}"; echo
}

hr() { local color="${1:-$CYAN}" width=78; echo "${color}$(printf '\xe2\x94\x80%.0s' $(seq 1 $width))${RESET}"; }

# mark_line "label" probe_fn [args...] - live checkmark line for status/gate screens.
mark_line() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "    ${GREEN}\xe2\x9c\x93${RESET} %s\n" "$label"
    else
        printf "    ${RED}\xe2\x9c\x97${RESET} %s\n" "$label"
    fi
}

press_enter() { echo; read -r -p "${DIM}Press Enter to return to the menu...${RESET} " _; clear; }

# Generic poll: wait_for "description" interval tries probe_fn [args...]
# (only used WITHIN a running part, for things the part itself just kicked off -
#  not for anything the user has to go fetch, that's what the menu gate is for)
wait_for() {
    local desc="$1" interval="$2" tries="$3"; shift 3
    local i=1
    while [ "$i" -le "$tries" ]; do
        if "$@" >/dev/null 2>&1; then
            echo; ok "$desc (ready after ~$(( (i - 1) * interval ))s)"; return 0
        fi
        printf "${CYAN}${BOLD}[WAIT]${RESET} %-55s try %d/%d (checking every %ss)\r" "$desc" "$i" "$tries" "$interval"
        sleep "$interval"; i=$((i + 1))
    done
    echo; warn "$desc - still not ready after $((tries * interval))s"; return 1
}

pause() { echo "${DIM}...giving things ${1}s to settle...${RESET}"; sleep "$1"; }

# --- probes (read-only where possible, used by both the parts and the menu) --
mesh_connected_probe()    { netbird status 2>&1 | grep -qi "Connected"; }
# Stricter than mesh_connected_probe: requires an actual connected PEER, not
# just "Management: Connected" (which comes up before any peer syncs). This
# is what pod-host-bringup.sh/pod-standup.sh used for their join-skip
# decision and pod-ready checklist - pod-verify.sh's own step 1 intentionally
# keeps the looser check, so that one is left alone.
mesh_peers_connected_probe() {
    local peers_line connected
    peers_line=$(netbird status 2>&1 | grep -i "Peers count:" | head -1)
    connected=$(echo "$peers_line" | grep -oE '[0-9]+' | head -1)
    [ -n "$connected" ] && [ "$connected" -gt 0 ]
}
docker_ready_probe()      { docker info >/dev/null 2>&1; }
containers_up_probe() {
    # "Up 2 minutes (unhealthy)" still contains "Up" - a container failing its
    # healthcheck must not count as up, or the whole ladder reports a sick pod green.
    # Gates on the router only: the audit sink waits for a healthy router before it starts,
    # and Part 3 reports it separately.
    local ps; ps=$(docker ps --format '{{.Names}}\t{{.Status}}' 2>/dev/null)
    echo "$ps" | grep "^goat-moon-zenoh-router" | grep "Up" | grep -qv "(unhealthy)"
}
bundle_probe() {
    [ -f "$BUNDLE_PATH" ] && return 0
    if [ -n "$BUNDLE_TARBALL" ] && [ -f "$BUNDLE_TARBALL" ]; then
        local dir; dir="$(dirname "$BUNDLE_PATH")"
        mkdir -p "$dir" && tar xzf "$BUNDLE_TARBALL" -C "$dir" 2>/dev/null && chmod 700 "$dir"
        [ -f "$BUNDLE_PATH" ] && return 0
    fi
    local found; mapfile -t found < <(find "$REAL_HOME" -maxdepth 5 -iname '*-goat-cli.cbor' -not -path "$REPO_DIR/*" 2>/dev/null)
    [ "${#found[@]}" -eq 1 ] && { BUNDLE_PATH="${found[0]}"; return 0; }
    return 1
}
# Read-only version for menu display - never extracts, just answers "is it there".
bundle_present_probe() {
    [ -f "$BUNDLE_PATH" ] && return 0
    [ -n "$BUNDLE_TARBALL" ] && [ -f "$BUNDLE_TARBALL" ] && return 0
    local n; n=$(find "$REAL_HOME" -maxdepth 5 -iname '*-goat-cli.cbor' -not -path "$REPO_DIR/*" 2>/dev/null | wc -l)
    [ "$n" -ge 1 ]
}

docker_and_compose_probe() { command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; }
netbird_installed_probe()  { command -v netbird >/dev/null 2>&1; }
goat_on_path_probe()       { command -v goat >/dev/null 2>&1; }
luks_mounted_probe()       { findmnt -n "$STATE_DIR" 2>/dev/null | grep -q '/dev/mapper/'; }
repo_found_probe()         { [ -f "$REPO_DIR/host/first-boot.sh" ]; }
netbird_key_set_probe()    { [ -n "$NETBIRD_SETUP_KEY" ]; }
mesh_or_key_probe()        { mesh_connected_probe || netbird_key_set_probe; }
# The profile exists once init has written its cert. The dir alone proves nothing: step 2.5's
# 'goat ca add' creates it before any profile does.
goat_profile_present_probe() { find "$GOAT_PROFILE_DIR" -name mtls.cert.pem -print -quit 2>/dev/null | grep -q .; }
# The pod's trust store lives UNDER the pod's profile dir ($GOAT_PROFILE_DIR/ca-roots), not in
# ~/.goat - a root added without GOAT_PROFILE_DIR is invisible to first-boot. Passes on a goat
# build that predates 'goat ca' (no such verb: that build still carries a compiled-in root).
ca_root_trusted_probe() {
    local out; out=$(GOAT_PROFILE_DIR="$GOAT_PROFILE_DIR" goat ca ls --json 2>/dev/null) || return 0
    ! echo "$out" | grep -qE '"count":[[:space:]]*0([^0-9]|$)'
}
# Read-only: is a *-goat-cli-ca.pem inside the tarball (so step 2.1 will unpack it beside the .cbor)?
tarball_ca_probe()         { [ -f "$BUNDLE_TARBALL" ] && tar tzf "$BUNDLE_TARBALL" 2>/dev/null | grep -q -- '-goat-cli-ca\.pem$'; }
# Mirrors step 2.5: a CA_ROOT_PEM that is set must exist, because step 2.5 never swaps in another
# root for it. The tarball check stands in for the .pem that step 2.1 has not unpacked yet.
ca_root_or_pem_probe() {
    ca_root_trusted_probe && return 0
    if [ -n "$CA_ROOT_PEM" ]; then [ -f "$CA_ROOT_PEM" ]; return; fi
    [ -f "${BUNDLE_PATH%.cbor}-ca.pem" ] || tarball_ca_probe
}

part1_ready_probe() {
    docker_and_compose_probe && netbird_installed_probe && goat_on_path_probe \
        && luks_mounted_probe && repo_found_probe
}
part2_done_probe() { [ -f "$BUNDLE_PATH" ] && containers_up_probe; }

netbird_up_if_needed() {
    # Idempotent join, identical semantics to both source scripts: never
    # re-run 'netbird up' if peers are already connected, so a re-run never
    # re-spends the key. Uses the stricter peers-count check (like the
    # original bringup/standup scripts), not just "daemon says Connected".
    if mesh_peers_connected_probe; then
        ok "netbird already joined, peers connected"
        return 0
    fi
    if [ -z "$NETBIRD_SETUP_KEY" ]; then
        warn "netbird not joined (no connected peers) and NETBIRD_SETUP_KEY not set - cannot join yet"
        return 1
    fi
    if [ -z "$NETBIRD_MANAGEMENT_URL" ]; then
        warn "NETBIRD_MANAGEMENT_URL not set - take it from your welcome package; it is never hardcoded in this repo"
        return 1
    fi
    warn "netbird not joined (no connected peers) - running 'netbird up' now (key will be spent)"
    if netbird up --management-url "$NETBIRD_MANAGEMENT_URL" --setup-key "$NETBIRD_SETUP_KEY" \
        --enable-rosenpass=false --rosenpass-permissive=false; then
        ok "netbird up succeeded (management: $NETBIRD_MANAGEMENT_URL)"
        NETBIRD_KEY_SPENT_THIS_RUN=1
    else
        fail "netbird up failed"
        return 1
    fi
    wait_for "netbird mesh connection" "$MESH_WAIT_INTERVAL" "$MESH_WAIT_TRIES" mesh_connected_probe
}

# Report a failed verify step without stopping the ladder - Part 3 now runs
# every check and summarizes pass/fail at the end instead of bailing early.
note_fail() {
    PART3_RESULT="fail"
    echo; echo "${RED}${BOLD}[FAILED] step $1${RESET}"; echo "$2"
}

# record "label" "PASS|FAIL" - appended to the Part 3 summary table.
record() { SUMMARY_LABELS+=("$1"); SUMMARY_STATUS+=("$2"); }

part_status_str() {
    local v="${!1}"
    case "$v" in
        "") echo "${DIM}not run this session${RESET}" ;;
        0)  echo "${GREEN}PASS${RESET}" ;;
        *)  echo "${YELLOW}HAD WARNINGS${RESET}" ;;
    esac
}

# #############################################################################
#  PART 1 / 3  --  HOST BRING-UP
# #############################################################################
run_part1() {
    banner "PART 1 / 3  --  HOST BRING-UP" "$CYAN"
    FAILED=0

    step "1.0  Host architecture"
    ARCH_UNAME=$(uname -m)
    case "$ARCH_UNAME" in
        aarch64) GOAT_ARCH="arm64"; ok "arch: $ARCH_UNAME (aarch64)" ;;
        x86_64)  GOAT_ARCH="amd64"; ok "arch: $ARCH_UNAME (x86_64)" ;;
        *) fail "arch: $ARCH_UNAME - not aarch64/x86_64"; GOAT_ARCH="" ;;
    esac

    step "1.1  Docker Engine + compose plugin"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "docker + compose plugin already present: $(docker compose version)"
    else
        warn "installing Docker via get.docker.com"
        if curl -fsSL https://get.docker.com | sh; then
            systemctl enable --now docker >/dev/null 2>&1 || true
            wait_for "docker daemon" "$DOCKER_WAIT_INTERVAL" "$DOCKER_WAIT_TRIES" docker_ready_probe
            if docker compose version >/dev/null 2>&1; then
                ok "docker installed: $(docker compose version)"
            else
                fail "docker installed but 'docker compose version' still fails"
            fi
        else
            fail "docker install script failed - check internet/egress"
        fi
    fi

    REAL_USER_FOR_DOCKER="${SUDO_USER:-}"
    if [ -n "$REAL_USER_FOR_DOCKER" ] && id "$REAL_USER_FOR_DOCKER" >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
        if id -nG "$REAL_USER_FOR_DOCKER" | grep -qw docker; then
            ok "$REAL_USER_FOR_DOCKER already in docker group"
        else
            usermod -aG docker "$REAL_USER_FOR_DOCKER" && ok "added $REAL_USER_FOR_DOCKER to docker group (re-login to take effect)"
        fi
    fi

    step "1.2  envsubst + OpenSSL"
    if command -v envsubst >/dev/null 2>&1; then
        ok "envsubst already present: $(envsubst --version | head -1)"
    else
        apt-get -o DPkg::Lock::Timeout=180 update -qq \
            && apt-get -o DPkg::Lock::Timeout=180 install -y -qq gettext-base \
            && ok "installed gettext-base (envsubst)" \
            || fail "failed to install gettext-base"
    fi
    if command -v openssl >/dev/null 2>&1; then
        ok "OpenSSL already present: $(openssl version)"
    else
        if apt-get -o DPkg::Lock::Timeout=180 update -qq \
            && apt-get -o DPkg::Lock::Timeout=180 install -y -qq openssl
        then
            ok "installed OpenSSL"
        else
            fail "failed to install OpenSSL"
        fi
    fi

    step "1.3  Mesh client - NetBird (install)"
    if command -v netbird >/dev/null 2>&1; then
        ok "netbird already installed: $(netbird version 2>&1 | head -1)"
    else
        if curl -fsSL https://pkgs.netbird.io/install.sh | sh; then
            ok "netbird installed: $(netbird version 2>&1 | head -1)"
        else
            fail "netbird install failed"
        fi
    fi

    step "1.4  Join the mesh (netbird up) - THE SINGLE-USE STEP"
    if ! command -v netbird >/dev/null 2>&1; then
        fail "netbird not installed - see step 1.3"
    else
        netbird_up_if_needed || warn "mesh not joined yet - will retry before Part 2 needs it"
    fi

    step "1.5  goat CLI (install/update, then verify)"
    pause 5
    CURRENT_SHA=""
    if command -v goat >/dev/null 2>&1; then
        CURRENT_SHA=$(sha256sum "$(command -v goat)" 2>/dev/null | awk '{print $1}')
    fi

    SOURCE_BIN=""; TMP=""
    if [ -n "$GOAT_ARCH" ] && [ -f "$REPO_DIR/goat-linux-${GOAT_ARCH}" ]; then
        SOURCE_BIN="$REPO_DIR/goat-linux-${GOAT_ARCH}"
        ok "found local goat binary: $SOURCE_BIN"
    elif [ -n "$GOAT_ARCH" ] && [ "$GOATNET" != "your.goatnet.domain" ]; then
        BASE="https://get.${GOATNET}"
        TMP=$(mktemp -d)

        RESOLVED_NAME=$(getent hosts "get.${GOATNET}" 2>/dev/null | awk '{print $2}')
        CURL_RESOLVE=()
        if [ -n "$RESOLVED_NAME" ] && [ "$RESOLVED_NAME" != "get.${GOATNET}" ] && [ "$RESOLVED_NAME" != "get.${GOATNET}." ]; then
            # Sending the goatnet hostname to a third-party resolver is egress the
            # operator did not ask for; ordinary search-suffix configs also trip this
            # heuristic. Off by default, opt in with GOAT_DOH_FALLBACK=1.
            DOH_IP=""
            [ "${GOAT_DOH_FALLBACK:-0}" = "1" ] && DOH_IP=$(curl -fsS -H 'accept: application/dns-json' \
                "https://1.1.1.1/dns-query?name=get.${GOATNET}&type=A" 2>/dev/null \
                | grep -oE '"data":"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | cut -d'"' -f4)
            if [ "${GOAT_DOH_FALLBACK:-0}" != "1" ]; then
                warn "local DNS for get.${GOATNET} resolves to '$RESOLVED_NAME' (possible search-domain rewrite) - skipping the public-DoH fallback by default; set GOAT_DOH_FALLBACK=1 to allow a one-off 1.1.1.1 lookup of this hostname"
            elif [ -n "$DOH_IP" ]; then
                warn "local DNS for get.${GOATNET} resolves to '$RESOLVED_NAME' (search-domain hijack) - pinning curl to $DOH_IP via public DoH"
                CURL_RESOLVE=(--resolve "get.${GOATNET}:443:${DOH_IP}")
            else
                warn "local DNS for get.${GOATNET} resolves to '$RESOLVED_NAME' and the DoH fallback also failed - continuing anyway"
            fi
        fi

        if curl -fsSL "${CURL_RESOLVE[@]}" -o "$TMP/goat-linux-${GOAT_ARCH}" "$BASE/goat-linux-${GOAT_ARCH}"; then
            if curl -fsSL "${CURL_RESOLVE[@]}" -o "$TMP/goat-linux-${GOAT_ARCH}.sha256" "$BASE/goat-linux-${GOAT_ARCH}.sha256" 2>/dev/null \
                && (cd "$TMP" && sha256sum -c "goat-linux-${GOAT_ARCH}.sha256" >/dev/null 2>&1); then
                ok "fetched goat from $BASE, checksum verified"
                SOURCE_BIN="$TMP/goat-linux-${GOAT_ARCH}"
            else
                # Never install what we can't verify: a binary that will hold fabric
                # credentials and run as root is exactly the wrong place to shrug off
                # a missing checksum.
                fail "fetched goat from $BASE but could not verify it (.sha256 missing or mismatch) - refusing to install an unverified binary. Fetch goat-linux-${GOAT_ARCH} and its .sha256 on an enrolled workstation and place both in $REPO_DIR, then re-run."
            fi
        else
            if [ -n "$CURRENT_SHA" ]; then
                warn "goat update check failed (couldn't download from $BASE) - keeping the currently installed goat"
            else
                fail "goat download failed from $BASE/goat-linux-${GOAT_ARCH} - get.${GOATNET} is mesh-only: join the mesh first (step 1.4), or fetch the binary on an enrolled workstation and place it in $REPO_DIR"
            fi
            echo "  diagnostic (curl -v, last 25 lines):"
            curl -v "${CURL_RESOLVE[@]}" -o /dev/null "$BASE/goat-linux-${GOAT_ARCH}" 2>&1 | tail -25 | sed 's/^/    /'
            echo "  DNS resolved get.${GOATNET} -> ${RESOLVED_NAME:-does not resolve}"
        fi
    elif [ -n "$CURRENT_SHA" ]; then
        warn "goat already installed but no update source configured - skipping update check"
    else
        fail "goat not installed - either put goat-linux-${GOAT_ARCH:-<arch>} in $REPO_DIR, or set GOATNET and re-run"
    fi

    if [ -n "$SOURCE_BIN" ]; then
        NEW_SHA=$(sha256sum "$SOURCE_BIN" 2>/dev/null | awk '{print $1}')
        if [ -n "$CURRENT_SHA" ] && [ "$NEW_SHA" = "$CURRENT_SHA" ]; then
            ok "goat already up to date (checksum matches $SOURCE_BIN)"
        else
            install -m 755 "$SOURCE_BIN" /usr/local/bin/goat
            [ -n "$CURRENT_SHA" ] && ok "updated goat from $SOURCE_BIN" || ok "installed goat from $SOURCE_BIN"
        fi
    fi
    [ -n "$TMP" ] && rm -rf "$TMP"

    if command -v goat >/dev/null 2>&1; then
        ok "goat version: $(goat --version 2>&1 | head -1)"
    else
        fail "goat still not on PATH after step 1.5"
    fi

    step "1.6  This repo"
    if [ -f "$REPO_DIR/host/first-boot.sh" ]; then
        ok "running from inside the repo clone: $REPO_DIR (host/first-boot.sh found)"
    else
        fail "$REPO_DIR/host/first-boot.sh not found - this script must live at the root of the zagros-moon-pod clone"
    fi

    step "1.7  LUKS-backed state volume ($STATE_DIR)"
    if findmnt -n "$STATE_DIR" 2>/dev/null | grep -q '/dev/mapper/'; then
        ok "$STATE_DIR already mounted from $(findmnt -n -o SOURCE "$STATE_DIR")"
    else
        if command -v cryptsetup >/dev/null 2>&1; then
            ok "cryptsetup already present"
        else
            apt-get -o DPkg::Lock::Timeout=180 update -qq \
                && apt-get -o DPkg::Lock::Timeout=180 install -y -qq cryptsetup \
                && ok "installed cryptsetup" \
                || fail "failed to install cryptsetup"
        fi

        if ! command -v cryptsetup >/dev/null 2>&1; then
            fail "cryptsetup still not available - skipping the rest of the LUKS setup"
        else
            if [ ! -f "$LUKS_IMG" ]; then
                fallocate -l "$LUKS_SIZE" "$LUKS_IMG" || dd if=/dev/zero of="$LUKS_IMG" bs=1M count=0 seek="$(numfmt --from=iec "$LUKS_SIZE" | awk '{print int($1/1048576)}')"
                ok "created $LUKS_IMG ($LUKS_SIZE)"
            else
                ok "$LUKS_IMG already exists"
            fi

            if [ ! -f "$LUKS_KEYFILE" ] && cryptsetup isLuks "$LUKS_IMG" 2>/dev/null; then
                fail "$LUKS_IMG is already a LUKS container but $LUKS_KEYFILE is missing - a fresh random keyfile cannot open the existing data. Restore the original keyfile (or deliberately wipe $LUKS_IMG) before re-running."
            elif [ ! -f "$LUKS_KEYFILE" ]; then
                dd if=/dev/urandom of="$LUKS_KEYFILE" bs=64 count=1 2>/dev/null
                chmod 0400 "$LUKS_KEYFILE"
                ok "created $LUKS_KEYFILE"
            else
                ok "$LUKS_KEYFILE already exists - reusing"
            fi

            if ! cryptsetup isLuks "$LUKS_IMG" 2>/dev/null; then
                cryptsetup luksFormat --batch-mode --key-file "$LUKS_KEYFILE" "$LUKS_IMG" \
                    && ok "luksFormat on $LUKS_IMG" || fail "luksFormat failed on $LUKS_IMG"
            else
                ok "$LUKS_IMG already a LUKS container"
            fi

            if [ ! -e /dev/mapper/goat-moon ] && cryptsetup isLuks "$LUKS_IMG" 2>/dev/null; then
                cryptsetup open --key-file "$LUKS_KEYFILE" "$LUKS_IMG" goat-moon \
                    && ok "opened /dev/mapper/goat-moon" || fail "cryptsetup open failed"
            elif [ -e /dev/mapper/goat-moon ]; then
                ok "/dev/mapper/goat-moon already open"
            else
                fail "cannot open /dev/mapper/goat-moon - $LUKS_IMG is not a valid LUKS container"
            fi

            if [ -e /dev/mapper/goat-moon ]; then
                # Settle and re-probe before trusting a negative blkid: mkfs over a
                # filesystem that just wasn't visible yet would destroy existing data.
                udevadm settle 2>/dev/null || true
                if blkid /dev/mapper/goat-moon >/dev/null 2>&1 || { sleep 1 && blkid /dev/mapper/goat-moon >/dev/null 2>&1; }; then
                    ok "/dev/mapper/goat-moon already has a filesystem"
                else
                    mkfs.ext4 -q /dev/mapper/goat-moon && ok "formatted /dev/mapper/goat-moon ext4" \
                        || fail "mkfs.ext4 failed on /dev/mapper/goat-moon"
                fi

                mkdir -p "$STATE_DIR"
                if findmnt -n "$STATE_DIR" 2>/dev/null | grep -q '/dev/mapper/'; then
                    ok "$STATE_DIR already mounted from $(findmnt -n -o SOURCE "$STATE_DIR")"
                elif findmnt -n "$STATE_DIR" >/dev/null 2>&1; then
                    fail "$STATE_DIR is mounted from $(findmnt -n -o SOURCE "$STATE_DIR"), not the LUKS volume - unmount it before re-running"
                else
                    mount /dev/mapper/goat-moon "$STATE_DIR" \
                        && ok "mounted /dev/mapper/goat-moon at $STATE_DIR" || fail "mount failed"
                fi
            else
                fail "/dev/mapper/goat-moon does not exist - skipping mkfs/mount"
            fi

            if ! grep -q "^goat-moon " /etc/crypttab 2>/dev/null; then
                echo "goat-moon $LUKS_IMG $LUKS_KEYFILE luks" >> /etc/crypttab
                ok "registered goat-moon in /etc/crypttab (best-effort - see the unit below)"
            else
                ok "crypttab entry already present"
            fi

            # crypttab entries pointing at a plain FILE (rather than a block device) are not
            # reliably picked up by every system's cryptsetup systemd-generator - confirmed on a
            # real pod: after `sudo reboot`, no systemd-cryptsetup@goat*.service unit was even
            # generated from the entry above, so the volume silently never unlocked (fstab's
            # `nofail` let the host boot anyway, just without its encrypted state - Docker then
            # auto-created empty placeholder directories at the container's bind-mount paths
            # under the still-unmounted $STATE_DIR, which is its own confusing failure to debug
            # blind). This unit does the loop-attach + luksOpen explicitly and does not depend on
            # that generator at all, so it works whether or not the crypttab entry above does.
            cat > /usr/local/sbin/goat-moon-luks-open.sh <<SCRIPT
#!/bin/bash
# goat-moon-luks-open.sh - attach $LUKS_IMG to a loop device and unlock its LUKS volume,
# idempotently. Installed by moon_pod_setup.sh step 1.7 - see the comment there for why this
# exists instead of relying on /etc/crypttab alone.
set -euo pipefail

IMG="$LUKS_IMG"
KEYFILE="$LUKS_KEYFILE"
MAPPER=goat-moon

if [ -e "/dev/mapper/\${MAPPER}" ]; then
    echo "already unlocked: /dev/mapper/\${MAPPER}"
    exit 0
fi

LOOPDEV="\$(losetup -j "\$IMG" | cut -d: -f1 | head -n1 || true)"
if [ -z "\$LOOPDEV" ]; then
    LOOPDEV="\$(losetup --find --show "\$IMG")"
    echo "attached \${IMG} -> \${LOOPDEV}"
else
    echo "reusing existing loop attachment: \${LOOPDEV}"
fi

# systemd-cryptsetup@ (from the crypttab entry, where the generator works) can unlock the same
# volume concurrently; losing that race is success, not a failure to report to the mount.
if ! cryptsetup luksOpen "\$LOOPDEV" "\$MAPPER" --key-file "\$KEYFILE"; then
    [ -e "/dev/mapper/\${MAPPER}" ] || exit 1
    echo "unlocked concurrently by another unit: /dev/mapper/\${MAPPER}"
    exit 0
fi
echo "unlocked: /dev/mapper/\${MAPPER}"
SCRIPT
            chmod 755 /usr/local/sbin/goat-moon-luks-open.sh
            ok "wrote /usr/local/sbin/goat-moon-luks-open.sh"

            cat > /etc/systemd/system/goat-moon-luks-open.service <<'UNIT'
[Unit]
Description=Attach loop device and unlock the goat-moon LUKS volume (file-backed crypttab workaround)
DefaultDependencies=no
After=local-fs-pre.target systemd-udevd.service systemd-cryptsetup@goat\x2dmoon.service
Before=local-fs.target
Requires=local-fs-pre.target
Wants=systemd-udevd.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=30
ExecStart=/usr/local/sbin/goat-moon-luks-open.sh

[Install]
WantedBy=local-fs-pre.target
UNIT
            ok "wrote /etc/systemd/system/goat-moon-luks-open.service"

            systemctl daemon-reload
            systemctl enable goat-moon-luks-open.service >/dev/null 2>&1 \
                && ok "enabled goat-moon-luks-open.service" || fail "failed to enable goat-moon-luks-open.service"

            if ! grep -q "^/dev/mapper/goat-moon " /etc/fstab 2>/dev/null; then
                echo "/dev/mapper/goat-moon $STATE_DIR ext4 defaults,nofail,x-systemd.requires=goat-moon-luks-open.service 0 2" >> /etc/fstab
                ok "registered $STATE_DIR in /etc/fstab (nofail, ordered after goat-moon-luks-open.service)"
            elif ! grep -q "x-systemd.requires=goat-moon-luks-open.service" /etc/fstab 2>/dev/null; then
                sed -i "s#\\(/dev/mapper/goat-moon $STATE_DIR ext4 defaults,nofail\\)#\\1,x-systemd.requires=goat-moon-luks-open.service#" /etc/fstab
                ok "added the boot-ordering hint to the existing $STATE_DIR fstab entry"
            else
                ok "fstab entry already present and ordered after goat-moon-luks-open.service"
            fi

            info "reboot persistence now goes through goat-moon-luks-open.service, not crypttab alone - still worth a real 'sudo reboot' + 'findmnt -n $STATE_DIR' check on hardware this hasn't run on before"
        fi
    fi

    step "1.8  Image reachability"
    if [ -x "$REPO_DIR/tests/check-images-public.sh" ]; then
        if (cd "$REPO_DIR" && ./tests/check-images-public.sh); then
            ok "all pod images anonymously pullable"
        else
            fail "check-images-public.sh failed - fix egress before continuing"
        fi
    else
        warn "skipping - $REPO_DIR/tests/check-images-public.sh not found"
    fi

    step "1.9  Firewall / egress reminder"
    if timeout 8 bash -c 'cat < /dev/null > /dev/tcp/pkgs.netbird.io/443' 2>/dev/null; then
        ok "outbound TCP 443 reachable"
    else
        warn "outbound TCP 443 to pkgs.netbird.io failed - check firewall"
    fi
    info "also needed: outbound UDP 51820 (WireGuard). Zenoh ports ride inside the tunnel - don't open them at the perimeter."

    step "Part 1 checklist"
    printf "  %-42s %s\n" "64-bit Linux host"          "$([ -n "$GOAT_ARCH" ] && echo PASS || echo FAIL)"
    printf "  %-42s %s\n" "Docker + compose plugin"    "$(docker compose version >/dev/null 2>&1 && echo PASS || echo FAIL)"
    printf "  %-42s %s\n" "envsubst"                   "$(command -v envsubst >/dev/null 2>&1 && echo PASS || echo FAIL)"
    printf "  %-42s %s\n" "OpenSSL"                    "$(command -v openssl >/dev/null 2>&1 && echo PASS || echo FAIL)"
    printf "  %-42s %s\n" "netbird installed"          "$(command -v netbird >/dev/null 2>&1 && echo PASS || echo FAIL)"
    printf "  %-42s %s\n" "netbird joined mesh"        "$(mesh_peers_connected_probe && echo PASS || echo "FAIL/NOT JOINED")"
    printf "  %-42s %s\n" "goat on PATH"                "$(command -v goat >/dev/null 2>&1 && echo PASS || echo FAIL)"
    printf "  %-42s %s\n" "LUKS state volume mounted"  "$(findmnt -n "$STATE_DIR" 2>/dev/null | grep -q '/dev/mapper/' && echo PASS || echo FAIL)"
    printf "  %-42s %s\n" "repo cloned"                 "$([ -f "$REPO_DIR/host/first-boot.sh" ] && echo PASS || echo FAIL)"
    PART1_FAILED=$FAILED
    [ "$PART1_FAILED" -eq 0 ] && ok "PART 1 complete - host is pod-ready." || warn "PART 1 finished with failures above - Part 2's pre-flight will re-check and stop if it's not safe to continue."
    return "$PART1_FAILED"
}

# #############################################################################
#  PART 2 / 3  --  STAND-UP
# #############################################################################

# --- step 2.5 helpers: the pod's CA trust root ------------------------------
# The state dir first-boot will use: the filled profile's POD_STATE_DIR, with first-boot's default.
# shellcheck disable=SC1090
profile_state_dir() { ( set +u; . "$PROFILE_ENV" >/dev/null 2>&1; echo "${POD_STATE_DIR:-/var/lib/goat-moon}" ); }

# The root step 2.5 would add: CA_ROOT_PEM when set, else the tarball's root beside the .cbor.
# A CA_ROOT_PEM that is set but missing is an error, never a reason to use another file.
ca_root_pem_source() {
    local pem="${CA_ROOT_PEM:-${BUNDLE_PATH%.cbor}-ca.pem}"
    [ -f "$pem" ] || return 1
    echo "$pem"
}

explain_missing_ca_root() {
    if [ -n "$CA_ROOT_PEM" ]; then
        fail "CA_ROOT_PEM=$CA_ROOT_PEM does not exist - fix the path (step 2.5 never swaps in another root)"
        return
    fi
    fail "the pod trusts no CA root, so first-boot cannot verify your bundle (the bundle itself is fine)"
    if tarball_ca_probe; then
        echo "  Your tarball carries a *-goat-cli-ca.pem, but not at ${BUNDLE_PATH%.cbor}-ca.pem."
        echo "  Point BUNDLE_PATH at the .cbor unpacked from the same tarball, or set CA_ROOT_PEM to the root."
        return
    fi
    echo "  goat ships with no goatnet built in, and no *-goat-cli-ca.pem sits beside your bundle."
    echo "  Fetch your goatnet's root from https://get.${GOATNET}/ca-roots/"
    echo "  (mesh-only, like the goat download), then either re-run with CA_ROOT_PEM=<root.pem>, or add it yourself:"
    echo "      sudo GOAT_PROFILE_DIR=$GOAT_PROFILE_DIR goat ca add <root.pem>"
    echo "  GOAT_PROFILE_DIR matters: without it the root lands in ~/.goat (or /root/.goat), which first-boot does not read."
    echo "  Details: docs/partner-run-guide.md, 'Trust your goatnet's CA root'."
}

# The fingerprint goat gives a root, read by adding it to a throwaway trust store: goat's own parse
# and format, and nothing reaches the pod's store before the operator has matched it.
ca_root_fingerprint() {
    local pem="$1" stage out fp
    stage="$(mktemp -d)" || return 1
    if ! out="$(GOAT_PROFILE_DIR="$stage" goat ca add "$pem" 2>&1)"; then
        rm -rf "$stage"
        echo "$out" >&2
        return 1
    fi
    fp="$(env -u GOAT_CA_ROOTS GOAT_PROFILE_DIR="$stage" goat ca ls --json 2>/dev/null \
        | grep -o '"fingerprint":"SHA256:[0-9a-f]*"' | cut -d'"' -f4)"
    rm -rf "$stage"
    if [ "$(printf '%s\n' "$fp" | grep -c .)" -ne 1 ]; then
        echo "could not read the fingerprint of $pem back from 'goat ca ls'" >&2
        return 1
    fi
    echo "$fp"
}

# SHA256:<hex>, compared without regard to case, spaces, or the SHA256: prefix.
normalize_fingerprint() { printf '%s' "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]' | sed 's/^sha256://'; }

# A root and a bundle from one tarball agree by construction, so the fingerprint the goat side gave
# out of band is the only check that the pair is genuine. Match it before the pod trusts the root.
confirm_ca_root_fingerprint() {
    local fp="$1" ans
    if [ -n "$EXPECTED_CA_FINGERPRINT" ]; then
        if [ "$(normalize_fingerprint "$fp")" = "$(normalize_fingerprint "$EXPECTED_CA_FINGERPRINT")" ]; then
            ok "fingerprint matches EXPECTED_CA_FINGERPRINT: $fp"
            return 0
        fi
        fail "fingerprint $fp does not match EXPECTED_CA_FINGERPRINT=$EXPECTED_CA_FINGERPRINT - the pod does not trust this root"
        echo "  Either the file is the wrong root or someone substituted it. Ask the goat side which root signs your bundle."
        return 1
    fi
    if [ ! -t 0 ]; then
        fail "EXPECTED_CA_FINGERPRINT is unset and there is no terminal to confirm on - the pod does not trust this root"
        return 1
    fi
    echo "  Root fingerprint: ${BOLD}$fp${RESET}"
    echo "  Compare it with the fingerprint the goat side gave you through another channel, not the tarball or page this file came from."
    read -r -p "  Type yes if they match exactly: " ans
    [ "${ans,,}" = "yes" ] && return 0
    fail "fingerprint not confirmed - nothing was added to the pod's trust store"
    return 1
}

trust_ca_root() {
    local state pem fp
    state="$(profile_state_dir)"
    if [ "$state" != "$STATE_DIR" ]; then
        fail "first-boot will keep the pod's state in $state (POD_STATE_DIR from $PROFILE_ENV, or its default), but this script mounts the state volume and adds the CA root under $STATE_DIR"
        echo "  They must be one directory. Set STATE_DIR in the CONFIG block and POD_STATE_DIR in the profile to the same value."
        return 1
    fi
    if ca_root_trusted_probe; then
        ok "the pod's trust store holds a CA root (or this goat build predates 'goat ca')"
        return 0
    fi
    if ! pem="$(ca_root_pem_source)"; then
        explain_missing_ca_root
        return 1
    fi
    [ -n "$CA_ROOT_PEM" ] || info "using the CA root your bundle tarball shipped beside the .cbor: $pem"
    if ! fp="$(ca_root_fingerprint "$pem")"; then
        fail "could not read the fingerprint of $pem (goat's message is above) - nothing was added to the pod's trust store"
        return 1
    fi
    confirm_ca_root_fingerprint "$fp" || return 1
    info "adding $pem to the pod's trust store"
    if ! GOAT_PROFILE_DIR="$GOAT_PROFILE_DIR" goat ca add "$pem"; then
        fail "goat ca add $pem failed - read goat's message above"
        echo "  'already trusted with a DIFFERENT key' means a CA rotation or a substitute root: confirm with the goat side before anything else."
        return 1
    fi
    ok "CA root trusted under $GOAT_PROFILE_DIR"
}

run_part2() {
    banner "PART 2 / 3  --  STAND-UP" "$MAGENTA"
    FAILED=0

    step "2.0  Pre-flight - re-check the pod-ready checklist (never trust a stale run)"
    PREFLIGHT_OK=1
    command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 \
        && ok "docker + compose plugin present" || { fail "docker + compose plugin missing"; PREFLIGHT_OK=0; }
    command -v envsubst >/dev/null 2>&1 \
        && ok "envsubst present" || { fail "envsubst missing"; PREFLIGHT_OK=0; }
    if command -v openssl >/dev/null 2>&1; then
        ok "OpenSSL present"
    else
        fail "OpenSSL missing"
        PREFLIGHT_OK=0
    fi
    command -v netbird >/dev/null 2>&1 \
        && ok "netbird installed" || { fail "netbird not installed"; PREFLIGHT_OK=0; }
    command -v goat >/dev/null 2>&1 \
        && ok "goat on PATH: $(goat --version 2>&1 | head -1)" || { fail "goat not on PATH"; PREFLIGHT_OK=0; }
    findmnt -n "$STATE_DIR" 2>/dev/null | grep -q '/dev/mapper/' \
        && ok "$STATE_DIR mounted from LUKS volume" || { fail "$STATE_DIR not mounted from a LUKS volume"; PREFLIGHT_OK=0; }
    [ -f "$REPO_DIR/host/first-boot.sh" ] \
        && ok "running from inside the repo clone: $REPO_DIR" || { fail "$REPO_DIR/host/first-boot.sh not found"; PREFLIGHT_OK=0; }

    if [ "$PREFLIGHT_OK" -ne 1 ]; then
        fail "pod-ready checklist did not pass - fix Part 1 above before continuing"
        echo "${RED}${BOLD}STOPPING before touching the bundle or the mesh setup key.${RESET}"
        return 1
    fi

    step "2.1  Bundle - extract/find the signed join bundle"
    if [ -f "$BUNDLE_PATH" ]; then
        ok "bundle already extracted: $BUNDLE_PATH"
    elif bundle_probe; then
        ok "bundle ready: $BUNDLE_PATH"
    else
        mapfile -t FOUND_BUNDLES < <(find "$REAL_HOME" -maxdepth 5 -iname '*-goat-cli.cbor' -not -path "$REPO_DIR/*" 2>/dev/null)
        if [ "${#FOUND_BUNDLES[@]}" -gt 1 ]; then
            fail "found multiple *-goat-cli.cbor files under $REAL_HOME - set BUNDLE_PATH explicitly:"
            printf '    %s\n' "${FOUND_BUNDLES[@]}"
        else
            fail "no bundle found at $BUNDLE_PATH or $BUNDLE_TARBALL - the menu should have caught this, go back and check again"
        fi
    fi

    if [ -f "$BUNDLE_PATH" ] && [ "$FAILED" -eq 0 ]; then
        case "$(cd "$(dirname "$BUNDLE_PATH")" && pwd)/$(basename "$BUNDLE_PATH")" in
            "$REPO_DIR"/*) fail "$BUNDLE_PATH is INSIDE the repo clone - move it outside before continuing" ;;
            *) ok "bundle confirmed outside the repo clone: $BUNDLE_PATH" ;;
        esac
    fi

    if [ "$FAILED" -ne 0 ]; then
        echo "${RED}${BOLD}STOPPING - no usable bundle.${RESET} If you never received it, contact the goat side"
        echo "(docs/partner-run-guide.md, 'If you have not received these')."
        return 1
    fi

    step "2.2  Slot id + pod id"
    # Both values are spliced unescaped into sed programs and zenoh key expressions
    # below - validate the character set once here, at the boundary.
    if [ -z "$PARTNER_NAMESPACE" ] || [ "$PARTNER_NAMESPACE" = "CHANGE-ME-zagros-uuid-slot" ]; then
        fail "PARTNER_NAMESPACE not set / still a placeholder - fill in your real slot id"
    elif ! [[ "$PARTNER_NAMESPACE" =~ ^[A-Za-z0-9/_-]+$ ]]; then
        fail "PARTNER_NAMESPACE '$PARTNER_NAMESPACE' has characters outside [A-Za-z0-9/_-]"
    else
        ok "slot id (PARTNER_NAMESPACE) = $PARTNER_NAMESPACE"
    fi
    if [ -z "$POD_ID" ]; then
        fail "POD_ID not set"
    elif ! [[ "$POD_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
        fail "POD_ID '$POD_ID' has characters outside [A-Za-z0-9_-]"
    else
        ok "POD_ID = $POD_ID"
    fi

    if [ "$FAILED" -ne 0 ]; then
        echo "${RED}${BOLD}STOPPING - slot id/pod id missing or invalid.${RESET}"
        return 1
    fi

    step "2.3  Fill your profile ($SOURCE_PROFILE -> $PROFILE_NAME)"
    PROFILE_DIR="$REPO_DIR/profiles/$PROFILE_NAME"
    PROFILE_ENV="$PROFILE_DIR/profile.env"
    if [ ! -d "$PROFILE_DIR" ]; then
        cp -r "$REPO_DIR/profiles/$SOURCE_PROFILE" "$PROFILE_DIR" \
            && ok "created $PROFILE_DIR from $SOURCE_PROFILE" || fail "failed to copy profiles/$SOURCE_PROFILE"
    else
        ok "$PROFILE_DIR already exists - reusing"
    fi

    if [ -f "$PROFILE_ENV" ]; then
        CURRENT_NS=$(grep -E '^PARTNER_NAMESPACE=' "$PROFILE_ENV" | head -1 | cut -d= -f2-)
        if [ "$CURRENT_NS" = "$PARTNER_NAMESPACE" ]; then
            ok "PARTNER_NAMESPACE already set in $PROFILE_ENV"
        else
            sed -i "s#^PARTNER_NAMESPACE=.*#PARTNER_NAMESPACE=${PARTNER_NAMESPACE}#" "$PROFILE_ENV" \
                && ok "set PARTNER_NAMESPACE in $PROFILE_ENV" || fail "failed to set PARTNER_NAMESPACE"
        fi
    else
        fail "$PROFILE_ENV not found after copy"
    fi

    if [ -f "$PROFILE_ENV" ]; then
        CURRENT_POD_ID=$(grep -E '^POD_ID=' "$PROFILE_ENV" | head -1 | cut -d= -f2-)
        if [ "$CURRENT_POD_ID" = "$POD_ID" ]; then
            ok "POD_ID already set in $PROFILE_ENV"
        elif grep -qE '^#?[[:space:]]*POD_ID=' "$PROFILE_ENV"; then
            sed -i -E "s/^#?[[:space:]]*POD_ID=.*/POD_ID=${POD_ID}/" "$PROFILE_ENV" \
                && ok "set POD_ID=$POD_ID" || fail "failed to set POD_ID"
        else
            echo "POD_ID=${POD_ID}" >> "$PROFILE_ENV" && ok "appended POD_ID=$POD_ID" || fail "failed to append POD_ID"
        fi
    fi

    if command -v git >/dev/null 2>&1 && [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" check-ignore -q "profiles/$PROFILE_NAME/profile.env" \
            && ok "profiles/$PROFILE_NAME/profile.env confirmed git-ignored" \
            || fail "profiles/$PROFILE_NAME/profile.env is NOT git-ignored - your slot id could land in a commit"
    else
        warn "not a git checkout - could not confirm the -local profile is ignored"
    fi

    if [ "$FAILED" -ne 0 ]; then
        echo "${RED}${BOLD}STOPPING before the mesh join - fix the profile fill above first.${RESET}"
        return 1
    fi

    step "2.4  Mesh join (netbird up) - re-check, idempotent"
    netbird_up_if_needed
    if ! mesh_connected_probe; then
        fail "netbird still not Connected - stopping before first-boot.sh"
        return 1
    fi

    step "2.5  CA trust root - the pod's trust store ($GOAT_PROFILE_DIR/ca-roots)"
    trust_ca_root || return 1

    step "2.6  host/first-boot.sh $PROFILE_NAME $BUNDLE_PATH"
    info "watch the six numbered steps below. On the zagros sandbox, [3/6] (goat-clientd import) printing 'skipped' is normal."
    if ( cd "$REPO_DIR" && ./host/first-boot.sh "$PROFILE_NAME" "$BUNDLE_PATH" ); then
        ok "first-boot.sh completed"
    else
        fail "first-boot.sh failed (set -e, stops at first broken step) - fix and re-run this script (idempotent)"
        echo "  Read the error above before asking the goat side for anything:"
        echo "  - 'trusts no CA roots' / 'does not trust that CA': the POD's trust store lacks your goatnet's root."
        echo "    Your bundle is fine and nothing was consumed - fix step 2.5 (docs/partner-run-guide.md, 'Trust your goatnet's CA root')."
        echo "  - 'expired' / 'activation deadline passed': the bundle lapsed; ask the goat side for a fresh one, don't retry blindly."
        return 1
    fi

    info "waiting for the data-plane containers to come up before the smoke check..."
    wait_for "goat-moon-zenoh-router" "$CONTAINERS_WAIT_INTERVAL" "$CONTAINERS_WAIT_TRIES" containers_up_probe || true

    # first-boot re-renders zenoh/config.json5, but a router that was ALREADY running
    # keeps the config it loaded at startup - zenoh reads the file only then. On a
    # re-run the compose spec is unchanged, so nothing recreates the container and
    # the fresh render (ACL included) silently never takes effect. Restart it when
    # the file is newer than the process.
    ROUTER_STARTED=$(docker inspect goat-moon-zenoh-router --format '{{.State.StartedAt}}' 2>/dev/null)
    CONFIG_FILE="$STATE_DIR/zenoh/config.json5"
    if [ -n "$ROUTER_STARTED" ] && [ -f "$CONFIG_FILE" ]; then
        ROUTER_EPOCH=$(date -d "$ROUTER_STARTED" +%s 2>/dev/null || echo 0)
        CONFIG_EPOCH=$(stat -c %Y "$CONFIG_FILE" 2>/dev/null || echo 0)
        if [ "$CONFIG_EPOCH" -gt "$ROUTER_EPOCH" ]; then
            warn "router started before the current config render - restarting it so the render takes effect"
            docker restart goat-moon-zenoh-router >/dev/null \
                && ok "goat-moon-zenoh-router restarted on the fresh config" \
                || fail "docker restart goat-moon-zenoh-router failed"
            wait_for "router back up after config reload" "$CONTAINERS_WAIT_INTERVAL" "$CONTAINERS_WAIT_TRIES" containers_up_probe || true
        else
            ok "router already running on the current config render"
        fi
    fi

    step "2.7  Verify (smoke check only - not the full ladder)"
    if GOAT_PROFILE_DIR="$GOAT_PROFILE_DIR" goat doctor --all; then
        ok "goat doctor --all passed"
    else
        fail "goat doctor --all reported problems - see output above"
    fi
    docker ps --format '{{.Names}}' | grep -q "goat-moon-zenoh-router" \
        && ok "goat-moon-zenoh-router container is up" || fail "goat-moon-zenoh-router container not found"
    docker ps --format '{{.Names}}' | grep -q "goat-moon-audit-sink" \
        && ok "goat-moon-audit-sink container is up" \
        || warn "goat-moon-audit-sink container not found - see docs/partner-run-guide.md, 'Trouble'"

    PART2_FAILED=$FAILED
    if [ "$PART2_FAILED" -eq 0 ]; then
        ok "PART 2 complete - mesh joined, first-boot done, smoke checks passed."
    else
        warn "PART 2 finished with smoke-check failures above - Part 3 will diagnose in detail."
    fi
    echo "  health:  GOAT_PROFILE_DIR=$GOAT_PROFILE_DIR goat doctor --all"
    echo "  delivery: keep goat-moon-zenoh-router running and publish a unique key through"
    echo "            tls/127.0.0.1:7447 with your normal application or clients/ example;"
    echo "            require both the local audit metric and portal catalog count to rise"
    if [ -n "${NETBIRD_KEY_SPENT_THIS_RUN:-}" ]; then
        warn "reminder: blank NETBIRD_SETUP_KEY now (or forget the env var) - it was just spent, it is single-use."
    fi
    return "$PART2_FAILED"
}

# #############################################################################
#  PART 3 / 3  --  VERIFY (health ladder, stops at first failure)
# #############################################################################
run_part3() {
    banner "PART 3 / 3  --  VERIFY (runs all 5 checks, reports pass/fail at the end)" "$BLUE"
    PART3_RESULT="pass"
    SUMMARY_LABELS=(); SUMMARY_STATUS=()

    info "Using slot (PARTNER_NAMESPACE) = $PARTNER_NAMESPACE   GOAT_PROFILE_DIR = $GOAT_PROFILE_DIR"

    step "3.1/5  Mesh - netbird status"
    NB_STATUS=$(netbird status 2>&1)
    echo "$NB_STATUS" | sed 's/^/  /'
    if echo "$NB_STATUS" | grep -qi "Connected"; then
        ok "netbird: Connected"
        record "1. Mesh (netbird status)" "PASS"
    else
        note_fail "1 (Mesh)" \
"netbird is not Connected. Per the skill's symptom table (mesh disconnected / flapping):
  sudo netbird status -d
The pod cannot be healthier than its mesh - the checks below may be meaningless until this is fixed."
        record "1. Mesh (netbird status)" "FAIL"
    fi

    step "3.2/5  Health - goat doctor --all"
    DOCTOR_OUT=$(GOAT_PROFILE_DIR="$GOAT_PROFILE_DIR" goat doctor --all 2>&1)
    DOCTOR_STATUS=$?
    echo "$DOCTOR_OUT" | sed 's/^/  /'
    if [ "$DOCTOR_STATUS" -eq 0 ] && ! echo "$DOCTOR_OUT" | grep -qiE 'fail|error'; then
        ok "goat doctor --all: cert + router checks green"
        record "2. Health (goat doctor --all)" "PASS"
    else
        note_fail "2 (Health)" \
"goat doctor reported problems (see output above). Per the skill's symptom table
(doctor router check fails), per docs/partner-run-guide.md Trouble:
  - confirm the mesh is up: netbird status -> Connected
  - confirm the bundle hasn't expired: sudo GOAT_PROFILE_DIR=$GOAT_PROFILE_DIR goat profile show
A stale bundle points the router config at the wrong endpoint - get a fresh one if expired."
        record "2. Health (goat doctor --all)" "FAIL"
    fi

    step "3.3/5  Containers - docker ps"
    DOCKER_PS=$(docker ps --format '{{.Names}}\t{{.Status}}')
    echo "$DOCKER_PS" | sed 's/^/  /'
    ROUTER_UP=$(echo "$DOCKER_PS" | grep "^goat-moon-zenoh-router" | grep -i "Up" | grep -cv "(unhealthy)")
    # The router is required; the audit sink is reported, and a missing or restarting sink
    # is a warning (the data plane does not depend on it).
    if echo "$DOCKER_PS" | grep "^goat-moon-audit-sink" | grep -q "Up"; then
        ok "goat-moon-audit-sink Up"
    else
        warn "goat-moon-audit-sink is not Up - see docs/partner-run-guide.md, 'Trouble'"
    fi
    if [ "$ROUTER_UP" -ge 1 ]; then
        ok "goat-moon-zenoh-router Up"
        record "3. Containers (docker ps)" "PASS"
    else
        echo "  container status (incl. stopped/restarting), for reference:"
        docker ps -a --format '  {{.Names}}\t{{.Status}}' | grep -E "goat-moon-" || true
        note_fail "3 (Containers)" \
"Missing or not-Up: goat-moon-zenoh-router. Per the skill's symptom table:
  - if it's pull-failing: (cd $REPO_DIR && ./tests/check-images-public.sh)  (egress problem if it fails)
  - if it's restarting: docker logs goat-moon-zenoh-router
    config render errors point at docs/router-config.md - check $STATE_DIR/zenoh/config.json5
    for leftover \${...} placeholders or a JSON5 parse error."
        record "3. Containers (docker ps)" "FAIL"
    fi

    step "3.4/5  Round-trip - publish, then confirm on the audit tail"
    echo "hi" > /tmp/ping
    # This is the legacy direct-to-fabric probe. It predates the running-router
    # delivery verdict and does not exercise the router ACL. The fabric allows one
    # transport per pod identity, and the running router holds it, so a live
    # host-side subscriber can only race the router and proves nothing. The separate
    # setup-verdict change tracked in #6 will replace this probe. 'goat flow --since'
    # reads via a portal-presigned URL using the profile token, so it needs no second transport.
    echo "  stopping goat-moon-zenoh-router (frees the pod identity's one fabric transport)"
    docker stop goat-moon-zenoh-router >/dev/null 2>&1 || true
    echo "  publishing to '${PARTNER_NAMESPACE}/test/ping' (INSIDE your slot - never a different namespace)"
    PUB_OK=0
    timeout "$ROUND_TRIP_TIMEOUT" env GOAT_PROFILE_DIR="$GOAT_PROFILE_DIR" goat pub "${PARTNER_NAMESPACE}/test/ping" --payload-file /tmp/ping && PUB_OK=1
    FLOW_OUT=""
    FLOW_SAW_EVENT=0
    if [ "$PUB_OK" -eq 1 ]; then
        # Audit-tail ingestion is eventually consistent (a portal-side read, not a live
        # subscription) - one immediate check after a fresh publish is a coin flip, not a
        # verdict. Retry the ambiguous "no event yet" case a few times before concluding it
        # never arrived; a distinct answer (an outright error, "no observer could answer")
        # is informative on its own and not worth re-asking.
        for attempt in $(seq 1 "$ROUND_TRIP_FLOW_TRIES"); do
            echo "  reading the audit tail (attempt $attempt/$ROUND_TRIP_FLOW_TRIES): goat flow '${PARTNER_NAMESPACE}/test/ping' --since 5m"
            FLOW_OUT=$(timeout "$ROUND_TRIP_TIMEOUT" env GOAT_PROFILE_DIR="$GOAT_PROFILE_DIR" goat flow "${PARTNER_NAMESPACE}/test/ping" --since 5m 2>&1)
            if echo "$FLOW_OUT" | grep -Eq "ok.*[1-9][0-9]* event"; then
                FLOW_SAW_EVENT=1
                break
            fi
            echo "$FLOW_OUT" | grep -qi "no observer could answer" && break
            [ "$attempt" -lt "$ROUND_TRIP_FLOW_TRIES" ] && sleep "$ROUND_TRIP_FLOW_RETRY_DELAY"
        done
        echo "$FLOW_OUT" | sed 's/^/  /'
    fi
    # Restart the router no matter how the probe went - a verify pass must never
    # leave the data plane down.
    docker start goat-moon-zenoh-router >/dev/null 2>&1 \
        && ok "goat-moon-zenoh-router restarted" \
        || fail "docker start goat-moon-zenoh-router failed - start it by hand before leaving the pod"
    if [ "$PUB_OK" -ne 1 ]; then
        note_fail "4 (Round-trip, publish)" \
"goat pub itself returned an error (not silence) - that's a CLI/connectivity fault, not an ACL
denial. Re-check step 1 (mesh) and step 2 (health) above. If the pub hung until the ${ROUND_TRIP_TIMEOUT}s
timeout, something else may still be holding the pod identity's transport - re-run after
confirming the router container is the only goat process on this host."
        record "4. Round-trip publish + audit tail" "FAIL"
    elif [ "$FLOW_SAW_EVENT" -eq 1 ]; then
        ok "round-trip: audit tail shows the publish"
        record "4. Round-trip publish + audit tail" "PASS"
    elif echo "$FLOW_OUT" | grep -qi "no observer could answer"; then
        note_fail "4 (Round-trip, audit tail)" \
"goat flow answered 'no observer could answer' - that is cannot-tell, NOT proof the publish was
dropped. The audit tail read goes to the portal; confirm the mesh (step 1) and portal reachability,
then re-run: GOAT_PROFILE_DIR=$GOAT_PROFILE_DIR goat flow '${PARTNER_NAMESPACE}/test/ping' --since 5m"
        record "4. Round-trip publish + audit tail" "FAIL"
    else
        note_fail "4 (Round-trip, audit tail)" \
"The publish returned success but the audit tail shows no event for it after $ROUND_TRIP_FLOW_TRIES
attempts ($(( (ROUND_TRIP_FLOW_TRIES - 1) * ROUND_TRIP_FLOW_RETRY_DELAY ))s of retrying). Per the
skill's first principle: silence is a verdict, not a bug - the fabric denies outside-slot publishes
SILENTLY, with no error to the publisher. This probe published INSIDE your slot (${PARTNER_NAMESPACE}), so:
  - re-confirm nothing above (mesh/doctor/containers) actually failed silently
  - see docs/router-config.md, 'Validate + troubleshoot' -> 'A publish succeeds but nothing
    arrives': confirm $STATE_DIR/zenoh/config.json5 has your real slot anchor baked in
  - never 'fix' this by publishing under a different namespace; the slot is the contract"
        record "4. Round-trip publish + audit tail" "FAIL"
    fi

    step "3.5/5  Doctor timer - status.json freshness"
    STATUS_JSON="$STATE_DIR/doctor/status.json"
    STATUS_FAIL_MARKER="${STATUS_JSON}.last-fail"
    if [ ! -f "$STATUS_JSON" ]; then
        note_fail "5 (Doctor timer)" \
"$STATUS_JSON does not exist - the goat-doctor health timer never ran or was never installed.
first-boot step [6/6] installs it; re-run Part 2, or check: systemctl status goat-doctor.timer"
        record "5. Doctor timer (status.json freshness)" "FAIL"
    else
        T1=$(stat -c %Y "$STATUS_JSON" 2>/dev/null)
        echo "  status.json mtime: $T1 - waiting for it to advance"
        # The timer's FIRST tick after being enabled can land up to OnBootSec(30s) + one full
        # OnUnitActiveSec(60s) =~ 90s out - poll with early exit rather than a fixed sleep, so
        # a timer that's been running a while still reports back in seconds, and a timer Part 2
        # *just* installed doesn't false-negative for having not ticked yet.
        status_json_advanced_probe() {
            local t; t=$(stat -c %Y "$STATUS_JSON" 2>/dev/null)
            [ -n "$t" ] && [ -n "$T1" ] && [ "$t" -gt "$T1" ]
        }
        TIMER_ADVANCED=0
        wait_for "status.json advancing" "$DOCTOR_TIMER_POLL_INTERVAL" "$DOCTOR_TIMER_TRIES" status_json_advanced_probe \
            && TIMER_ADVANCED=1
        T2=$(stat -c %Y "$STATUS_JSON" 2>/dev/null)
        echo "  status.json mtime now: $T2"
        if [ -f "$STATUS_FAIL_MARKER" ]; then
            note_fail "5 (Doctor timer)" \
"$STATUS_FAIL_MARKER exists - the last doctor timer run failed. Re-check steps 1-2 above."
            record "5. Doctor timer (status.json freshness)" "FAIL"
        elif [ "$TIMER_ADVANCED" -eq 1 ]; then
            ok "status.json is fresh (timestamp advanced), no .last-fail marker"
            record "5. Doctor timer (status.json freshness)" "PASS"
        else
            note_fail "5 (Doctor timer)" \
"$STATUS_JSON did not advance within $(( DOCTOR_TIMER_POLL_INTERVAL * DOCTOR_TIMER_TRIES ))s - the timer is not firing.
Check: systemctl status goat-doctor.timer   and   systemctl list-timers | grep goat-doctor"
            record "5. Doctor timer (status.json freshness)" "FAIL"
        fi
    fi

    if [ "$PART3_RESULT" = "pass" ]; then
        banner "ALL DONE - POD VERIFIED" "$GREEN"
    else
        banner "VERIFY SUMMARY - ONE OR MORE CHECKS FAILED" "$RED"
    fi
    printf "  %-20s %s\n" "Part 1 (bring-up)" "$(part_status_str PART1_FAILED)"
    printf "  %-20s %s\n" "Part 2 (stand-up)"  "$(part_status_str PART2_FAILED)"
    echo
    local i
    for i in "${!SUMMARY_LABELS[@]}"; do
        if [ "${SUMMARY_STATUS[$i]}" = "PASS" ]; then
            printf "  ${GREEN}${BOLD}%-6s${RESET} %s\n" "PASS" "${SUMMARY_LABELS[$i]}"
        else
            printf "  ${RED}${BOLD}%-6s${RESET} %s\n" "FAIL" "${SUMMARY_LABELS[$i]}"
        fi
    done
    echo
    echo "  health:  GOAT_PROFILE_DIR=$GOAT_PROFILE_DIR goat doctor --all"
    echo "  delivery: keep goat-moon-zenoh-router running and publish a unique key through"
    echo "            tls/127.0.0.1:7447 with your normal application or clients/ example;"
    echo "            require both the local audit metric and portal catalog count to rise"
    return 0
}

# #############################################################################
#  CONTROL CENTER MENU
# #############################################################################
show_header() {
    echo "${BOLD}${CYAN}"
    cat <<'ASCIIART'
   __  __  ____   ____  _   _     ____   ___  ____          _..._
  |  \/  |/ __ \ / __ \| \ | |   |  _ \ / _ \|  _ \       .::::. `.
  | |\/| | |  | | |  | |  \| |   | |_) | | | | | | |     ::::::::  :
  | |  | | |__| | |__| | |\  |   |  __/| |_| | |_| |     `::::::' .'
  |_|  |_|\____/ \____/|_| \_|   |_|    \___/|____/        `'::'-'
ASCIIART
    echo "${RESET}"
    banner "MOON POD SETUP  --  CONTROL CENTER" "$CYAN"
    printf "  %-20s %s\n" "REPO_DIR" "$REPO_DIR"
    printf "  %-20s %s\n" "STATE_DIR" "$STATE_DIR"
    printf "  %-20s %s\n" "PARTNER_NAMESPACE" "$PARTNER_NAMESPACE"
    printf "  %-20s %s\n" "POD_ID" "$POD_ID"
    echo
}

show_status() {
    hr "$CYAN"
    echo "${CYAN}${BOLD}  STATUS${RESET}"
    if part1_ready_probe; then
        printf "    [1] Host bring-up   ${GREEN}${BOLD}READY${RESET}\n"
    else
        printf "    [1] Host bring-up   ${YELLOW}${BOLD}NOT READY${RESET}\n"
    fi
    if part2_done_probe; then
        printf "    [2] Stand-up        ${GREEN}${BOLD}DONE${RESET}\n"
    else
        printf "    [2] Stand-up        ${YELLOW}${BOLD}NOT DONE${RESET}\n"
    fi
    case "${PART3_RESULT:-}" in
        pass) printf "    [3] Verify          ${GREEN}${BOLD}PASS${RESET}\n" ;;
        fail) printf "    [3] Verify          ${RED}${BOLD}FAILED${RESET}\n" ;;
        *)    printf "    [3] Verify          ${DIM}NOT RUN YET${RESET}\n" ;;
    esac
    hr "$CYAN"
    echo
}

show_menu() {
    echo "${CYAN}${BOLD}  MENU${RESET}"
    echo "    1) Run PART 1 - Host bring-up   (docker, netbird, goat CLI, LUKS volume)"
    echo "    2) Run PART 2 - Stand-up        (bundle join, first-boot, smoke check)"
    echo "    3) Run PART 3 - Verify          (full health ladder)"
    echo "    r) Refresh status"
    echo "    q) Quit"
    echo
}

gate_part1() {
    echo
    hr "$CYAN"; echo "${CYAN}${BOLD}  PART 1 / 3 -- HOST BRING-UP${RESET}"; hr "$CYAN"
    echo "  What this does:"
    echo "    Installs Docker+compose, envsubst, OpenSSL, NetBird, and the goat CLI."
    echo "    Joins the mesh"
    echo "    (spends NETBIRD_SETUP_KEY once), and creates/mounts the LUKS state volume."
    echo
    echo "  Current state:"
    mark_line "Docker + compose plugin present" docker_and_compose_probe
    mark_line "NetBird installed"                netbird_installed_probe
    mark_line "NetBird mesh joined (peers connected)" mesh_peers_connected_probe
    mark_line "goat CLI on PATH"                  goat_on_path_probe
    mark_line "LUKS state volume mounted"         luks_mounted_probe
    echo
    echo "  Requires from you right now:"
    if netbird_key_set_probe; then
        printf "    ${GREEN}\xe2\x9c\x93${RESET} NETBIRD_SETUP_KEY is exported\n"
    else
        printf "    ${YELLOW}\xe2\x97\x8b${RESET} NETBIRD_SETUP_KEY not set - fine if mesh already joined above, otherwise export it first\n"
    fi
    echo "    outbound internet access (get.docker.com, pkgs.netbird.io, your GOATNET, apt)"
    echo
    read -r -p "  Start PART 1 now? [y/N/q]: " ans
    case "$ans" in
        y|Y) run_part1; press_enter ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) ;;
    esac
}

gate_part2() {
    echo
    hr "$MAGENTA"; echo "${MAGENTA}${BOLD}  PART 2 / 3 -- STAND-UP${RESET}"; hr "$MAGENTA"
    echo "  What this does:"
    echo "    Extracts the signed join bundle, fills your local profile, (re)joins the"
    echo "    mesh if needed, runs host/first-boot.sh, and does a smoke check."
    echo
    echo "  Requires from Part 1:"
    mark_line "Docker + compose plugin"   docker_and_compose_probe
    mark_line "NetBird installed"         netbird_installed_probe
    mark_line "goat CLI on PATH"          goat_on_path_probe
    mark_line "LUKS state volume mounted" luks_mounted_probe
    echo
    echo "  Requires from you right now:"
    mark_line "signed bundle dropped at $BUNDLE_TARBALL (or a *-goat-cli.cbor under $REAL_HOME)" bundle_present_probe
    mark_line "netbird mesh connected (or NETBIRD_SETUP_KEY exported to join now)"                mesh_or_key_probe
    mark_line "CA root trusted under $GOAT_PROFILE_DIR (or one in your tarball / CA_ROOT_PEM to add now)" ca_root_or_pem_probe
    echo "    PARTNER_NAMESPACE = $PARTNER_NAMESPACE   POD_ID = $POD_ID   (edit the CONFIG block if wrong)"
    echo
    read -r -p "  Start PART 2 now? [y/N/q]: " ans
    case "$ans" in
        y|Y) run_part2; press_enter ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) ;;
    esac
}

gate_part3() {
    echo
    hr "$BLUE"; echo "${BLUE}${BOLD}  PART 3 / 3 -- VERIFY${RESET}"; hr "$BLUE"
    echo "  What this does:"
    echo "    Live health ladder: mesh status -> goat doctor --all -> container check ->"
    echo "    legacy direct-to-fabric publish + audit-tail probe (does not exercise the"
    echo "    router ACL; it stops and restarts the router, retrying the audit-tail read"
    echo "    a few times - it's eventually consistent,"
    echo "    not instant - so the router can stay down up to"
    echo "    ~$(( ROUND_TRIP_TIMEOUT * (ROUND_TRIP_FLOW_TRIES + 1) + ROUND_TRIP_FLOW_RETRY_DELAY * (ROUND_TRIP_FLOW_TRIES - 1) ))s) -> confirms the doctor timer is advancing (polls up to"
    echo "    ~$(( DOCTOR_TIMER_POLL_INTERVAL * DOCTOR_TIMER_TRIES ))s - a freshly-installed timer's first tick can land"
    echo "    that late; a warm one reports back in seconds)."
    echo
    echo "  Requires from Part 2:"
    mark_line "netbird mesh connected"                             mesh_connected_probe
    mark_line "goat-moon-zenoh-router up"                           containers_up_probe
    mark_line "goat profile present ($GOAT_PROFILE_DIR)"            goat_profile_present_probe
    echo
    read -r -p "  Start PART 3 now? [y/N/q]: " ans
    case "$ans" in
        y|Y) run_part3; press_enter ;;
        q|Q) echo "Bye."; exit 0 ;;
        *) ;;
    esac
}

main_menu() {
    while true; do
        show_header
        show_status
        show_menu
        # A closed/exhausted stdin (piping answers non-interactively, or driving this
        # script from a scripted/CI session) makes `read` return non-zero immediately
        # with an empty $choice, forever - without this check the loop re-draws the
        # whole menu and warns "unknown option" in a near-tight spin, since re-drawing
        # itself takes real time (several subprocess probes) but never blocks on
        # anything. Treat EOF the same as an explicit quit.
        if ! read -r -p "  Choose an option: " choice; then
            echo; echo "Bye (stdin closed)."; exit 0
        fi
        case "$choice" in
            1) gate_part1 ;;
            2) gate_part2 ;;
            3) gate_part3 ;;
            r|R) : ;;
            q|Q) echo "Bye."; exit 0 ;;
            *) warn "unknown option: $choice" ;;
        esac
    done
}

# =============================================================================
#  ENTRY POINT
# =============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo bash $0" >&2
    exit 1
fi

PART1_FAILED=""
PART2_FAILED=""
PART3_RESULT=""
NETBIRD_KEY_SPENT_THIS_RUN=""

main_menu
