#!/usr/bin/env bash
# audit-sink-local.sh — stand the pod up on THIS host through host/first-boot.sh, with a
# synthetic CA and pod leaf in place of a goat-side enrollment bundle, and prove the audit sink
# starts on first-boot's plain `docker compose up` and runs: container up and not restarting, metrics on :9303, session open, and a publish into the
# pod's namespace counted by goat_audit_samples_total.
#
# For a disposable Linux host with Docker (CI runs it on every PR: .github/workflows/
# audit-sink.yml). It runs first-boot as root, writes compose/.env, and starts the compose
# stack; the trap stops the stack and removes what it created.
#
# The synthetic leaf matches what a machine enrollment mints: ECDSA P-256, CN = the slot anchor,
# a DNS and a URI SAN, EKU serverAuth+clientAuth (the pod router presents the same leaf as its
# LISTEN certificate, so it needs serverAuth). LEAF_EKU=clientAuth reproduces a leaf that lacks it.
#
# Environment:
#   LEAF_EKU        EKU set for the synthetic leaf (default serverAuth,clientAuth).
#   PUBLISH_COUNT   samples to publish and expect counted (default 5).
set -euo pipefail

POD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=host/fabric-peer-identity.sh
source "${POD_DIR}/host/fabric-peer-identity.sh"
LEAF_EKU="${LEAF_EKU:-serverAuth,clientAuth}"
PUBLISH_COUNT="${PUBLISH_COUNT:-5}"
SLOT="7f3c2a1000004000800000000000c1a0"         # synthetic slot anchor
PROFILE_NAME="ci-local"                       # profiles/*-local/ is gitignored
WORK="$(mktemp -d)"
STATE="${WORK}/state"
SINK=goat-moon-audit-sink
ROUTER=goat-moon-zenoh-router
UPSTREAM="moon-test-fabric-router-$(basename "$WORK" | tr -cd 'A-Za-z0-9')"
METRICS=http://127.0.0.1:9303/metrics
ZENOH_IMAGE="eclipse/zenoh:1.9.0@sha256:157965d71e0bfd0a044d76a985ff0e5c306ad3968929168fb9678cd2a7fec23f"
ROUTER_TEMPLATE="${POD_DIR}/host/zenoh-router.json5.tmpl"

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; dump; exit 1; }
dump() {
  log "docker ps"; docker ps -a --format '{{.Names}}\t{{.Status}}' || true
  for c in "$ROUTER" "$SINK"; do
    log "logs: $c"; docker logs "$c" 2>&1 | tail -n 80 || true
  done
}
cleanup() {
  ( cd "${POD_DIR}/compose" && sudo docker compose down -v --remove-orphans ) >/dev/null 2>&1 || true
  docker rm -f "$UPSTREAM" >/dev/null 2>&1 || true
  sudo systemctl disable --now goat-doctor.timer >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/goat-doctor.service /etc/systemd/system/goat-doctor.timer
  sudo rm -rf "${WORK}" "${POD_DIR}/profiles/${PROFILE_NAME}" "${POD_DIR}/compose/.env"
}
trap cleanup EXIT

for t in docker openssl envsubst curl python3 sudo timeout; do
  command -v "$t" >/dev/null 2>&1 || { echo "required tool not found: $t"; exit 2; }
done

# --- 1. Synthetic mint: CA + pod leaf -------------------------------------------------------------
log "minting a synthetic CA and pod leaf (EKU ${LEAF_EKU})"
MINT="${WORK}/mint"; mkdir -p "$MINT"
openssl ecparam -name prime256v1 -genkey -noout -out "$MINT/ca.key" 2>/dev/null
openssl req -x509 -new -key "$MINT/ca.key" -sha256 -days 2 -subj "/CN=synthetic-goatnet-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out "$MINT/ca.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$MINT/leaf.key.sec1" 2>/dev/null
openssl pkcs8 -topk8 -nocrypt -in "$MINT/leaf.key.sec1" -out "$MINT/leaf.key"
openssl req -new -key "$MINT/leaf.key" -subj "/CN=${SLOT}" -out "$MINT/leaf.csr" 2>/dev/null
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=%s\nsubjectAltName=DNS:client.%s.synthetic.peer,URI:urn:goat:synthetic:org=%s\n' \
  "$LEAF_EKU" "$SLOT" "$SLOT" > "$MINT/leaf.ext"
openssl x509 -req -in "$MINT/leaf.csr" -CA "$MINT/ca.pem" -CAkey "$MINT/ca.key" \
  -CAcreateserial -CAserial "$MINT/ca.srl" \
  -days 2 -sha256 -extfile "$MINT/leaf.ext" -out "$MINT/leaf.pem" 2>/dev/null
openssl x509 -in "$MINT/leaf.pem" -noout -ext extendedKeyUsage | tail -n 1 | sed 's/^ */    leaf EKU: /'

# A synthetic upstream exercises first-boot's real CA-verified CN discovery. It stays up for the
# pod router to connect to, so this test needs no bypass or pre-trusted CN.
mint_router_leaf() {
  local name="$1" cn="$2"
  openssl ecparam -name prime256v1 -genkey -noout -out "$MINT/${name}.key" 2>/dev/null
  openssl req -new -key "$MINT/${name}.key" -subj "/CN=${cn}" \
    -out "$MINT/${name}.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=IP:127.0.0.1\n' \
    > "$MINT/${name}.ext"
  openssl x509 -req -in "$MINT/${name}.csr" -CA "$MINT/ca.pem" -CAkey "$MINT/ca.key" \
    -CAcreateserial -CAserial "$MINT/ca.srl" -days 2 -sha256 \
    -extfile "$MINT/${name}.ext" -out "$MINT/${name}.pem" 2>/dev/null
}
mint_router_leaf router synthetic-fabric-router
mint_router_leaf router-next synthetic-fabric-router-next
FABRIC_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
cat > "$MINT/upstream.json5" <<EOF
{
  mode: "router",
  listen: { endpoints: ["tls/0.0.0.0:${FABRIC_PORT}"] },
  scouting: { multicast: { enabled: false } },
  transport: { link: { tls: {
    listen_certificate: "/work/router.pem",
    listen_private_key: "/work/router.key",
    root_ca_certificate: "/work/ca.pem",
    enable_mtls: true,
  } } },
}
EOF
docker run -d --name "$UPSTREAM" --network host -v "$MINT:/work:ro" \
  "$ZENOH_IMAGE" -c /work/upstream.json5 >/dev/null
for _ in $(seq 1 30); do
  if [ "$(discover_fabric_certificate_cn "tls/127.0.0.1:${FABRIC_PORT}" \
    "$MINT/leaf.pem" "$MINT/leaf.key" "$MINT/ca.pem" 2 2>/dev/null || true)" = \
    synthetic-fabric-router ]; then
    break
  fi
  sleep 1
done
[ "$(discover_fabric_certificate_cn "tls/127.0.0.1:${FABRIC_PORT}" \
  "$MINT/leaf.pem" "$MINT/leaf.key" "$MINT/ca.pem" 2 2>/dev/null || true)" = \
  synthetic-fabric-router ] || fail "synthetic fabric router did not become ready"

# --- 2. Stub `goat` in place of the goat-side bundle path ---------------------------
# first-boot's step [1/6] calls `goat ca ls` and `goat profile init <bundle>`; the stub writes the
# synthetic material where `goat profile init` writes the real thing.
STUBS="${WORK}/bin"; mkdir -p "$STUBS"
cat > "$STUBS/goat" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "ca ls")        echo '{"count":1}' ;;
  "profile init") d="\${GOAT_PROFILE_DIR}/contexts/default"; mkdir -p "\$d"
                  cp "${MINT}/leaf.pem" "\$d/mtls.cert.pem"; cp "${MINT}/leaf.key" "\$d/mtls.key.pem"
                  cp "${MINT}/ca.pem" "\$d/ca-roots.pem"
                  echo 'router_endpoint = "tls/127.0.0.1:${FABRIC_PORT}"' > "\$d/profile.toml" ;;
  *)              exit 0 ;;
esac
EOF
chmod +x "$STUBS"/*

# --- 3. A filled local profile, then first-boot as a partner runs it ---------------------------------
mkdir -p "${POD_DIR}/profiles/${PROFILE_NAME}"
sed -e "s|^PARTNER_NAMESPACE=.*|PARTNER_NAMESPACE=${SLOT}|" "${POD_DIR}/profiles/zagros/profile.env" \
  > "${POD_DIR}/profiles/${PROFILE_NAME}/profile.env"
printf 'POD_STATE_DIR=%s\nPOD_ID=ci-pod\nZENOH_FABRIC_CERT_CN=\n' "$STATE" \
  >> "${POD_DIR}/profiles/${PROFILE_NAME}/profile.env"
: > "${WORK}/pod.cbor"   # placeholder bundle; the stub never reads it

INVALID_ROUTER_TEMPLATE="${WORK}/invalid-zenoh-router.json5.tmpl"
cp "$ROUTER_TEMPLATE" "$INVALID_ROUTER_TEMPLATE"
printf '\nthis is not valid json5\n' >> "$INVALID_ROUTER_TEMPLATE"

log "reporting an unhealthy router on the first run"
# The invoking user owns WORK; only first-boot itself needs sudo.
# shellcheck disable=SC2024
if sudo env PATH="${STUBS}:${PATH}" \
  ZENOH_ROUTER_TEMPLATE="$INVALID_ROUTER_TEMPLATE" \
  bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor" \
  >"${WORK}/failed-first-run.log" 2>&1; then
  fail "first-boot accepted an invalid router config on the first run"
fi
grep -Eq 'router failed to load|router did not become healthy' \
  "${WORK}/failed-first-run.log" \
  || fail "first-boot did not identify the unhealthy router on the first run"
grep -Fq 'Owner: the partner checks profile inputs' \
  "${WORK}/failed-first-run.log" \
  || fail "first-boot gave no owner for the first-run router failure"
grep -Fq 'Partner next step: fix a bad local profile value' \
  "${WORK}/failed-first-run.log" \
  || fail "first-boot gave no partner next step for the first-run router failure"
[ ! -e "$STATE/zenoh/.config.applied.sha256" ] \
  || fail "first-boot recorded the invalid first-run config as applied"

log "host/first-boot.sh ${PROFILE_NAME}"
sudo env PATH="${STUBS}:${PATH}" bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor"
sudo grep "^ZENOH_LOCAL_ENDPOINT=" "${POD_DIR}/compose/.env" | sed 's/^/    /'
rendered_sha="$(sudo sha256sum "$STATE/zenoh/config.json5" | cut -d' ' -f1)"
applied_sha="$(sudo cat "$STATE/zenoh/.config.applied.sha256")"
[ "$rendered_sha" = "$applied_sha" ] || fail "first-boot did not record the config loaded by the router"
[ "$(sudo cat "$STATE/zenoh/.fabric-router-cn.applied")" = synthetic-fabric-router ] \
  || fail "first-boot did not record the healthy fabric router identity"
router_zid="$(printf '%s' "${SLOT}|moon-pod-router" | sha256sum | cut -c1-32 | sed 's/^0*//')"
sudo grep -Fq "id: \"${router_zid}\"" "$STATE/zenoh/config.json5" \
  || fail "first-boot did not render the deterministic pod router ZID"
[ "$(docker inspect -f '{{.State.Health.Status}}' "$ROUTER")" = healthy ] \
  || fail "the router did not start with its deterministic ZID"
for tls_file in pod-cert.pem pod-key.pem ca-roots.pem; do
  tls_mode="$(sudo stat -c '%u:%g %a' "$STATE/zenoh/tls/$tls_file")"
  [ "$tls_mode" = '0:65532 640' ] \
    || fail "$tls_file has ownership/mode $tls_mode, expected 0:65532 640"
done

log "re-running first-boot with an unchanged healthy router"
unchanged_started_before="$(docker inspect -f '{{.State.StartedAt}}' "$ROUTER")"
unchanged_applied_before="$(sudo cat "$STATE/zenoh/.config.applied.sha256")"
# The invoking user owns WORK; only first-boot itself needs sudo.
# shellcheck disable=SC2024
sudo env PATH="${STUBS}:${PATH}" \
  bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor" \
  >"${WORK}/unchanged-rerun.log" 2>&1
unchanged_started_after="$(docker inspect -f '{{.State.StartedAt}}' "$ROUTER")"
unchanged_applied_after="$(sudo cat "$STATE/zenoh/.config.applied.sha256")"
[ "$unchanged_started_before" = "$unchanged_started_after" ] \
  || fail "unchanged first-boot re-run restarted the healthy router"
[ "$unchanged_applied_before" = "$unchanged_applied_after" ] \
  || fail "unchanged first-boot re-run changed the applied config hash"
grep -Fq 'router config unchanged' "${WORK}/unchanged-rerun.log" \
  || fail "unchanged first-boot re-run did not report the unchanged router config"
grep -Fq 'router already loaded this config — no router restart needed' \
  "${WORK}/unchanged-rerun.log" \
  || fail "unchanged first-boot re-run did not explain why no restart was needed"
sudo grep -Fq "id: \"${router_zid}\"" "$STATE/zenoh/config.json5" \
  || fail "the same pod certificate CN rendered a different router ZID"

# --- 4. Assertions -----------------------------------------------------------------------------------
metric() {  # sum of every sample of a metric family
  curl -fsS "$METRICS" 2>/dev/null | awk -v m="$1" '$1 ~ "^"m"({|$)" {s+=$2} END {print s+0}'
}

log "waiting for the audit sink's session (session_state == 1)"
for _ in $(seq 1 30); do
  [ "$(metric goat_audit_subscriber_session_state)" = 1 ] && break
  sleep 2
done
[ "$(metric goat_audit_subscriber_session_state)" = 1 ] || fail "audit sink never reported session_state 1"

sleep 20   # let a crash-loop show itself
running="$(docker inspect -f '{{.State.Running}}' "$SINK")"
restarts="$(docker inspect -f '{{.RestartCount}}' "$SINK")"
log "audit sink: running=${running} restarts=${restarts}"
[ "$running" = true ] && [ "$restarts" = 0 ] || fail "audit sink is not steadily running"

log "publishing ${PUBLISH_COUNT} samples to ${SLOT}/test/ping over mTLS"
python3 -m venv "${WORK}/venv"
"${WORK}/venv/bin/pip" install -q eclipse-zenoh==1.9.0
ENDPOINT="$(sudo sed -n 's/^ZENOH_LOCAL_ENDPOINT=//p' "${POD_DIR}/compose/.env")"
before="$(metric goat_audit_samples_total)"
sudo "${WORK}/venv/bin/python" -I - "$ENDPOINT" "$STATE/zenoh/tls" "${SLOT}/test/ping" "$PUBLISH_COUNT" <<'PY'
import json, sys, time
import zenoh
endpoint, tls, key, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
conf = zenoh.Config.from_json5(json.dumps({
    "id": key.split("/", 1)[0],
    "mode": "client",
    "connect": {"endpoints": [endpoint]},
    "scouting": {"multicast": {"enabled": False}},
    "transport": {"link": {"tls": {
        "root_ca_certificate": f"{tls}/ca-roots.pem",
        "connect_certificate": f"{tls}/pod-cert.pem",
        "connect_private_key": f"{tls}/pod-key.pem",
        "enable_mtls": True,
        "verify_name_on_connect": False,
    }}},
}))
with zenoh.open(conf) as s:
    time.sleep(2)  # let the router see the session before the first put
    for i in range(count):
        s.put(key, f"ping {i}")
        time.sleep(0.5)
    time.sleep(2)
print(f"    published {count} samples to {key}")
PY

for _ in $(seq 1 15); do
  after="$(metric goat_audit_samples_total)"
  [ "$(awk -v a="$after" -v b="$before" -v n="$PUBLISH_COUNT" 'BEGIN {print (a-b >= n)}')" = 1 ] && break
  sleep 2
done
log "goat_audit_samples_total: before=${before} after=${after}"
curl -fsS "$METRICS" | grep -E '^goat_audit_(samples_total|subscriber_session_state)' | sed 's/^/    /'
[ "$(awk -v a="$after" -v b="$before" -v n="$PUBLISH_COUNT" 'BEGIN {print (a-b >= n)}')" = 1 ] \
  || fail "audit sink counted $(awk -v a="$after" -v b="$before" 'BEGIN {print a-b}') of ${PUBLISH_COUNT} samples"

log "audit sink log"
docker logs "$SINK" 2>&1 | tail -n 20 | sed 's/^/    /'

log "changing the rendered ACL input and re-running first-boot"
started_before="$(docker inspect -f '{{.State.StartedAt}}' "$ROUTER")"
config_before="$(sudo sha256sum "$STATE/zenoh/config.json5" | cut -d' ' -f1)"
printf 'INBOUND_NAMESPACE=release/goat\n' >> "${POD_DIR}/profiles/${PROFILE_NAME}/profile.env"
sleep 1
sudo env PATH="${STUBS}:${PATH}" bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor"
started_after="$(docker inspect -f '{{.State.StartedAt}}' "$ROUTER")"
config_after="$(sudo sha256sum "$STATE/zenoh/config.json5" | cut -d' ' -f1)"
[ "$config_before" != "$config_after" ] || fail "the changed inbound namespace did not change the render"
[ "$started_before" != "$started_after" ] || fail "the running router was not restarted after its config changed"
log "router restart applied changed render: ${started_before} -> ${started_after}"

log "rolling back a rejected render to the last known good configuration"
good_config_sha="$(sudo sha256sum "$STATE/zenoh/config.json5" | cut -d' ' -f1)"
failed_restart_log="${WORK}/failed-restart.log"
# The invoking user owns WORK; only first-boot itself needs sudo.
# shellcheck disable=SC2024
if sudo env PATH="${STUBS}:${PATH}" \
  ZENOH_ROUTER_TEMPLATE="$INVALID_ROUTER_TEMPLATE" \
  bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor" \
  >"$failed_restart_log" 2>&1; then
  fail "first-boot accepted a router that could not load its changed config"
fi
grep -Eq 'router failed to load|router did not become healthy' "$failed_restart_log" \
  || fail "first-boot failed without identifying the unhealthy router"
grep -Fq 'The new configuration was rejected' "$failed_restart_log" \
  || fail "first-boot did not report the rejected router configuration"
grep -Fq 'The previous configuration is running again.' "$failed_restart_log" \
  || fail "first-boot did not report successful rollback"
[ "$(docker inspect -f '{{.State.Health.Status}}' "$ROUTER")" = healthy ] \
  || fail "router was not healthy after automatic rollback"
restored_sha="$(sudo sha256sum "$STATE/zenoh/config.json5" | cut -d' ' -f1)"
restored_applied_sha="$(sudo cat "$STATE/zenoh/.config.applied.sha256")"
[ "$restored_sha" = "$good_config_sha" ] && [ "$restored_applied_sha" = "$restored_sha" ] \
  || fail "rollback did not restore the running file and its applied hash"
[ "$(sudo stat -c '%a' "$STATE/zenoh/config.last-known-good.json5")" = 600 ] \
  || fail "last known good configuration mode is not 600"

log "refusing rollback when the saved identities cannot be verified"
# Keep the running router healthy but make the on-disk applied file impossible to identify.
# The next changed render therefore saves a last-known-good file without a usable identity record.
sudo sed -i 's/id: "pod-peer"/id: "unreadable-pod-peer"/' "$STATE/zenoh/config.json5"
sudo sh -c "sha256sum '$STATE/zenoh/config.json5' | cut -d' ' -f1 > '$STATE/zenoh/.config.applied.sha256'"
# shellcheck disable=SC2024
if sudo env PATH="${STUBS}:${PATH}" \
  ZENOH_ROUTER_TEMPLATE="$INVALID_ROUTER_TEMPLATE" \
  bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor" \
  >"${WORK}/unverified-identities-no-rollback.log" 2>&1; then
  fail "first-boot accepted an invalid render with unverifiable saved identities"
fi
grep -Fq 'was not restored because its saved certificate identities could not be verified' \
  "${WORK}/unverified-identities-no-rollback.log" \
  || fail "first-boot did not explain that the saved rollback identities were unverifiable"
grep -Fq 'The router is stopped rather than re-admitting an unverified identity.' \
  "${WORK}/unverified-identities-no-rollback.log" \
  || fail "first-boot did not report the safe stopped state for unverifiable identities"
[ "$(docker inspect -f '{{.State.Status}}' "$ROUTER")" = exited ] \
  || fail "router was not stopped after rollback identity verification failed"

log "recovering after the unverifiable rollback refusal"
sudo env PATH="${STUBS}:${PATH}" bash "${POD_DIR}/host/first-boot.sh" \
  "${PROFILE_NAME}" "${WORK}/pod.cbor" >/dev/null
[ "$(docker inspect -f '{{.State.Health.Status}}' "$ROUTER")" = healthy ] \
  || fail "router did not recover after the unverifiable rollback refusal"

log "refusing an unpinned fabric certificate name change before rendering"
sudo install -m 600 "$MINT/router-next.pem" "$MINT/router.pem"
sudo install -m 600 "$MINT/router-next.key" "$MINT/router.key"
docker restart "$UPSTREAM" >/dev/null
for _ in $(seq 1 30); do
  if [ "$(discover_fabric_certificate_cn "tls/127.0.0.1:${FABRIC_PORT}" \
    "$MINT/leaf.pem" "$MINT/leaf.key" "$MINT/ca.pem" 2 2>/dev/null || true)" = \
    synthetic-fabric-router-next ]; then
    break
  fi
  sleep 1
done
[ "$(discover_fabric_certificate_cn "tls/127.0.0.1:${FABRIC_PORT}" \
  "$MINT/leaf.pem" "$MINT/leaf.key" "$MINT/ca.pem" 2 2>/dev/null || true)" = \
  synthetic-fabric-router-next ] || fail "rotated synthetic router did not become ready"
continuity_started_before="$(docker inspect -f '{{.State.StartedAt}}' "$ROUTER")"
continuity_config_before="$(sudo sha256sum "$STATE/zenoh/config.json5" | cut -d' ' -f1)"
continuity_applied_before="$(sudo cat "$STATE/zenoh/.config.applied.sha256")"
# shellcheck disable=SC2024
if sudo env PATH="${STUBS}:${PATH}" \
  bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor" \
  >"${WORK}/identity-change-unpinned.log" 2>&1; then
  fail "first-boot accepted an unpinned fabric certificate name change"
fi
grep -Fq 'fabric router certificate name changed' \
  "${WORK}/identity-change-unpinned.log" \
  || fail "first-boot did not identify the changed fabric certificate name"
grep -Fq 'Goat-side operator: confirm the new name' \
  "${WORK}/identity-change-unpinned.log" \
  || fail "first-boot did not name the owner of fabric identity confirmation"
grep -Fq 'set ZENOH_FABRIC_CERT_CN to the' \
  "${WORK}/identity-change-unpinned.log" \
  || fail "first-boot did not give the partner a safe next step"
[ "$(docker inspect -f '{{.State.StartedAt}}' "$ROUTER")" = "$continuity_started_before" ] \
  || fail "fabric identity refusal restarted the running router"
[ "$(sudo sha256sum "$STATE/zenoh/config.json5" | cut -d' ' -f1)" = \
  "$continuity_config_before" ] \
  || fail "fabric identity refusal changed the rendered config"
[ "$(sudo cat "$STATE/zenoh/.config.applied.sha256")" = "$continuity_applied_before" ] \
  || fail "fabric identity refusal changed the applied hash"

log "refusing rollback across a confirmed fabric identity change"
printf 'ZENOH_FABRIC_CERT_CN=synthetic-fabric-router-next\n' \
  >> "${POD_DIR}/profiles/${PROFILE_NAME}/profile.env"
# shellcheck disable=SC2024
if sudo env PATH="${STUBS}:${PATH}" \
  ZENOH_ROUTER_TEMPLATE="$INVALID_ROUTER_TEMPLATE" \
  bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor" \
  >"${WORK}/identity-change-no-rollback.log" 2>&1; then
  fail "first-boot accepted the invalid identity-changing render"
fi
grep -Fq 'was not restored because its POD or' \
  "${WORK}/identity-change-no-rollback.log" \
  || fail "first-boot did not explain why identity-changing rollback was refused"
grep -Fq 'The router is stopped rather than re-admitting an old identity.' \
  "${WORK}/identity-change-no-rollback.log" \
  || fail "first-boot did not report the safe stopped state"
[ "$(docker inspect -f '{{.State.Status}}' "$ROUTER")" = exited ] \
  || fail "router was not stopped after identity-changing rollback was refused"
[ "$(sudo cat "$STATE/zenoh/.config.applied.sha256")" = "$continuity_applied_before" ] \
  || fail "identity-changing failure replaced the applied hash"

log "recovering with the confirmed identity and valid template"
sudo env PATH="${STUBS}:${PATH}" bash "${POD_DIR}/host/first-boot.sh" \
  "${PROFILE_NAME}" "${WORK}/pod.cbor" >/dev/null
[ "$(docker inspect -f '{{.State.Health.Status}}' "$ROUTER")" = healthy ] \
  || fail "router did not recover with the confirmed identity"
[ "$(sudo cat "$STATE/zenoh/.fabric-router-cn.applied")" = \
  synthetic-fabric-router-next ] \
  || fail "healthy confirmed identity did not replace the recorded name"
log "PASS: audit sink subscribed and counted ${PUBLISH_COUNT} samples (endpoint ${ENDPOINT})"
