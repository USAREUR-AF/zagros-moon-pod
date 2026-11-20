#!/usr/bin/env bash
# moon-pod — first-boot bring-up (run once on the partner host, as root).
#
# Turns a signed enrollment bundle + an environment profile into a running pod:
#   [1] goat profile init (verify + extract certs) -> [2] lay Zenoh mTLS material ->
#   [3] goat-clientd import + mesh service (skipped on the sandbox) -> [4] verify the
#   fabric peer + render router config -> [5] compose up -> [6] goat-doctor timer.
#
# goat-cli does the heavy lifting for the bundle: `goat profile init <bundle>` verifies the
# ECDSA-over-canonical-CBOR signature, checks expiry/activation, and writes the mTLS material
# (mtls.cert.pem / mtls.key.pem / ca-roots.pem) + portal token into the profile dir. We reuse
# those extracted certs for the Zenoh router rather than parsing CBOR ourselves.
#
# Idempotent where practical (re-running re-renders config + re-applies compose). goat-client
# v0.2.0 flags are confirmed against the release tag (docs/goat-client-v02-contract.md). On the sandbox
# the mesh is stock netbird, so the goat-clientd step is skipped gracefully when it's absent.
set -euo pipefail

SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
SYSTEMD_RUNTIME_DIR="${SYSTEMD_RUNTIME_DIR:-/run/systemd/system}"

POD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="${1:-}"
BUNDLE="${2:-}"

usage() {
  echo "usage: sudo $0 <profile-name> <bundle.cbor>   e.g. $0 zagros /path/to/pod.cbor"
  exit 2
}
if [ -z "$PROFILE" ] || [ -z "$BUNDLE" ]; then
  usage
fi
[ "$(id -u)" -eq 0 ] || { echo "must run as root (tunnel + cert privileges)"; exit 2; }

PROFILE_ENV="${POD_DIR}/profiles/${PROFILE}/profile.env"
[ -f "$PROFILE_ENV" ] || { echo "no such profile: ${PROFILE_ENV}"; exit 2; }
[ -f "$BUNDLE" ]      || { echo "no such bundle: ${BUNDLE}"; exit 2; }

# Tool presence — fail loud + early rather than midway.
for t in goat envsubst docker openssl timeout cmp mktemp sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "required tool not found on PATH: $t"; exit 2; }
done
command -v goat-clientd >/dev/null 2>&1 || echo "warning: goat-clientd not on PATH — mesh step [3/6] will be skipped"
# goat-pod-api (ADR 1251 pod carriage) is optional: without it, or without the portal signer
# certificate in the profile, the pod carries only its own slot, as before.
: "${POD_API_BIN:=$(command -v goat-pod-api 2>/dev/null || true)}"

# shellcheck disable=SC1090
source "$PROFILE_ENV"
# shellcheck source=host/fabric-peer-identity.sh
source "${POD_DIR}/host/fabric-peer-identity.sh"
# shellcheck source=host/goat-context.sh
source "${POD_DIR}/host/goat-context.sh"
# shellcheck source=host/secure-remove.sh
source "${POD_DIR}/host/secure-remove.sh"
# Test hook: production uses the shipped template; integration tests may render a temporary copy.
: "${ZENOH_ROUTER_TEMPLATE:=${POD_DIR}/host/zenoh-router.json5.tmpl}"
: "${POD_STATE_DIR:=/var/lib/goat-moon}"
: "${GOAT_CLIENT_MODE:=combined}"
: "${ZENOH_LISTEN_PORT:=7447}"
: "${PARTNER_NAMESPACE:?PARTNER_NAMESPACE must be set in the profile}"
: "${VERIFY_CERT_SLOT_BINDING:=0}"
# The shipped profile carries a CHANGE-ME placeholder, which would pass the unset-check above
# and stand the pod up publishing into a namespace the fabric silently denies. Refuse it.
case "${PARTNER_NAMESPACE}" in
  CHANGE-ME*)
    echo "PARTNER_NAMESPACE still carries the CHANGE-ME placeholder — fill your slot id in a"
    echo "local profile copy (docs/partner-run-guide.md, 'Fill your profile')."
    exit 2;;
esac
# INBOUND_NAMESPACE: bilateral prefix the fabric publishes TO the pod (profile-driven, not
# hardcoded to any stack). Default to the pod's own namespace so the rendered ACL is always valid
# even when no bilateral inbound is granted yet.
: "${INBOUND_NAMESPACE:=${PARTNER_NAMESPACE}}"
# ZENOH_FABRIC_ENDPOINT: profile fallback ONLY; the bundle's router_endpoint takes precedence
# (resolved from the bundle-derived profile.toml in step [4/6]).
: "${ZENOH_FABRIC_ENDPOINT:=}"
: "${ZENOH_FABRIC_CERT_CN:=}"
case "${VERIFY_CERT_SLOT_BINDING}" in
  0|1) ;;
  *) echo "VERIFY_CERT_SLOT_BINDING must be 0 or 1"; exit 2;;
esac

echo "==> goat-moon-pod first-boot (profile=${PROFILE}, state=${POD_STATE_DIR})"
echo "    WARNING: ${POD_STATE_DIR} MUST be on the partner's LUKS-encrypted volume."

GOAT_PROFILE_DIR="${POD_STATE_DIR}/goat-cli"
ZENOH_TLS_DIR="${POD_STATE_DIR}/zenoh/tls"
mkdir -p "${POD_STATE_DIR}"/{zenoh/rocksdb,audit,doctor} "${GOAT_PROFILE_DIR}" "${ZENOH_TLS_DIR}"
chmod 700 "${POD_STATE_DIR}" "${GOAT_PROFILE_DIR}"

# --- [1/6] Verify bundle + extract certs + init operator profile (one goat-cli command) ----------
# `goat profile init` verifies the bundle signature against the CA roots THIS HOST trusts, checks
# expiry/activation-deadline, and writes mtls.cert.pem / mtls.key.pem / ca-roots.pem + portal
# token into the profile context dir. This is steps "verify", "extract certs", and "init
# goat-cli" folded into one.
#
# goat compiles in no CA root: the operator adds one, once per goatnet, with
# `goat ca add`. The trust store FOLLOWS THE PROFILE DIR (<profile-dir>/ca-roots), and this
# script pins the profile dir to the pod's state volume — so a root added with a plain
# `goat ca add` lands in ~/.goat (or /root/.goat under sudo) and is never read here. The
# ca-roots.pem the bundle carries is the Zenoh TLS trust laid in step [2/6]; it does not verify
# the bundle that carries it.
echo "==> [1/6] goat profile init (verify bundle + extract mTLS material)"
# Catch an empty trust store before `goat profile init` does, and print the exact fix rather
# than a verification error that reads like a bad bundle. `goat ca ls` counts both sources
# (<profile-dir>/ca-roots and $GOAT_CA_ROOTS). A goat build that predates `goat ca` still
# carries a compiled-in root; the probe fails there and init runs unchanged.
require_ca_root() {
  local profile_dir="$1" display_dir="${2:-$1}" out count
  out="$(GOAT_PROFILE_DIR="${profile_dir}" goat ca ls --json 2>/dev/null)" || return 0
  count="$(printf '%s' "${out}" | sed -n 's/.*"count":[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  [ "${count:-1}" = "0" ] || return 0
  # The onboarding tarball ships the root beside the bundle as <prefix>-goat-cli-ca.pem when the
  # goat side configured it; name that file if it is here, else a placeholder.
  local root="${BUNDLE%.cbor}-ca.pem"
  [ -f "${root}" ] || root="<root.pem>"
  echo "    no CA root is trusted under ${display_dir} — the bundle cannot be verified."
  echo "    Your bundle is fine: verification is local and nothing was consumed. Add your"
  echo "    goatnet's root to the POD's trust store (a root added without GOAT_PROFILE_DIR lands"
  echo "    in ~/.goat, which this script does not read):"
  echo "      sudo GOAT_PROFILE_DIR=${GOAT_PROFILE_DIR} goat ca add ${root}"
  echo "    check the fingerprint it prints against one the goat side gave you separately, then"
  echo "    re-run this script. Where the root comes from and how to check its fingerprint:"
  echo "    docs/partner-run-guide.md, 'Trust your goatnet's CA root'."
  return 3
}
# Resolve only the active context. Searching the whole tree can select a .bak certificate.
active_context_dir() {
  local root="$1" context
  context="$(goat_active_context "$root")" || return 1
  printf '%s/contexts/%s\n' "${root}" "${context}"
}

STAGED_PROFILE=""
CONFIG_TMP=""
staged_profile_cleanup() {
  secure_remove_dir "${STAGED_PROFILE:-}" || return 1
  STAGED_PROFILE=""
}

first_boot_cleanup() {
  local original_status=$? cleanup_failed=0
  if ! staged_profile_cleanup; then
    echo "could not remove protected bundle pre-flight storage" >&2
    cleanup_failed=1
  fi
  if [ -n "${CONFIG_TMP:-}" ] && ! rm -f "${CONFIG_TMP}"; then
    echo "could not remove the temporary router configuration" >&2
    cleanup_failed=1
  fi
  CONFIG_TMP=""
  trap - EXIT
  if [ "${original_status}" -eq 0 ] && [ "${cleanup_failed}" -ne 0 ]; then
    exit 1
  fi
  exit "${original_status}"
}
trap first_boot_cleanup EXIT

check_slot_binding() {
  local cert_path="$1" cert_cn
  if [ "${VERIFY_CERT_SLOT_BINDING}" = "1" ]; then
    cert_cn="$(openssl x509 -in "${cert_path}" -noout -subject -nameopt RFC2253 \
      | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p')"
    [ -n "${cert_cn}" ] || {
      echo "could not read a common name from the certificate:"
      echo "    ${cert_path}"
      return 2
    }
    if [ "${cert_cn}" != "${PARTNER_NAMESPACE}" ]; then
      echo "certificate identity does not match the configured slot ID — refusing to install"
      echo "    certificate CN: ${cert_cn}"
      echo "    slot ID:        ${PARTNER_NAMESPACE}"
      echo "Use the bundle and slot ID from the same onboarding package. The live profile and services were not changed."
      return 2
    fi
    echo "    certificate identity matches slot ID: ${PARTNER_NAMESPACE}"
  else
    echo "    certificate/slot identity binding was not checked (profile setting is off)"
  fi
}

# Remove pre-flight profiles (they hold key copies) left by an unclean shutdown.
for LEFTOVER_INPUT in "${POD_STATE_DIR}"/.bundle-preflight.*; do
  if [ -d "${LEFTOVER_INPUT}" ] && ! secure_remove_dir "${LEFTOVER_INPUT}"; then
    echo "could not remove abandoned protected input storage:" >&2
    echo "    ${LEFTOVER_INPUT}" >&2
    exit 2
  fi
done

# An installed, unchanged bundle is not verified again: goat enforces the activation deadline in
# every `goat profile init`, but the deadline bounds only first use.
BUNDLE_SHA="$(sha256sum "${BUNDLE}" | cut -d' ' -f1)"
BUNDLE_SHA_FILE="${GOAT_PROFILE_DIR}/.bundle.sha256"
LIVE_CTX_DIR="$(active_context_dir "${GOAT_PROFILE_DIR}")" || exit 2
BUNDLE_INSTALLED=0
if [ -f "${LIVE_CTX_DIR}/mtls.cert.pem" ] && [ -f "${BUNDLE_SHA_FILE}" ] \
  && [ "$(cat "${BUNDLE_SHA_FILE}")" = "${BUNDLE_SHA}" ]; then
  BUNDLE_INSTALLED=1
fi

if [ "${BUNDLE_INSTALLED}" = "1" ]; then
  echo "    bundle already installed and unchanged — checking the installed"
  echo "    certificate instead of re-verifying the bundle"
  check_slot_binding "${LIVE_CTX_DIR}/mtls.cert.pem" || exit $?
else
  # Verify and unpack into throwaway encrypted-state storage before touching the live profile or
  # its bundle hash. goat has no read-only bundle verifier; profile init is local-only and gives
  # this check the same signature, lifecycle, and extraction path as the real install.
  STAGED_PROFILE="$(mktemp -d -p "${POD_STATE_DIR}" .bundle-preflight.XXXXXX)" \
    || { echo "could not create bundle pre-flight storage under ${POD_STATE_DIR}"; exit 2; }
  chmod 700 "${STAGED_PROFILE}"
  if [ -d "${GOAT_PROFILE_DIR}/ca-roots" ]; then
    cp -a "${GOAT_PROFILE_DIR}/ca-roots" "${STAGED_PROFILE}/ca-roots"
  fi
  require_ca_root "${STAGED_PROFILE}" "${GOAT_PROFILE_DIR}" || exit $?
  GOAT_PROFILE_DIR="${STAGED_PROFILE}" goat profile init "${BUNDLE}"
  STAGED_CTX_DIR="$(active_context_dir "${STAGED_PROFILE}")" || exit 2
  STAGED_CERT_PATH="${STAGED_CTX_DIR}/mtls.cert.pem"
  [ -f "${STAGED_CERT_PATH}" ] \
    || { echo "bundle pre-flight did not produce an active mtls.cert.pem"; exit 1; }
  check_slot_binding "${STAGED_CERT_PATH}" || exit $?
  staged_profile_cleanup
fi
if [ "${IDENTITY_PREFLIGHT_ONLY:-0}" = "1" ]; then
  echo "==> identity pre-flight complete"
  echo "    The live profile, bundle hash, and services were not changed."
  exit 0
fi

# Idempotent live install. This is reached only after the bundle or installed certificate and
# optional identity binding check succeeded.
if [ ! -f "${LIVE_CTX_DIR}/mtls.cert.pem" ]; then
  require_ca_root "${GOAT_PROFILE_DIR}" || exit $?
  GOAT_PROFILE_DIR="${GOAT_PROFILE_DIR}" goat profile init "${BUNDLE}"
  echo "${BUNDLE_SHA}" > "${BUNDLE_SHA_FILE}"
elif [ "${BUNDLE_INSTALLED}" = "1" ]; then
  echo "    profile present and bundle unchanged — skipping init/rotate (re-render only)"
else
  echo "    profile already present, verified new bundle — rotating (preserves prior at .bak/)"
  require_ca_root "${GOAT_PROFILE_DIR}" || exit $?
  GOAT_PROFILE_DIR="${GOAT_PROFILE_DIR}" goat profile rotate "${BUNDLE}"
  echo "${BUNDLE_SHA}" > "${BUNDLE_SHA_FILE}"
fi
CTX_DIR="$(active_context_dir "${GOAT_PROFILE_DIR}")" || exit 2
CERT_PATH="${CTX_DIR}/mtls.cert.pem"
[ -f "${CERT_PATH}" ] \
  || { echo "goat profile install did not produce active mtls.cert.pem under ${GOAT_PROFILE_DIR}"; exit 1; }

# --- [2/6] Lay the pod's Zenoh mTLS material from the goat-cli-extracted certs -------------------
echo "==> [2/6] laying Zenoh mTLS certs from the goat-cli profile"
# Two containers read these: the router (root) and the audit sink, whose image runs as uid/gid
# 65532 (compose pins `user: "65532:65532"`). Owner root, group 65532, mode 640: readable by both,
# by nothing else. A root-only 600 leaves the sink unable to read its key, and zenoh reports that
# as "Cannot create a new TLS listener ... Permission denied" while it is dialing, not listening.
AUDIT_SINK_GID=65532
install -m 600 -o root "${CTX_DIR}/mtls.cert.pem" "${ZENOH_TLS_DIR}/pod-cert.pem"
install -m 600 -o root "${CTX_DIR}/mtls.key.pem"  "${ZENOH_TLS_DIR}/pod-key.pem"
install -m 600 -o root "${CTX_DIR}/ca-roots.pem"  "${ZENOH_TLS_DIR}/ca-roots.pem"
chown "root:${AUDIT_SINK_GID}" "${ZENOH_TLS_DIR}/pod-cert.pem" \
  "${ZENOH_TLS_DIR}/pod-key.pem" "${ZENOH_TLS_DIR}/ca-roots.pem"
chmod 640 "${ZENOH_TLS_DIR}/pod-cert.pem" "${ZENOH_TLS_DIR}/pod-key.pem" \
  "${ZENOH_TLS_DIR}/ca-roots.pem"

# --- [3/6] Bring up the host mesh daemon (goat-clientd) -----------------------------------------
echo "==> [3/6] importing bundle into goat-clientd (mode=${GOAT_CLIENT_MODE})"
if ! command -v goat-clientd >/dev/null 2>&1; then
  echo "    skipped (goat-clientd not installed; the sandbox uses stock netbird)."
  echo "    Bring the mesh up with netbird, or install goat-clientd and re-run"
  echo "    for the production mesh path."
# A mesh failure here must not kill the later local data-plane start: warn and keep going. The
# router-identity check in step [4/6] still fails closed if the fabric route is unavailable.
# Must stay an `&&` chain, NOT a `( set -e; ... )` subshell: bash suppresses errexit (inner
# set -e included) inside an if/elif condition, so a mid-block failure would fall through and
# enable a bundle-less service that crashloops under Restart=always.
elif
  # goat-client v0.2.0: --import-bundle + --headless + explicit --bundle/--socket/--config
  # confirmed against the release tag (docs/goat-client-v02-contract.md). Keep goat-clientd
  # state on the pod's LUKS volume (POD_STATE_DIR), not its default /var/lib/goat-client.
  install -d -m 0700 "${POD_STATE_DIR}/goat-client" &&
  goat-clientd --import-bundle "${BUNDLE}" --bundle "${POD_STATE_DIR}/goat-client/bundle.cbor" \
    --mode "${GOAT_CLIENT_MODE}" &&
  # Install + enable the host service templated with the profile's mode + pod state dir.
  GOAT_CLIENT_MODE="${GOAT_CLIENT_MODE}" POD_STATE_DIR="${POD_STATE_DIR}" \
    envsubst '${GOAT_CLIENT_MODE} ${POD_STATE_DIR}' \
    < "${POD_DIR}/host/goat-clientd.service.example" \
    > "${SYSTEMD_UNIT_DIR}/goat-clientd.service" &&
  systemctl daemon-reload &&
  systemctl enable --now goat-clientd
then
  echo "    goat-clientd enabled; verify mesh with: goat doctor"
else
  echo "    warning: goat-clientd mesh setup FAILED."
  echo "    Continuing to the fabric identity check."
  echo "    The service needs out-of-band host prep (a goat-client service user + config.toml;"
  echo "    see host/goat-clientd.service.example). Fix the mesh, then re-run this script."
fi

# --- [4/6] Verify the fabric peer and render the pod Zenoh router config -------------------------
# The SIGNED BUNDLE is the single source of truth for the fabric router endpoint: `goat profile
# init` wrote the bundle's goat_cli_extras.router_endpoint into profile.toml. We read it from
# there so the pod follows the bundle, never a stale profile constant. The ZENOH_FABRIC_ENDPOINT
# profile var is a fallback only (hand-driven validation, or a bundle that omitted the field).
echo "==> [4/6] verifying fabric peer and rendering Zenoh router config"
PROFILE_TOML="${CTX_DIR}/profile.toml"
BUNDLE_ROUTER=""
if [ -n "${PROFILE_TOML}" ] && [ -f "${PROFILE_TOML}" ]; then
  BUNDLE_ROUTER="$(sed -n 's/^[[:space:]]*router_endpoint[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${PROFILE_TOML}" | head -1)"
fi
if [ -n "${BUNDLE_ROUTER}" ]; then
  ZENOH_FABRIC_ENDPOINT="${BUNDLE_ROUTER}"
  echo "    router endpoint from bundle: ${ZENOH_FABRIC_ENDPOINT}"
elif [ -n "${ZENOH_FABRIC_ENDPOINT}" ]; then
  echo "    router endpoint from profile fallback (bundle carried none):"
  echo "      ${ZENOH_FABRIC_ENDPOINT}"
else
  echo "ZENOH_FABRIC_ENDPOINT is unset, and the bundle carried no router_endpoint."
  echo "Cannot render the router config."
  exit 1
fi

POD_CERT_CN="$(certificate_cn "${CTX_DIR}/mtls.cert.pem")" || POD_CERT_CN=""
POD_ROUTER_ZID="$(derive_pod_router_zid "${POD_CERT_CN}")" || {
  echo "pod router ID derivation failed: expected 1-32 lowercase hex characters" >&2
  echo "with no leading zero. Goat-side operator: inspect the pod certificate CN." >&2
  echo "Partner: leave the router stopped and send this output to the operator." >&2
  exit 1
}
valid_zenoh_zid "${POD_ROUTER_ZID}" || {
  echo "pod router ID validation failed before rendering." >&2
  exit 1
}

ZENOH_STATE_DIR="${POD_STATE_DIR}/zenoh"
FABRIC_CN_APPLIED_FILE="${ZENOH_STATE_DIR}/.fabric-router-cn.applied"
RECORDED_FABRIC_CN=""
if [ -z "${ZENOH_FABRIC_CERT_CN}" ] && [ -e "${FABRIC_CN_APPLIED_FILE}" ]; then
  if ! RECORDED_FABRIC_CN="$(cat "${FABRIC_CN_APPLIED_FILE}")" || \
    [ -z "${RECORDED_FABRIC_CN}" ]; then
    fabric_identity_error 'the applied router certificate record is unreadable.'
    echo "    Partner: do not replace the record by hand. Ask the goat-side" >&2
    echo "    operator to confirm the endpoint identity, then set the confirmed" >&2
    echo "    ZENOH_FABRIC_CERT_CN in the active profile and re-run first-boot." >&2
    exit 1
  fi
fi

# ACLs must distinguish the upstream router from pod-local clients: only the router may send
# fabric-wide subscription declarations. TLS endpoints are always checked with a CA-verified,
# mutually authenticated handshake; a configured pin must match what the endpoint presents.
# Other transports cannot be inspected by openssl and therefore require an operator-provided pin.
echo "    discovering fabric router certificate identity"
resolve_fabric_certificate_cn "${ZENOH_FABRIC_ENDPOINT}" "${ZENOH_FABRIC_CERT_CN}" \
  "${POD_CERT_CN}" "${CTX_DIR}/mtls.cert.pem" "${CTX_DIR}/mtls.key.pem" \
  "${CTX_DIR}/ca-roots.pem" || exit 1
check_fabric_identity_continuity "${FABRIC_ROUTER_CERT_CN}" \
  "${ZENOH_FABRIC_CERT_CN}" "${RECORDED_FABRIC_CN}" || exit 1
echo "    fabric router certificate CN: ${FABRIC_ROUTER_CERT_CN}"
export ZENOH_LISTEN_PORT ZENOH_FABRIC_ENDPOINT PARTNER_NAMESPACE INBOUND_NAMESPACE
export POD_CERT_CN POD_ROUTER_ZID FABRIC_ROUTER_CERT_CN
export POD_CERT_PEM="/etc/zenoh/tls/pod-cert.pem"   # in-container paths (compose mounts ZENOH_TLS_DIR ro)
export POD_KEY_PEM="/etc/zenoh/tls/pod-key.pem"
export CA_ROOTS_PEM="/etc/zenoh/tls/ca-roots.pem"
CONFIG_OUT="${POD_STATE_DIR}/zenoh/config.json5"
BASE_CONFIG_OUT="${ZENOH_STATE_DIR}/config.base.json5"
CONFIG_APPLIED_SHA_FILE="${ZENOH_STATE_DIR}/.config.applied.sha256"
LAST_GOOD_CONFIG="${ZENOH_STATE_DIR}/config.last-known-good.json5"
LAST_GOOD_IDENTITIES="${ZENOH_STATE_DIR}/.config.last-known-good.identities"
APPLIED_CONFIG_SHA="$(cat "${CONFIG_APPLIED_SHA_FILE}" 2>/dev/null || true)"
CONFIG_WAS_APPLIED=0

write_identity_pair() {
  local path="$1" pod_cn="$2" fabric_cn="$3" temporary
  temporary="$(mktemp "${path}.tmp.XXXXXX")"
  chmod 600 "${temporary}"
  printf '%s\n%s\n' "${pod_cn}" "${fabric_cn}" >"${temporary}"
  mv "${temporary}" "${path}"
}

# One JSON string; refuses characters that would need escaping, so a profile value cannot
# change the structure of the file.
json_string() {
  case "$1" in
    *'"'*|*\\*|*[[:cntrl:]]*) echo "profile value contains a quote or backslash: $1" >&2; return 1;;
  esac
  printf '"%s"' "$1"
}

# goat-pod-api configuration, from the profile and the paths first-boot uses (host paths).
write_pod_api_config() {
  local path="$1" listen="" addr temporary health=false
  local slot state url ca token signer cert key roots fabric page base live good applied profile
  for addr in ${POD_API_LISTEN:-127.0.0.1:8447}; do
    addr="$(json_string "${addr}")" || return 1
    listen="${listen:+${listen}, }${addr}"
  done
  [ "${POD_API_HEALTH_PUBLISH:-0}" = 1 ] && health=true
  [ -f "${POD_API_SIGNER_CERT}" ] || {
    echo "POD_API_SIGNER_CERT names a file that does not exist: ${POD_API_SIGNER_CERT}" >&2
    return 1
  }
  slot="$(json_string "${POD_SLOT:-${PARTNER_NAMESPACE}}")" || return 1
  state="$(json_string "${POD_STATE_DIR}/pod-api")" || return 1
  url="$(json_string "${POD_API_PORTAL_URL:-}")" || return 1
  ca="$(json_string "${POD_API_PORTAL_CA:-}")" || return 1
  # The pod's portal API key stays in the goat profile; the config names the file only.
  token="$(json_string "${CTX_DIR}/portal.token")" || return 1
  signer="$(json_string "${POD_API_SIGNER_CERT}")" || return 1
  cert="$(json_string "${ZENOH_TLS_DIR}/pod-cert.pem")" || return 1
  key="$(json_string "${ZENOH_TLS_DIR}/pod-key.pem")" || return 1
  roots="$(json_string "${ZENOH_TLS_DIR}/ca-roots.pem")" || return 1
  fabric="$(json_string "${FABRIC_ROUTER_CERT_CN}")" || return 1
  page="$(json_string "${POD_API_GATEPOST_PAGE:-/usr/local/share/goat-pod-api/gatepost.html}")" || return 1
  base="$(json_string "${BASE_CONFIG_OUT}")" || return 1
  live="$(json_string "${CONFIG_OUT}")" || return 1
  good="$(json_string "${LAST_GOOD_CONFIG}")" || return 1
  applied="$(json_string "${CONFIG_APPLIED_SHA_FILE}")" || return 1
  profile="$(json_string "${GOAT_PROFILE_DIR}")" || return 1
  install -d -m 0700 "$(dirname "${path}")"
  temporary="$(mktemp "${path}.tmp.XXXXXX")"
  chmod 600 "${temporary}"
  cat > "${temporary}" <<EOF_POD_API
{
  "pod_slot": ${slot},
  "state_dir": ${state},
  "portal_url": ${url},
  "portal_ca": ${ca},
  "portal_token_file": ${token},
  "portal_signer_cert": ${signer},
  "pod_cert": ${cert},
  "pod_key": ${key},
  "ca_roots": ${roots},
  "listen": [${listen}],
  "fabric_router_cn": ${fabric},
  "gatepost_page": ${page},
  "router": {
    "base_config": ${base},
    "config": ${live},
    "last_good": ${good},
    "applied_sha_file": ${applied},
    "container": "goat-moon-zenoh-router"
  },
  "health_publish": {"enabled": ${health}, "env": {"GOAT_PROFILE_DIR": ${profile}}}
}
EOF_POD_API
  mv "${temporary}" "${path}"
}

config_subject_cn() {
  local path="$1" subject="$2"
  awk -v subject="${subject}" '
    index($0, "id: \"" subject "\"") { found=1; next }
    found && /cert_common_names:/ {
      split($0, fields, "\"")
      print fields[2]
      exit
    }
    found && /},/ { exit }
  ' "${path}"
}

if [ -f "${CONFIG_OUT}" ] && [ -n "${APPLIED_CONFIG_SHA}" ] && \
  [ "$(sha256sum "${CONFIG_OUT}" | cut -d' ' -f1)" = "${APPLIED_CONFIG_SHA}" ]; then
  CONFIG_WAS_APPLIED=1
fi

CONFIG_TMP="$(mktemp "${CONFIG_OUT}.tmp.XXXXXX")"
envsubst \
  '${ZENOH_LISTEN_PORT} ${POD_ROUTER_ZID} ${ZENOH_FABRIC_ENDPOINT} ${PARTNER_NAMESPACE} ${INBOUND_NAMESPACE} ${POD_CERT_CN} ${FABRIC_ROUTER_CERT_CN} ${POD_CERT_PEM} ${POD_KEY_PEM} ${CA_ROOTS_PEM}' \
  < "${ZENOH_ROUTER_TEMPLATE}" \
  > "${CONFIG_TMP}"
# The template rendering is the base goat-pod-api adds carried sources to (ADR 1251).
install -m 600 "${CONFIG_TMP}" "${BASE_CONFIG_OUT}"
POD_API_CONFIG="${POD_STATE_DIR}/pod-api/config.json"
POD_API_ENABLED=0
# Install the pinned goat-pod-api release (host/goat-pod-api.pin): signature and digests are
# checked before anything is installed, and a failed check stops first-boot. POD_API_INSTALL=0
# keeps a build already on PATH instead.
if [ -n "${POD_API_SIGNER_CERT:-}" ] && [ "${POD_API_INSTALL:-1}" = 1 ]; then
  echo "    installing the pinned goat-pod-api release"
  install_status=0
  "${POD_DIR}/host/install-goat-pod-api.sh" "${POD_DIR}/host/goat-pod-api.pin" || install_status=$?
  case "${install_status}" in
    0) POD_API_BIN="${GOAT_POD_API_BIN_DIR:-/usr/local/bin}/goat-pod-api" ;;
    3) echo "    no goat-pod-api release is pinned; using goat-pod-api from PATH if present" ;;
    *) echo "goat-pod-api was not installed; the router config and services were not changed." >&2
       exit 1 ;;
  esac
fi
if [ -n "${POD_API_BIN}" ] && [ -n "${POD_API_SIGNER_CERT:-}" ]; then
  write_pod_api_config "${POD_API_CONFIG}" || exit 2
  POD_API_ENABLED=1
  echo "    adding carried sources to the router config (goat-pod-api)"
  if ! "${POD_API_BIN}" render --config "${POD_API_CONFIG}" --out "${CONFIG_TMP}"; then
    echo "    warning: goat-pod-api could not render carried sources; the router config"
    echo "    carries only this pod's own slot until goat-pod-api applies its rules."
    install -m 600 "${BASE_CONFIG_OUT}" "${CONFIG_TMP}"
  fi
elif [ -n "${POD_API_BIN}" ]; then
  echo "    goat-pod-api is installed but POD_API_SIGNER_CERT is not set in the profile;"
  echo "    the pod carries only its own slot (docs/devices-behind-a-pod.md)."
fi
if [ ! -f "${CONFIG_OUT}" ] || ! cmp -s "${CONFIG_TMP}" "${CONFIG_OUT}"; then
  if [ "${CONFIG_WAS_APPLIED}" -eq 1 ]; then
    install -m 600 "${CONFIG_OUT}" "${LAST_GOOD_CONFIG}"
    LAST_GOOD_POD_CN="$(config_subject_cn "${CONFIG_OUT}" pod-peer)"
    LAST_GOOD_FABRIC_CN="$(config_subject_cn "${CONFIG_OUT}" fabric-peer)"
    if safe_certificate_cn "${LAST_GOOD_POD_CN}" && \
      safe_certificate_cn "${LAST_GOOD_FABRIC_CN}"; then
      write_identity_pair "${LAST_GOOD_IDENTITIES}" \
        "${LAST_GOOD_POD_CN}" "${LAST_GOOD_FABRIC_CN}"
    else
      rm -f "${LAST_GOOD_IDENTITIES}"
    fi
    echo "    saved the last known good router config"
  fi
  chmod 600 "${CONFIG_TMP}"
  mv "${CONFIG_TMP}" "${CONFIG_OUT}"
  CONFIG_TMP=""
  echo "    wrote changed ${CONFIG_OUT}"
else
  rm -f "${CONFIG_TMP}"
  CONFIG_TMP=""
  echo "    router config unchanged: ${CONFIG_OUT}"
fi
CONFIG_SHA="$(sha256sum "${CONFIG_OUT}" | cut -d' ' -f1)"
RELOAD_REQUIRED=0
[ "${CONFIG_SHA}" = "${APPLIED_CONFIG_SHA}" ] || RELOAD_REQUIRED=1

# --- [5/6] Render compose .env and start the data plane -----------------------------------------
echo "==> [5/6] writing compose/.env and starting the data plane"
# The audit sink dials the router on loopback: both run with network_mode: host, and the router
# listens on 0.0.0.0. This is the ONE place the local endpoint is decided; it overrides any
# ZENOH_LOCAL_ENDPOINT a profile carries.
ZENOH_LOCAL_HOST="127.0.0.1"
ENV_OUT="${POD_DIR}/compose/.env"
{
  echo "# generated by first-boot.sh on $(hostname) — do not edit by hand"
  echo "POD_STATE_DIR=${POD_STATE_DIR}"
  echo "PARTNER_NAMESPACE=${PARTNER_NAMESPACE}"
  echo "POD_ID=${POD_ID:-moon-pod}"
  echo "ZENOH_LOCAL_ENDPOINT=tls/${ZENOH_LOCAL_HOST}:${ZENOH_LISTEN_PORT}"
  echo "ZENOH_LISTEN_PORT=${ZENOH_LISTEN_PORT}"
  echo "ZENOH_LOG=${ZENOH_LOG:-info}"
} > "${ENV_OUT}"
chmod 600 "${ENV_OUT}"
echo "    wrote ${ENV_OUT}"

ROUTER_EXISTED=0
ROUTER_WAS_RUNNING=0
ROUTER_STATE_BEFORE="$(docker inspect -f '{{.State.Status}}' \
  goat-moon-zenoh-router 2>/dev/null || true)"
[ -z "${ROUTER_STATE_BEFORE}" ] || ROUTER_EXISTED=1
[ "${ROUTER_STATE_BEFORE}" = "running" ] && ROUTER_WAS_RUNNING=1
( cd "${POD_DIR}/compose" && docker compose up -d zenoh-router )
ROUTER_STATE_AFTER_UP="$(docker inspect -f '{{.State.Status}}' \
  goat-moon-zenoh-router 2>/dev/null || true)"
ROUTER_HEALTH_AFTER_UP="$(docker inspect \
  -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
  goat-moon-zenoh-router 2>/dev/null || true)"
if [ "${ROUTER_EXISTED}" -eq 1 ] && \
  { [ "${ROUTER_STATE_AFTER_UP}" != "running" ] || \
    [ "${ROUTER_HEALTH_AFTER_UP}" != "healthy" ]; }; then
  echo "    router was not running and healthy — restarting it now"
  ( cd "${POD_DIR}/compose" && docker compose restart zenoh-router )
elif [ "${RELOAD_REQUIRED}" -eq 1 ] && [ "${ROUTER_WAS_RUNNING}" -eq 1 ]; then
  echo "    router has not loaded this config — restarting it now"
  ( cd "${POD_DIR}/compose" && docker compose restart zenoh-router )
elif [ "${RELOAD_REQUIRED}" -eq 0 ]; then
  echo "    router already loaded this config — no router restart needed"
fi

ROUTER_HEALTH=""
ROUTER_FAILURE_KIND=""

wait_for_router_health() {
  local _
  ROUTER_FAILURE_KIND=""
  for _ in $(seq 1 60); do
    ROUTER_STATE="$(docker inspect -f '{{.State.Status}}' \
      goat-moon-zenoh-router 2>/dev/null || true)"
    ROUTER_HEALTH="$(docker inspect \
      -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' \
      goat-moon-zenoh-router 2>/dev/null || true)"
    if [ "${ROUTER_STATE}" = "running" ] && [ "${ROUTER_HEALTH}" = "healthy" ]; then
      return 0
    fi
    case "${ROUTER_STATE}" in
      created|exited|dead|restarting|removing|"")
        ROUTER_FAILURE_KIND=load
        return 1
        ;;
    esac
    sleep 2
  done
  ROUTER_FAILURE_KIND=health
  return 1
}

report_router_failure() {
  if [ "${ROUTER_FAILURE_KIND}" = load ]; then
    echo "router failed to load the rendered config (state=${ROUTER_STATE:-missing})." >&2
  else
    echo "router did not become healthy after loading the rendered config." >&2
  fi
  docker logs goat-moon-zenoh-router 2>&1 | tail -n 20 >&2 || true
}

router_failure_guidance() {
  echo "Owner: the partner checks profile inputs; the goat-side operator owns" >&2
  echo "a confirmed problem with the router template or the fabric endpoint." >&2
  echo "Partner next step: fix a bad local profile value and re-run first-boot," >&2
  echo "or send the router log lines above to the goat-side operator." >&2
}

record_applied_config() {
  local sha="$1" temporary
  temporary="$(mktemp "${CONFIG_APPLIED_SHA_FILE}.tmp.XXXXXX")"
  chmod 600 "${temporary}"
  printf '%s\n' "${sha}" >"${temporary}"
  mv "${temporary}" "${CONFIG_APPLIED_SHA_FILE}"
}

restore_last_known_good() {
  local saved_pod_cn saved_fabric_cn restored_sha
  [ -f "${LAST_GOOD_CONFIG}" ] || return 2

  saved_pod_cn="$(sed -n '1p' "${LAST_GOOD_IDENTITIES}" 2>/dev/null || true)"
  saved_fabric_cn="$(sed -n '2p' "${LAST_GOOD_IDENTITIES}" 2>/dev/null || true)"
  if [ ! -r "${LAST_GOOD_IDENTITIES}" ] || \
    ! safe_certificate_cn "${saved_pod_cn}" || \
    ! safe_certificate_cn "${saved_fabric_cn}"; then
    echo "The previous configuration was not restored because its saved" >&2
    echo "certificate identities could not be verified." >&2
    if ( cd "${POD_DIR}/compose" && docker compose stop zenoh-router ); then
      echo "The router is stopped rather than re-admitting an unverified identity." >&2
    else
      echo "First-boot could not stop the router; it is not safe to leave running." >&2
      echo "Partner next step: run sudo docker stop goat-moon-zenoh-router now." >&2
    fi
    echo "Owner: the goat-side operator confirms the intended identities." >&2
    echo "Partner next step: keep the router stopped, obtain that confirmation," >&2
    echo "then correct the profile or bundle and re-run first-boot." >&2
    return 1
  fi
  if [ "${saved_pod_cn}" != "${POD_CERT_CN}" ] || \
    [ "${saved_fabric_cn}" != "${FABRIC_ROUTER_CERT_CN}" ]; then
    echo "The previous configuration was not restored because its POD or" >&2
    echo "fabric certificate identity differs from the current inputs." >&2
    if ( cd "${POD_DIR}/compose" && docker compose stop zenoh-router ); then
      echo "The router is stopped rather than re-admitting an old identity." >&2
    else
      echo "First-boot could not stop the router; it is not safe to leave running." >&2
      echo "Partner next step: run sudo docker stop goat-moon-zenoh-router now." >&2
    fi
    echo "Owner: the goat-side operator confirms the intended identities." >&2
    echo "Partner next step: keep the router stopped, obtain that confirmation," >&2
    echo "then correct the profile or bundle and re-run first-boot." >&2
    return 1
  fi

  install -m 600 "${LAST_GOOD_CONFIG}" "${CONFIG_OUT}"
  echo "    restoring the last known good router configuration" >&2
  ( cd "${POD_DIR}/compose" && docker compose restart zenoh-router )
  if wait_for_router_health; then
    restored_sha="$(sha256sum "${CONFIG_OUT}" | cut -d' ' -f1)"
    record_applied_fabric_cn "${FABRIC_CN_APPLIED_FILE}" "${saved_fabric_cn}"
    record_applied_config "${restored_sha}"
    echo "The previous configuration is running again." >&2
    router_failure_guidance
    return 0
  fi

  report_router_failure
  echo "The restored configuration also failed." >&2
  if ( cd "${POD_DIR}/compose" && docker compose stop zenoh-router ); then
    echo "The router is stopped." >&2
  else
    echo "First-boot could not stop the router; it is not safe to leave running." >&2
    echo "Partner next step: run sudo docker stop goat-moon-zenoh-router now." >&2
  fi
  echo "Owner: the goat-side operator investigates the router and host state." >&2
  echo "Partner next step: send both sets of router log lines to the operator." >&2
  return 1
}

if ! wait_for_router_health; then
  report_router_failure
  echo "The new configuration was rejected." >&2
  if restore_last_known_good; then
    exit 1
  else
    restore_status=$?
    if [ "${restore_status}" -eq 2 ]; then
      router_failure_guidance
    fi
    exit 1
  fi
fi
record_applied_fabric_cn "${FABRIC_CN_APPLIED_FILE}" "${FABRIC_ROUTER_CERT_CN}"
record_applied_config "${CONFIG_SHA}"
( cd "${POD_DIR}/compose" && docker compose up -d )
echo "    audit sink metrics:"
echo "      curl -s --max-time 5 http://127.0.0.1:9303/metrics | grep ^goat_audit_"

# --- [6/6] Install the host services: goat-doctor probe timer, goat-pod-api ---------------------
# goat presence was hard-checked at the top of the script. systemd is NOT guaranteed: a
# container, a chroot, or a minimal host has no systemctl (or has the binary with no running
# systemd), and dying here under `set -e` would exit non-zero with the data plane already up.
# Guard like step [3/6]: detect, skip loudly, leave the manual path on screen.
echo "==> [6/6] installing host services (goat-doctor timer, goat-pod-api)"
if ! command -v systemctl >/dev/null 2>&1 || [ ! -d "${SYSTEMD_RUNTIME_DIR}" ]; then
  echo "    skipped (no running systemd on this host). The data plane is up; run the health"
  echo "    probe manually or from your own scheduler:"
  echo "      GOAT_PROFILE_DIR=${GOAT_PROFILE_DIR} ${POD_DIR}/host/goat-doctor.sh"
  if [ "${POD_API_ENABLED}" = 1 ]; then
    echo "    run the carriage service from your own supervisor:"
    echo "      ${POD_API_BIN} serve --config ${POD_API_CONFIG}"
  fi
else
  DOCTOR_SH="${POD_DIR}/host/goat-doctor.sh"
  # Render the unit with the real script path + profile dir + pod state dir (honors a custom
  # POD_STATE_DIR; no hardcoded paths).
  GOAT_PROFILE_DIR="${GOAT_PROFILE_DIR}" POD_STATE_DIR="${POD_STATE_DIR}" DOCTOR_SH="${DOCTOR_SH}" \
    envsubst '${GOAT_PROFILE_DIR} ${POD_STATE_DIR} ${DOCTOR_SH}' \
    < "${POD_DIR}/host/goat-doctor.service.example" \
    > "${SYSTEMD_UNIT_DIR}/goat-doctor.service"
  cp "${POD_DIR}/host/goat-doctor.timer.example" \
    "${SYSTEMD_UNIT_DIR}/goat-doctor.timer"
  systemctl daemon-reload
  systemctl enable --now goat-doctor.timer
  echo "    goat-doctor.timer enabled"
  echo "    status blob: ${POD_STATE_DIR}/doctor/status.json"
  if [ "${POD_API_ENABLED}" = 1 ]; then
    # shellcheck disable=SC2016  # envsubst takes the variable names literally
    POD_API_BIN="${POD_API_BIN}" POD_API_CONFIG="${POD_API_CONFIG}" POD_STATE_DIR="${POD_STATE_DIR}" \
      envsubst '${POD_API_BIN} ${POD_API_CONFIG} ${POD_STATE_DIR}' \
      < "${POD_DIR}/host/goat-pod-api.service.example" \
      > "${SYSTEMD_UNIT_DIR}/goat-pod-api.service"
    systemctl daemon-reload
    systemctl enable goat-pod-api.service
    # Restart so a changed configuration or binary takes effect.
    systemctl restart goat-pod-api.service
    echo "    goat-pod-api enabled; status: goat pod status (or curl the local API)"
  fi
fi

echo "==> first-boot complete."
echo "    health:  GOAT_PROFILE_DIR=${GOAT_PROFILE_DIR} goat doctor"
echo "    local data endpoint: tls/127.0.0.1:${ZENOH_LISTEN_PORT}"
echo "    publish/subscribe with your application or a client under clients/;"
echo "      publish namespace: ${PARTNER_NAMESPACE}/**"
echo "      inbound namespace: ${INBOUND_NAMESPACE}/**"
echo "    Do not stop the router for a delivery check:"
echo "      that bypasses the pod data path."
