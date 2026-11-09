#!/usr/bin/env bash
# Prove that fabric-wide subscription interest crosses the pod router without widening data ACLs.
set -euo pipefail

POD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=host/fabric-peer-identity.sh
source "${POD_DIR}/host/fabric-peer-identity.sh"
ROUTER_TEMPLATE="${ROUTER_TEMPLATE:-${POD_DIR}/host/zenoh-router.json5.tmpl}"
IMAGE="eclipse/zenoh:1.9.0@sha256:157965d71e0bfd0a044d76a985ff0e5c306ad3968929168fb9678cd2a7fec23f"
SLOT="7f3c2a10-0000-4000-8000-00000000c1a0"
INBOUND="release/goat"
FABRIC_CN="synthetic-fabric-router"
# Keep the bind mount below the checkout so Docker Desktop/Colima and Linux CI can both see it.
WORK="$(mktemp -d "${POD_DIR}/.router-forwarding.XXXXXX")"
RUN_ID="$(basename "$WORK" | tr -cd 'A-Za-z0-9')"
NETWORK="moon-forwarding-${RUN_ID}"
UPSTREAM="moon-upstream-${RUN_ID}"
POD_ROUTER="moon-pod-router-${RUN_ID}"

log() { printf '==> %s\n' "$*"; }
dump() {
  docker logs "$UPSTREAM" 2>&1 | tail -n 80 || true
  docker logs "$POD_ROUTER" 2>&1 | tail -n 80 || true
}
cleanup() {
  docker rm -f "$POD_ROUTER" "$UPSTREAM" >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for tool in docker envsubst openssl python3 timeout; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool not found: $tool"; exit 2; }
done

mkdir -p "$WORK/tls"
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/tls/ca.key" 2>/dev/null
openssl req -x509 -new -key "$WORK/tls/ca.key" -sha256 -days 2 \
  -subj "/CN=synthetic-forwarding-ca" -addext "basicConstraints=critical,CA:TRUE" \
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

docker network create "$NETWORK" >/dev/null
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
docker run -d --name "$UPSTREAM" --network "$NETWORK" --network-alias upstream \
  -p "127.0.0.1:${UPSTREAM_PORT}:7448" -v "$WORK:/work:ro" "$IMAGE" -c /work/upstream.json5 >/dev/null

log "discovering the fabric-router CN through the shared first-boot helper"
for _ in $(seq 1 30); do
  if resolve_fabric_certificate_cn "tls/127.0.0.1:${UPSTREAM_PORT}?rel=0#router" "" "$SLOT" \
    "$WORK/tls/pod.pem" "$WORK/tls/pod.key" "$WORK/tls/ca.pem" 2>/dev/null; then
    break
  fi
  sleep 1
done
[ "${FABRIC_ROUTER_CERT_CN:-}" = "$FABRIC_CN" ] \
  || { echo "fabric CN discovery failed: got '${FABRIC_ROUTER_CERT_CN:-}'"; dump; exit 1; }

export ZENOH_LISTEN_PORT=7447 ZENOH_FABRIC_ENDPOINT="tls/upstream:7448"
export PARTNER_NAMESPACE="$SLOT" INBOUND_NAMESPACE="$INBOUND"
export POD_CERT_CN="$SLOT" FABRIC_ROUTER_CERT_CN
export POD_CERT_PEM=/work/tls/pod.pem POD_KEY_PEM=/work/tls/pod.key CA_ROOTS_PEM=/work/tls/ca.pem
# shellcheck disable=SC2016
envsubst \
  '${ZENOH_LISTEN_PORT} ${ZENOH_FABRIC_ENDPOINT} ${PARTNER_NAMESPACE} ${INBOUND_NAMESPACE} ${POD_CERT_CN} ${FABRIC_ROUTER_CERT_CN} ${POD_CERT_PEM} ${POD_KEY_PEM} ${CA_ROOTS_PEM}' \
  < "$ROUTER_TEMPLATE" > "$WORK/pod.json5"
# shellcheck disable=SC2016
UNRESOLVED_PLACEHOLDER='"${'
if grep -Fq "$UNRESOLVED_PLACEHOLDER" "$WORK/pod.json5"; then
  echo "rendered router config still contains placeholders"
  exit 1
fi

docker run -d --name "$POD_ROUTER" --network "$NETWORK" \
  -p "127.0.0.1:${POD_PORT}:7447" -v "$WORK:/work:ro" "$IMAGE" -c /work/pod.json5 >/dev/null

log "installing the Zenoh 1.9.0 test client"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q eclipse-zenoh==1.9.0

log "testing routed interest and namespace denials"
if ! "$WORK/venv/bin/python" -I - "$UPSTREAM_PORT" "$POD_PORT" "$WORK/tls" "$SLOT" "$INBOUND" <<'PY'
import json
import sys
import threading
import time

import zenoh

upstream_port, pod_port, tls, slot, inbound = sys.argv[1:]

def config(port, identity):
    return zenoh.Config.from_json5(json.dumps({
        "mode": "client",
        "connect": {"endpoints": [f"tls/127.0.0.1:{port}"]},
        "scouting": {"multicast": {"enabled": False}},
        "transport": {"link": {"tls": {
            "root_ca_certificate": f"{tls}/ca.pem",
            "connect_certificate": f"{tls}/{identity}.pem",
            "connect_private_key": f"{tls}/{identity}.key",
            "enable_mtls": True,
            "verify_name_on_connect": False,
        }}},
    }))

def wait_for(event, description, timeout=8):
    if not event.wait(timeout):
        raise AssertionError(f"timed out waiting for {description}")

last_error = None
for _ in range(30):
    try:
        upstream = zenoh.open(config(upstream_port, "upstream"))
        pod = zenoh.open(config(pod_port, "pod"))
        break
    except Exception as exc:
        last_error = exc
        time.sleep(1)
else:
    raise AssertionError(f"routers did not become ready: {last_error}")

with upstream, pod:
    inbound_direction_violations = []
    outbound = threading.Event()
    outbound_key = f"{slot}/test/ping"
    fabric_sub = upstream.declare_subscriber(
        "*/**", lambda sample: outbound.set() if str(sample.key_expr) == outbound_key else None
    )
    time.sleep(2)
    pod.put(outbound_key, "allowed")
    wait_for(outbound, "slot publish at the fabric wildcard subscriber")

    blocked_outbound = threading.Event()
    blocked_key = "outside/test/blocked"
    blocked_sub = upstream.declare_subscriber(blocked_key, lambda _sample: blocked_outbound.set())
    time.sleep(1)
    pod.put(blocked_key, "must-not-leave")
    if blocked_outbound.wait(3):
        raise AssertionError("out-of-slot local publish escaped the pod router")

    blocked_inbound_write = threading.Event()
    inbound_write_key = f"{inbound}/test/local-write"
    inbound_write_sub = upstream.declare_subscriber(
        "*/**",
        lambda sample: blocked_inbound_write.set()
        if str(sample.key_expr) == inbound_write_key else None,
    )
    time.sleep(1)
    pod.put(inbound_write_key, "must-not-leave")
    if blocked_inbound_write.wait(3):
        inbound_direction_violations.append(
            "local publish into the fabric-owned inbound namespace escaped the pod router"
        )

    inbound_seen = threading.Event()
    inbound_key = f"{inbound}/test/pong"
    inbound_sub = pod.declare_subscriber(inbound_key, lambda _sample: inbound_seen.set())
    time.sleep(1)
    upstream.put(inbound_key, "allowed")
    wait_for(inbound_seen, "allowed inbound publish at the pod client")

    inbound_query_seen = threading.Event()
    inbound_reply_seen = threading.Event()
    inbound_query_key = f"{inbound}/test/query"

    def answer_inbound(query):
        inbound_query_seen.set()
        query.reply(inbound_query_key, "answer")

    inbound_queryable = upstream.declare_queryable(inbound_query_key, answer_inbound)
    time.sleep(1)
    pod.get(inbound_query_key, handler=lambda reply: inbound_reply_seen.set() if reply.ok else None)
    if not inbound_query_seen.wait(8):
        inbound_direction_violations.append(
            "local inbound query did not reach the fabric queryable"
        )
    elif not inbound_reply_seen.wait(8):
        inbound_direction_violations.append(
            "fabric query reply did not reach the pod client"
        )

    inbound_liveliness_seen = threading.Event()
    inbound_liveliness_key = f"{inbound}/test/liveliness"
    inbound_liveliness_sub = pod.liveliness().declare_subscriber(
        inbound_liveliness_key, lambda _sample: inbound_liveliness_seen.set()
    )
    time.sleep(1)
    fabric_token = upstream.liveliness().declare_token(inbound_liveliness_key)
    wait_for(inbound_liveliness_seen, "fabric liveliness token at the pod client")

    escaped_liveliness = threading.Event()
    local_liveliness_key = f"{inbound}/test/local-liveliness"
    fabric_liveliness_sub = upstream.liveliness().declare_subscriber(
        local_liveliness_key, lambda _sample: escaped_liveliness.set()
    )
    time.sleep(1)
    local_token = pod.liveliness().declare_token(local_liveliness_key)
    if escaped_liveliness.wait(3):
        inbound_direction_violations.append(
            "local liveliness token escaped into the fabric-owned inbound namespace"
        )

    wildcard_seen = threading.Event()
    local_wildcard = pod.declare_subscriber("**", lambda _sample: wildcard_seen.set())
    time.sleep(2)
    upstream.put("outside/fabric/blocked", "must-not-arrive")
    if wildcard_seen.wait(3):
        raise AssertionError("out-of-scope fabric publish reached a pod-local wildcard subscriber")

    upstream.put(f"{slot}/wildcard/probe", "must-not-arrive")
    if wildcard_seen.wait(3):
        raise AssertionError("pod-local wildcard subscription was accepted or propagated")

    exact_seen = threading.Event()
    exact_key = f"{slot}/exact/probe"
    exact_sub = pod.declare_subscriber(exact_key, lambda _sample: exact_seen.set())
    time.sleep(1)
    upstream.put(exact_key, "allowed")
    wait_for(exact_seen, "slot-scoped local subscription")

    # Keep declarations alive until every assertion has completed.
    assert all((fabric_sub, blocked_sub, inbound_write_sub, inbound_sub, inbound_queryable,
                inbound_liveliness_sub, fabric_token, fabric_liveliness_sub, local_token,
                local_wildcard, exact_sub))
    if inbound_direction_violations:
        raise AssertionError("; ".join(inbound_direction_violations))

print("PASS: fabric wildcard interest forwards slot data; data ACLs and local wildcard default remain closed")
PY
then
  dump
  exit 1
fi

log "testing the sandbox shape where inbound and partner namespaces are identical"
docker rm -f "$POD_ROUTER" >/dev/null
export INBOUND_NAMESPACE="$SLOT"
# shellcheck disable=SC2016
envsubst \
  '${ZENOH_LISTEN_PORT} ${ZENOH_FABRIC_ENDPOINT} ${PARTNER_NAMESPACE} ${INBOUND_NAMESPACE} ${POD_CERT_CN} ${FABRIC_ROUTER_CERT_CN} ${POD_CERT_PEM} ${POD_KEY_PEM} ${CA_ROOTS_PEM}' \
  < "$ROUTER_TEMPLATE" > "$WORK/pod-sandbox.json5"
docker run -d --name "$POD_ROUTER" --network "$NETWORK" \
  -p "127.0.0.1:${POD_PORT}:7447" -v "$WORK:/work:ro" "$IMAGE" -c /work/pod-sandbox.json5 >/dev/null

if ! "$WORK/venv/bin/python" -I - "$UPSTREAM_PORT" "$POD_PORT" "$WORK/tls" "$SLOT" <<'PY'
import json
import sys
import threading
import time

import zenoh

upstream_port, pod_port, tls, slot = sys.argv[1:]

def config(port, identity):
    return zenoh.Config.from_json5(json.dumps({
        "mode": "client",
        "connect": {"endpoints": [f"tls/127.0.0.1:{port}"]},
        "scouting": {"multicast": {"enabled": False}},
        "transport": {"link": {"tls": {
            "root_ca_certificate": f"{tls}/ca.pem",
            "connect_certificate": f"{tls}/{identity}.pem",
            "connect_private_key": f"{tls}/{identity}.key",
            "enable_mtls": True,
            "verify_name_on_connect": False,
        }}},
    }))

last_error = None
for _ in range(30):
    try:
        upstream = zenoh.open(config(upstream_port, "upstream"))
        pod = zenoh.open(config(pod_port, "pod"))
        break
    except Exception as exc:
        last_error = exc
        time.sleep(1)
else:
    raise AssertionError(f"sandbox router did not become ready: {last_error}")

with upstream, pod:
    arrived = threading.Event()
    key = f"{slot}/test/sandbox-shared-namespace"
    subscriber = upstream.declare_subscriber(
        "*/**", lambda sample: arrived.set() if str(sample.key_expr) == key else None
    )
    time.sleep(2)
    pod.put(key, "allowed-by-firstparty")
    if not arrived.wait(8):
        raise AssertionError("slot publish was denied when inbound namespace equalled the slot")
    assert subscriber

print("PASS: shared inbound/partner namespace preserves first-party slot publishing")
PY
then
  dump
  exit 1
fi
