#!/usr/bin/env bash
# Prove pod carriage end to end (ADR 1251): a device with its own certificate publishes through the
# pod under its own slot once the pod's signed rule generation carries it, an uncovered device is
# refused, and a local rule made by the pod's named local authority admits a device at once.
#
# The generation is signed here, with a throwaway signer key, by an implementation independent of
# goat-pod-api's own (Python canonical JSON + openssl), so the two must agree on the signed bytes.
#
# goat-pod-api comes from GOAT_POD_API (a built binary) or is built from GOATCORE_DIR
# (a goatcore checkout holding ops/goat-pod-api).
set -euo pipefail

POD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=host/fabric-peer-identity.sh
source "${POD_DIR}/host/fabric-peer-identity.sh"
ROUTER_TEMPLATE="${ROUTER_TEMPLATE:-${POD_DIR}/host/zenoh-router.json5.tmpl}"
IMAGE="eclipse/zenoh:1.9.0@sha256:157965d71e0bfd0a044d76a985ff0e5c306ad3968929168fb9678cd2a7fec23f"
SLOT="7f3c2a10000040008000000000c1a0aa"
DEVICE="7f3c2a10000040008000000000d0d0d1"
STRANGER="7f3c2a10000040008000000000e0e0e2"
FABRIC_SLOT="7f3c2a10000040008000000000f0f0f3"
FABRIC_CN="synthetic-fabric-router"
SIGNER_CN="synthetic-portal-signer"
LEAD_CN="lead.g1"
WORK="$(mktemp -d "${POD_DIR}/.pod-carriage.XXXXXX")"
RUN_ID="$(basename "$WORK" | tr -cd 'A-Za-z0-9')"
NETWORK="moon-carriage-${RUN_ID}"
UPSTREAM="moon-carriage-upstream-${RUN_ID}"
POD_ROUTER="moon-carriage-pod-${RUN_ID}"
API_PID=""

log() { printf '==> %s\n' "$*"; }
dump() {
  docker logs "$UPSTREAM" 2>&1 | tail -n 60 || true
  docker logs "$POD_ROUTER" 2>&1 | tail -n 60 || true
  [ -f "$WORK/api.log" ] && tail -n 40 "$WORK/api.log" || true
}
cleanup() {
  [ -n "$API_PID" ] && kill "$API_PID" 2>/dev/null || true
  docker rm -f "$POD_ROUTER" "$UPSTREAM" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; dump; exit 1; }

for tool in docker envsubst openssl python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool not found: $tool"; exit 2; }
done

if [ -n "${GOAT_POD_API:-}" ]; then
  POD_API="$GOAT_POD_API"
elif [ -n "${GOATCORE_DIR:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "go is needed to build goat-pod-api from GOATCORE_DIR"; exit 2; }
  log "building goat-pod-api from ${GOATCORE_DIR}"
  (cd "${GOATCORE_DIR}/ops/goat-pod-api" && CGO_ENABLED=0 go build -o "$WORK/goat-pod-api" .)
  POD_API="$WORK/goat-pod-api"
else
  echo "set GOAT_POD_API to a goat-pod-api binary, or GOATCORE_DIR to a goatcore checkout"
  exit 2
fi

# --- Synthetic PKI -------------------------------------------------------------------------------
mkdir -p "$WORK/tls" "$WORK/state"
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/tls/ca.key" 2>/dev/null
openssl req -x509 -new -key "$WORK/tls/ca.key" -sha256 -days 2 \
  -subj "/CN=synthetic-carriage-ca" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$WORK/tls/ca.pem" 2>/dev/null
mint_leaf() {
  local name="$1" cn="$2"
  openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/tls/${name}.sec1" 2>/dev/null
  openssl pkcs8 -topk8 -nocrypt -in "$WORK/tls/${name}.sec1" -out "$WORK/tls/${name}.key" 2>/dev/null
  openssl req -new -key "$WORK/tls/${name}.key" -subj "/CN=${cn}" -out "$WORK/tls/${name}.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:%s\n' "$name" \
    > "$WORK/tls/${name}.ext"
  openssl x509 -req -in "$WORK/tls/${name}.csr" -CA "$WORK/tls/ca.pem" \
    -CAkey "$WORK/tls/ca.key" -CAcreateserial -CAserial "$WORK/tls/ca.srl" -days 2 -sha256 \
    -extfile "$WORK/tls/${name}.ext" -out "$WORK/tls/${name}.pem" 2>/dev/null
}
mint_leaf pod "$SLOT"
mint_leaf upstream "$FABRIC_CN"
mint_leaf device "${DEVICE}.g1"
mint_leaf stranger "${STRANGER}.g1"
mint_leaf signer "$SIGNER_CN"
mint_leaf lead "$LEAD_CN"

# --- Routers ---------------------------------------------------------------------------------------
cat > "$WORK/upstream.json5" <<'EOF'
{
  mode: "router",
  listen: { endpoints: ["tls/0.0.0.0:7448"] },
  scouting: { multicast: { enabled: false } },
  transport: { link: { tls: {
    listen_certificate: "/work/tls/upstream.pem",
    listen_private_key: "/work/tls/upstream.key",
    root_ca_certificate: "/work/tls/ca.pem",
    enable_mtls: true,
  } } },
}
EOF
free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}
UPSTREAM_PORT="$(free_port)"
POD_PORT="$(free_port)"
API_PORT="$(free_port)"
docker network create "$NETWORK" >/dev/null
docker run -d --name "$UPSTREAM" --network "$NETWORK" --network-alias upstream \
  -p "127.0.0.1:${UPSTREAM_PORT}:7448" -v "$WORK:/work:ro" "$IMAGE" -c /work/upstream.json5 >/dev/null

for _ in $(seq 1 30); do
  if resolve_fabric_certificate_cn "tls/127.0.0.1:${UPSTREAM_PORT}?rel=0#router" "" "$SLOT" \
    "$WORK/tls/pod.pem" "$WORK/tls/pod.key" "$WORK/tls/ca.pem" 2>/dev/null; then
    break
  fi
  sleep 1
done
[ "${FABRIC_ROUTER_CERT_CN:-}" = "$FABRIC_CN" ] || fail "fabric CN discovery got '${FABRIC_ROUTER_CERT_CN:-}'"

log "rendering the base router config from the pod template (first-boot's envsubst)"
export ZENOH_LISTEN_PORT=7447 ZENOH_FABRIC_ENDPOINT="tls/upstream:7448"
export PARTNER_NAMESPACE="$SLOT" INBOUND_NAMESPACE="$SLOT"
export POD_CERT_CN="$SLOT" FABRIC_ROUTER_CERT_CN
POD_ROUTER_ZID="$(derive_pod_router_zid "$POD_CERT_CN")"
export POD_ROUTER_ZID
export POD_CERT_PEM=/work/tls/pod.pem POD_KEY_PEM=/work/tls/pod.key CA_ROOTS_PEM=/work/tls/ca.pem
# shellcheck disable=SC2016
envsubst \
  '${ZENOH_LISTEN_PORT} ${POD_ROUTER_ZID} ${ZENOH_FABRIC_ENDPOINT} ${PARTNER_NAMESPACE} ${INBOUND_NAMESPACE} ${POD_CERT_CN} ${FABRIC_ROUTER_CERT_CN} ${POD_CERT_PEM} ${POD_KEY_PEM} ${CA_ROOTS_PEM}' \
  < "$ROUTER_TEMPLATE" > "$WORK/pod.base.json5"
for marker in rules subjects policies; do
  grep -q "// @carriage-${marker}" "$WORK/pod.base.json5" || fail "template lacks the ${marker} marker"
done
cp "$WORK/pod.base.json5" "$WORK/pod.json5"

docker run -d --name "$POD_ROUTER" --network "$NETWORK" \
  -p "127.0.0.1:${POD_PORT}:7447" -v "$WORK:/work:ro" "$IMAGE" -c /work/pod.json5 >/dev/null

cat > "$WORK/pod-api.json" <<EOF
{
  "pod_slot": "${SLOT}",
  "state_dir": "${WORK}/state",
  "portal_signer_cert": "${WORK}/tls/signer.pem",
  "pod_cert": "${WORK}/tls/pod.pem",
  "pod_key": "${WORK}/tls/pod.key",
  "ca_roots": "${WORK}/tls/ca.pem",
  "listen": ["127.0.0.1:${API_PORT}"],
  "router": {
    "base_config": "${WORK}/pod.base.json5",
    "config": "${WORK}/pod.json5",
    "last_good": "${WORK}/pod.last-known-good.json5",
    "applied_sha_file": "${WORK}/.config.applied.sha256",
    "container": "${POD_ROUTER}",
    "health_timeout_seconds": 60
  }
}
EOF

# --- A generation signed here ----------------------------------------------------------------------
# Canonical JSON (sorted keys, no whitespace, UTF-8 as is), prefixed, ECDSA P-256 over SHA-256.
sign_generation() {
  local number="$1" sources="$2" out="$3"
  python3 -I - "$number" "$SLOT" "$sources" "$LEAD_CN" "$SIGNER_CN" "$WORK/unsigned.bin" "$WORK/doc.json" <<'PY'
import json, sys
number, pod, sources, lead, signer, signed_path, doc_path = sys.argv[1:]
src = []
for slot in filter(None, sources.split(",")):
    src.append({
        "slot": slot, "rule_id": "cr_" + slot[-4:], "kind": "org", "until": None,
        "principals": [slot + ".g1"],
        "write": [slot + "/**", "volatile/" + slot + "/**", slot + "/**/@adv/**"],
    })
doc = {
    "schema": "goat.carriage.generation/v1", "pod_slot": pod, "generation": int(number),
    "issued_at": "2026-11-19T10:00:00Z",
    "local_authority": [{"identity": "zagros-test:lead", "cert_cn": lead}],
    "read": ["*/**"], "sources": src, "signer": signer,
}
canonical = json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
open(signed_path, "wb").write(b"goat-carriage-v1\n" + canonical.encode())
json.dump(doc, open(doc_path, "w"))
PY
  openssl dgst -sha256 -sign "$WORK/tls/signer.key" -out "$WORK/sig.der" "$WORK/unsigned.bin"
  python3 -I - "$WORK/doc.json" "$WORK/sig.der" "$out" <<'PY'
import base64, json, sys
doc = json.load(open(sys.argv[1]))
doc["signature"] = base64.b64encode(open(sys.argv[2], "rb").read()).decode()
json.dump(doc, open(sys.argv[3], "w"), indent=2)
PY
}

log "installing the Zenoh 1.9.0 test client"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q eclipse-zenoh==1.9.0

cat > "$WORK/check.py" <<'PY'
"""Publish through the pod router and observe at the upstream router.

usage: check.py <mode> <upstream_port> <pod_port> <tls_dir> <pod_slot> <device> <stranger> <fabric_slot>
mode: generation  - the generation carries DEVICE only
      local-rule  - a local rule has also admitted STRANGER
"""
import json, sys, threading, time
import zenoh

mode, up_port, pod_port, tls, pod_slot, device, stranger, fabric_slot = sys.argv[1:]

def config(port, identity):
    return zenoh.Config.from_json5(json.dumps({
        "mode": "client",
        "connect": {"endpoints": [f"tls/127.0.0.1:{port}"]},
        "scouting": {"multicast": {"enabled": False}},
        "transport": {"link": {"tls": {
            "root_ca_certificate": f"{tls}/ca.pem",
            "connect_certificate": f"{tls}/{identity}.pem",
            "connect_private_key": f"{tls}/{identity}.key",
            "enable_mtls": True, "verify_name_on_connect": False,
        }}},
    }))

def open_retry(port, identity):
    last = None
    for _ in range(40):
        try:
            return zenoh.open(config(port, identity))
        except Exception as exc:
            last = exc
            time.sleep(1)
    raise AssertionError(f"could not open a session as {identity}: {last}")

def publish_until(session, key, event, what, timeout=20):
    deadline = time.monotonic() + timeout
    event.clear()
    while time.monotonic() < deadline:
        session.put(key, "probe")
        if event.wait(0.25):
            return
    raise AssertionError(f"timed out waiting for {what}")

upstream = open_retry(up_port, "upstream")
pod = open_retry(pod_port, "pod")
dev = open_retry(pod_port, "device")
seen = []
events = {}
def record(sample):
    key = str(sample.key_expr)
    seen.append(key)
    if key in events:
        events[key].set()
upstream.declare_subscriber("*/**", record)

# The pod's own first-party data still flows (the template's rules are unchanged).
pod_ok = threading.Event(); events[f"{pod_slot}/carriage/sentinel"] = pod_ok
publish_until(pod, f"{pod_slot}/carriage/sentinel", pod_ok, "pod first-party publish")

# The carried device publishes under its own slot through the pod.
dev_ok = threading.Event(); events[f"{device}/test/ping"] = dev_ok
publish_until(dev, f"{device}/test/ping", dev_ok, "carried device publish under its own slot")
print("ok: carried device published under its own slot")

def denied(session, key, why, close=False):
    """A denied put cannot overtake an allowed sentinel sent after it on the same route."""
    seen.clear()
    session.put(key, "must-not-leave")
    if close:
        session.close()
    sentinel = threading.Event(); events[f"{pod_slot}/carriage/barrier"] = sentinel
    publish_until(pod, f"{pod_slot}/carriage/barrier", sentinel, "barrier")
    time.sleep(0.5)
    if key in seen:
        raise AssertionError(why)

denied(dev, f"{stranger}/test/forged", "carried device wrote another source's slot")
print("ok: carried device refused outside its own slot")

# Reads: data the fabric publishes reaches the carried device through the pod (read set */**).
got = threading.Event()
dev.declare_subscriber(f"{fabric_slot}/feed/**", lambda s: got.set())
publish_until(upstream, f"{fabric_slot}/feed/1", got, "fabric data delivered to the carried device")
print("ok: carried device reads through the pod")

stranger_s = open_retry(pod_port, "stranger")
if mode == "generation":
    denied(stranger_s, f"{stranger}/test/ping", "uncovered device published through the pod", close=True)
    print("ok: uncovered device refused")
else:
    st_ok = threading.Event(); events[f"{stranger}/test/local"] = st_ok
    publish_until(stranger_s, f"{stranger}/test/local", st_ok, "device admitted by a local rule")
    stranger_s.close()
    print("ok: device admitted by a local rule publishes under its own slot")
for s in (dev, pod, upstream):
    s.close()
PY
run_check() {
  "$WORK/venv/bin/python" -I "$WORK/check.py" "$1" "$UPSTREAM_PORT" "$POD_PORT" "$WORK/tls" \
    "$SLOT" "$DEVICE" "$STRANGER" "$FABRIC_SLOT" || fail "check '$1' failed"
}

log "adopting generation 1 (carries the device only)"
sign_generation 1 "$DEVICE" "$WORK/gen1.json"
"$POD_API" adopt --config "$WORK/pod-api.json" "$WORK/gen1.json" || fail "generation 1 not adopted"
grep -q "\"cert_common_names\":\[\"${DEVICE}.g1\"\]" "$WORK/pod.json5" || fail "device subject not rendered"
if grep -q "${STRANGER}" "$WORK/pod.json5"; then fail "uncovered device rendered"; fi
run_check generation

log "a different generation 1 and a tampered generation are refused"
sign_generation 1 "$DEVICE,$STRANGER" "$WORK/gen1b.json"
if "$POD_API" adopt --config "$WORK/pod-api.json" "$WORK/gen1b.json" 2>"$WORK/err.txt"; then
  fail "a second generation 1 with other contents was adopted"
fi
sed 's/"generation": 1/"generation": 2/' "$WORK/gen1.json" > "$WORK/gen-tampered.json"
if "$POD_API" adopt --config "$WORK/pod-api.json" "$WORK/gen-tampered.json" 2>"$WORK/err.txt"; then
  fail "a tampered generation was adopted"
fi
grep -q signature "$WORK/err.txt" || fail "tampered generation refused for the wrong reason: $(cat "$WORK/err.txt")"

log "starting the local API; a local rule from the named local authority admits the stranger"
"$POD_API" serve --config "$WORK/pod-api.json" >"$WORK/api.log" 2>&1 &
API_PID=$!
api() {
  local who="$1"; shift
  curl -sS --resolve "pod:${API_PORT}:127.0.0.1" --cacert "$WORK/tls/ca.pem" \
    --cert "$WORK/tls/${who}.pem" --key "$WORK/tls/${who}.key" "$@"
}
for _ in $(seq 1 30); do
  api lead -o /dev/null "https://pod:${API_PORT}/v1/status" 2>/dev/null && break
  sleep 1
done
STATUS="$(api device "https://pod:${API_PORT}/v1/status")"
echo "$STATUS" | grep -q '"generation": 1' || fail "status: $STATUS"
UNTIL="$(python3 -c 'import datetime;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(hours=4)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
BODY="{\"source\":\"${STRANGER}.g1\",\"until\":\"${UNTIL}\",\"reason\":\"met in the field\"}"
CODE="$(api device -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$BODY" "https://pod:${API_PORT}/v1/rules")"
[ "$CODE" = 403 ] || fail "a device that is not local authority changed rules (HTTP $CODE)"
CODE="$(api lead -o "$WORK/allow.json" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
  -d "$BODY" "https://pod:${API_PORT}/v1/rules")"
[ "$CODE" = 201 ] || fail "local authority allow returned HTTP $CODE: $(cat "$WORK/allow.json")"
[ "$(wc -l < "$WORK/state/ledger.jsonl" | tr -d ' ')" = 1 ] || fail "ledger does not hold one line"
run_check local-rule

log "pod carriage: all checks passed"
