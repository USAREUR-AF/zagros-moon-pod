#!/usr/bin/env bash
# audit-sink-local.sh — stand the pod up on THIS host through host/first-boot.sh, with a
# synthetic CA and pod leaf in place of a goat-side enrollment bundle, and prove the audit sink
# runs: container up and not restarting, metrics on :9303, session open, and a publish into the
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
#   LOCAL_ENDPOINT  mesh (default) | loopback — which address first-boot hands the audit sink.
#                   "mesh" stubs `netbird status` with this host's primary address, the way a
#                   real pod resolves its mesh IP; "loopback" is first-boot's no-mesh fallback.
#   LEAF_EKU        EKU set for the synthetic leaf (default serverAuth,clientAuth).
#   PUBLISH_COUNT   samples to publish and expect counted (default 5).
set -euo pipefail

POD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENDPOINT="${LOCAL_ENDPOINT:-mesh}"
LEAF_EKU="${LEAF_EKU:-serverAuth,clientAuth}"
PUBLISH_COUNT="${PUBLISH_COUNT:-5}"
SLOT="7f3c2a10-0000-4000-8000-00000000c1a0"   # synthetic slot anchor
PROFILE_NAME="ci-local"                       # profiles/*-local/ is gitignored
WORK="$(mktemp -d)"
STATE="${WORK}/state"
SINK=goat-moon-audit-sink
ROUTER=goat-moon-zenoh-router
METRICS=http://127.0.0.1:9303/metrics

log()  { printf '==> %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; dump; exit 1; }
dump() {
  log "docker ps"; docker ps -a --format '{{.Names}}\t{{.Status}}' || true
  for c in "$ROUTER" "$SINK"; do
    log "logs: $c"; docker logs "$c" 2>&1 | tail -n 80 || true
  done
}
cleanup() {
  ( cd "${POD_DIR}/compose" && sudo docker compose --profile audit down -v --remove-orphans ) >/dev/null 2>&1 || true
  sudo systemctl disable --now goat-doctor.timer >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/goat-doctor.service /etc/systemd/system/goat-doctor.timer
  sudo rm -rf "${WORK}" "${POD_DIR}/profiles/${PROFILE_NAME}" "${POD_DIR}/compose/.env"
}
trap cleanup EXIT

for t in docker openssl envsubst curl python3 sudo; do
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
openssl x509 -req -in "$MINT/leaf.csr" -CA "$MINT/ca.pem" -CAkey "$MINT/ca.key" -CAcreateserial \
  -days 2 -sha256 -extfile "$MINT/leaf.ext" -out "$MINT/leaf.pem" 2>/dev/null
openssl x509 -in "$MINT/leaf.pem" -noout -ext extendedKeyUsage | tail -n 1 | sed 's/^ */    leaf EKU: /'

# --- 2. Stub `goat` (and `netbird`) in place of the goat-side bundle path ---------------------------
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
                  # No fabric in this test: the router dials a documentation address (RFC 5737)
                  # and keeps retrying in the background.
                  echo 'router_endpoint = "tls/192.0.2.1:7447"' > "\$d/profile.toml" ;;
  *)              exit 0 ;;
esac
EOF
if [ "$LOCAL_ENDPOINT" = mesh ]; then
  HOST_IP="$(ip -4 route get 192.0.2.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
  [ -n "$HOST_IP" ] || { echo "could not resolve this host's primary IPv4"; exit 2; }
  printf '#!/usr/bin/env bash\necho "NetBird IP: %s/16"\n' "$HOST_IP" > "$STUBS/netbird"
  log "netbird stub reports ${HOST_IP} as the mesh IP"
fi
chmod +x "$STUBS"/*

# --- 3. A filled local profile, then first-boot as a partner runs it ---------------------------------
mkdir -p "${POD_DIR}/profiles/${PROFILE_NAME}"
sed -e "s|^PARTNER_NAMESPACE=.*|PARTNER_NAMESPACE=${SLOT}|" "${POD_DIR}/profiles/zagros/profile.env" \
  > "${POD_DIR}/profiles/${PROFILE_NAME}/profile.env"
printf 'POD_STATE_DIR=%s\nPOD_ID=ci-pod\n' "$STATE" >> "${POD_DIR}/profiles/${PROFILE_NAME}/profile.env"
: > "${WORK}/pod.cbor"   # placeholder bundle; the stub never reads it

log "host/first-boot.sh ${PROFILE_NAME}"
sudo env PATH="${STUBS}:${PATH}" bash "${POD_DIR}/host/first-boot.sh" "${PROFILE_NAME}" "${WORK}/pod.cbor"
grep '^ZENOH_LOCAL_ENDPOINT=' "${POD_DIR}/compose/.env" | sed 's/^/    /'
# --profile audit is a no-op once the sink starts by default, and starts it while it is gated.
( cd "${POD_DIR}/compose" && sudo docker compose --profile audit up -d )

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
ENDPOINT="$(sed -n 's/^ZENOH_LOCAL_ENDPOINT=//p' "${POD_DIR}/compose/.env")"
before="$(metric goat_audit_samples_total)"
sudo "${WORK}/venv/bin/python" -I - "$ENDPOINT" "$STATE/zenoh/tls" "${SLOT}/test/ping" "$PUBLISH_COUNT" <<'PY'
import json, sys, time
import zenoh
endpoint, tls, key, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
conf = zenoh.Config.from_json5(json.dumps({
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
log "PASS: audit sink subscribed and counted ${PUBLISH_COUNT} samples (endpoint ${ENDPOINT})"
