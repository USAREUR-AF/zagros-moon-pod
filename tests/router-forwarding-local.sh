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
mint_leaf other "synthetic-other-pod"

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

def publish_until(session, key, event, description, timeout=8):
    """Retry an allowed publish until its already-declared subscriber is live."""
    deadline = time.monotonic() + timeout
    event.clear()
    while time.monotonic() < deadline:
        session.put(key, "readiness-probe")
        if event.wait(0.25):
            return
    raise AssertionError(f"timed out waiting for {description}")

def declare_liveliness_until(session, key, event, description, timeout=8):
    """Retry an allowed token declaration until its subscriber is live."""
    deadline = time.monotonic() + timeout
    event.clear()
    while time.monotonic() < deadline:
        token = session.liveliness().declare_token(key)
        if event.wait(0.25):
            return token
        token.undeclare()
    raise AssertionError(f"timed out waiting for {description}")

last_error = None
for _ in range(30):
    try:
        upstream = zenoh.open(config(upstream_port, "upstream"))
        pod = zenoh.open(config(pod_port, "pod"))
        pod_second = zenoh.open(config(pod_port, "pod"))
        pod_wild = zenoh.open(config(pod_port, "pod"))
        pod_control = zenoh.open(config(pod_port, "pod"))
        other = zenoh.open(config(pod_port, "other"))
        other_writer = zenoh.open(config(pod_port, "other"))
        break
    except Exception as exc:
        last_error = exc
        time.sleep(1)
else:
    raise AssertionError(f"routers did not become ready: {last_error}")

with upstream, pod, pod_second, pod_wild, pod_control, other, other_writer:
    inbound_direction_violations = []
    upstream_keys = []
    outbound = threading.Event()
    outbound_key = f"{slot}/test/ping"

    def record_upstream(sample):
        key = str(sample.key_expr)
        upstream_keys.append(key)
        if key == outbound_key:
            outbound.set()

    fabric_sub = upstream.declare_subscriber(
        "*/**", record_upstream
    )
    publish_until(pod, outbound_key, outbound,
                  "slot publish at the fabric wildcard subscriber")

    sentinel_number = [0]

    def assert_local_put_denied(session, denied_key, message, violations=None):
        """Prove a denied put cannot precede an allowed sentinel on the live route."""
        sentinel_number[0] += 1
        sentinel_key = f"{slot}/sentinel/{sentinel_number[0]}"
        sentinel = threading.Event()

        def see_sentinel(sample):
            if str(sample.key_expr) == sentinel_key:
                sentinel.set()

        sentinel_sub = upstream.declare_subscriber(sentinel_key, see_sentinel)
        publish_until(pod, sentinel_key, sentinel,
                      f"allowed sentinel for denial of {denied_key}")
        upstream_keys.clear()
        sentinel.clear()
        session.put(denied_key, "must-not-leave")
        # The sentinel uses the same session and priority, so its arrival is an ordering barrier.
        session.put(sentinel_key, "ordering-sentinel")
        wait_for(sentinel, f"ordering sentinel after denied put to {denied_key}")
        if denied_key in upstream_keys:
            if violations is None:
                raise AssertionError(message)
            violations.append(message)
        assert sentinel_sub

    assert_local_put_denied(
        pod,
        "outside/test/blocked",
        "out-of-slot local publish escaped the pod router",
    )
    assert_local_put_denied(
        pod,
        f"{inbound}/test/local-write",
        "local publish into the fabric-owned inbound namespace escaped the pod router",
        inbound_direction_violations,
    )
    # The other-CN identity has no allowed key for a same-session sentinel. Closing its dedicated
    # writer session flushes or discards every queued put before the already-proven POD route sends
    # the observation barrier. This is the deterministic alternative to an arbitrary denial wait.
    other_slot_write = f"{slot}/other/write"
    other_inbound_write = f"{inbound}/other/write"
    other_write_sentinel = f"{slot}/other/write-sentinel"
    other_write_seen = threading.Event()
    other_write_barrier = upstream.declare_subscriber(
        other_write_sentinel, lambda _sample: other_write_seen.set()
    )
    publish_until(pod, other_write_sentinel, other_write_seen,
                  "allowed sentinel for other-CN write denials")
    upstream_keys.clear()
    other_write_seen.clear()
    other_writer.put(other_slot_write, "must-not-leave")
    other_writer.put(other_inbound_write, "must-not-leave")
    other_writer.close()
    pod.put(other_write_sentinel, "ordering-sentinel")
    wait_for(other_write_seen, "ordering sentinel after other-CN writes")
    if other_slot_write in upstream_keys:
        raise AssertionError("other-CN session wrote into the slot namespace")
    if other_inbound_write in upstream_keys:
        raise AssertionError("other-CN session wrote into the inbound namespace")

    inbound_seen = threading.Event()
    inbound_key = f"{inbound}/test/pong"
    inbound_sub = pod.declare_subscriber(inbound_key, lambda _sample: inbound_seen.set())
    publish_until(upstream, inbound_key, inbound_seen,
                  "allowed inbound publish at the pod client")

    inbound_query_seen = threading.Event()
    inbound_reply_seen = threading.Event()
    inbound_query_key = f"{inbound}/test/query"

    def answer_inbound(query):
        inbound_query_seen.set()
        query.reply(inbound_query_key, "answer")

    inbound_queryable = upstream.declare_queryable(inbound_query_key, answer_inbound)
    query_deadline = time.monotonic() + 8
    while time.monotonic() < query_deadline and not inbound_reply_seen.is_set():
        pod.get(inbound_query_key,
                handler=lambda reply: inbound_reply_seen.set() if reply.ok else None)
        inbound_reply_seen.wait(0.25)
    if not inbound_query_seen.is_set():
        inbound_direction_violations.append(
            "local inbound query did not reach the fabric queryable"
        )
    elif not inbound_reply_seen.is_set():
        inbound_direction_violations.append(
            "fabric query reply did not reach the pod client"
        )

    inbound_liveliness_seen = threading.Event()
    inbound_liveliness_key = f"{inbound}/test/liveliness"
    inbound_liveliness_sub = pod.liveliness().declare_subscriber(
        inbound_liveliness_key, lambda _sample: inbound_liveliness_seen.set()
    )
    fabric_token = declare_liveliness_until(
        upstream,
        inbound_liveliness_key,
        inbound_liveliness_seen,
        "fabric liveliness token at the pod client",
    )

    escaped_liveliness = threading.Event()
    local_liveliness_key = f"{inbound}/test/local-liveliness"
    liveliness_sentinel_seen = threading.Event()
    liveliness_sentinel_gone = threading.Event()
    liveliness_sentinel_key = f"{slot}/test/liveliness-sentinel"

    def record_fabric_liveliness(sample):
        key = str(sample.key_expr)
        if key == local_liveliness_key and sample.kind == zenoh.SampleKind.PUT:
            escaped_liveliness.set()
        elif key == liveliness_sentinel_key and sample.kind == zenoh.SampleKind.PUT:
            liveliness_sentinel_seen.set()
        elif key == liveliness_sentinel_key and sample.kind == zenoh.SampleKind.DELETE:
            liveliness_sentinel_gone.set()

    # Both exact declarations share one callback on the upstream session. Liveliness tokens have
    # no caller-selectable priority, so the sentinel callback follows any earlier escaped token.
    fabric_liveliness_sub = upstream.liveliness().declare_subscriber(
        local_liveliness_key, record_fabric_liveliness
    )
    fabric_liveliness_sentinel_sub = upstream.liveliness().declare_subscriber(
        liveliness_sentinel_key, record_fabric_liveliness
    )
    liveliness_readiness_token = declare_liveliness_until(
        pod,
        liveliness_sentinel_key,
        liveliness_sentinel_seen,
        "allowed liveliness readiness token at the fabric",
    )
    liveliness_sentinel_gone.clear()
    liveliness_readiness_token.undeclare()
    wait_for(liveliness_sentinel_gone, "allowed liveliness readiness token withdrawal")
    liveliness_sentinel_seen.clear()
    local_token = pod.liveliness().declare_token(local_liveliness_key)
    liveliness_sentinel_token = pod.liveliness().declare_token(liveliness_sentinel_key)
    wait_for(liveliness_sentinel_seen, "allowed liveliness ordering sentinel at the fabric")
    if escaped_liveliness.is_set():
        inbound_direction_violations.append(
            "local liveliness token escaped into the fabric-owned inbound namespace"
        )

    wildcard_keys = []

    def record_wildcard(sample):
        wildcard_keys.append(str(sample.key_expr))

    # This session holds only the broad subscriber. Putting an exact subscriber beside it would
    # let Zenoh dispatch a sample locally after routing it to the session for the exact match.
    local_wildcard = pod_wild.declare_subscriber(
        "**", record_wildcard
    )

    control_seen = threading.Event()
    control_expr = f"{slot}/local-wildcard/**"

    control_sub = pod_control.declare_subscriber(
        control_expr, lambda _sample: control_seen.set()
    )
    readiness_key = f"{slot}/local-wildcard/readiness"
    publish_until(pod_second, readiness_key, control_seen,
                  "local slot publish at the dedicated control subscriber")

    # The query and put use DATA priority and blocking congestion control. Zenoh replies inherit
    # the query QoS, so the callback's put precedes its reply on the publishing session's reliable
    # link. Once pod_wild receives the reply, an accepted wildcard would already have seen the put.
    barrier_priority = zenoh.Priority.DATA
    barrier_congestion = zenoh.CongestionControl.BLOCK
    barrier_key = f"{slot}/local-wildcard/barrier"
    barrier_probe_key = f"{slot}/local-wildcard/probe"
    barrier_reply_seen = threading.Event()

    def answer_wildcard_barrier(query):
        pod_second.put(
            barrier_probe_key,
            "wildcard-acceptance-probe",
            priority=barrier_priority,
            congestion_control=barrier_congestion,
        )
        query.reply(barrier_key, "barrier-reply")

    wildcard_barrier_queryable = pod_second.declare_queryable(
        barrier_key, answer_wildcard_barrier
    )
    wildcard_keys.clear()
    deadline = time.monotonic() + 8
    while not barrier_reply_seen.is_set() and time.monotonic() < deadline:
        pod_wild.get(
            barrier_key,
            handler=lambda reply: barrier_reply_seen.set() if reply.ok else None,
            priority=barrier_priority,
            congestion_control=barrier_congestion,
        )
        barrier_reply_seen.wait(0.25)
    if not barrier_reply_seen.is_set():
        raise AssertionError("wildcard acceptance ordering barrier did not reply")
    if barrier_probe_key in wildcard_keys:
        raise AssertionError("router accepted a pod-local ** subscription")

    # Remove the test's own upstream wildcard subscriber before inspecting publisher matching.
    fabric_sub.undeclare()
    allowed_publisher = upstream.declare_publisher(f"{slot}/local-wildcard/matching")
    broad_publisher = upstream.declare_publisher("outside/local-wildcard/matching")
    deadline = time.monotonic() + 8
    while not allowed_publisher.matching_status.matching and time.monotonic() < deadline:
        threading.Event().wait(0.25)
    if not allowed_publisher.matching_status.matching:
        raise AssertionError("exact-key pod subscription did not propagate upstream")
    if broad_publisher.matching_status.matching:
        raise AssertionError("pod-local wildcard subscription propagated upstream")

    outside_key = "outside/fabric/blocked"
    outside_barrier_key = f"{slot}/local-wildcard/outside-barrier"
    outside_reply_seen = threading.Event()

    def answer_outside_barrier(query):
        upstream.put(
            outside_key,
            "must-not-arrive",
            priority=barrier_priority,
            congestion_control=barrier_congestion,
        )
        query.reply(outside_barrier_key, "barrier-reply")

    outside_barrier_queryable = upstream.declare_queryable(
        outside_barrier_key, answer_outside_barrier
    )
    wildcard_keys.clear()
    deadline = time.monotonic() + 8
    while not outside_reply_seen.is_set() and time.monotonic() < deadline:
        pod_wild.get(
            outside_barrier_key,
            handler=lambda reply: outside_reply_seen.set() if reply.ok else None,
            priority=barrier_priority,
            congestion_control=barrier_congestion,
        )
        outside_reply_seen.wait(0.25)
    if not outside_reply_seen.is_set():
        raise AssertionError("out-of-scope fabric ordering barrier did not reply")
    if outside_key in wildcard_keys:
        raise AssertionError("out-of-scope fabric publish reached a pod-local wildcard subscriber")

    other_keys = []
    other_slot_sub = other.declare_subscriber(
        f"{slot}/other/read",
        lambda sample: other_keys.append(str(sample.key_expr)),
    )
    pod_read_keys = []
    pod_read_seen = threading.Event()

    def record_pod_read(sample):
        pod_read_keys.append(str(sample.key_expr))
        pod_read_seen.set()

    pod_slot_sub = pod.declare_subscriber(
        f"{slot}/other/**",
        record_pod_read,
    )
    other_readiness = f"{slot}/other/readiness"
    other_target = f"{slot}/other/read"
    other_sentinel = f"{slot}/other/sentinel"
    pod_read_ready = threading.Event()
    pod_read_barrier = pod.declare_subscriber(
        other_readiness, lambda _sample: pod_read_ready.set()
    )
    publish_until(upstream, other_readiness, pod_read_ready,
                  "POD subscriber used to verify other-CN read denial")
    other_keys.clear()
    upstream.put(other_target, "must-not-reach-other-cn")
    upstream.put(other_sentinel, "ordering-sentinel")
    deadline = time.monotonic() + 8
    while other_sentinel not in pod_read_keys and time.monotonic() < deadline:
        pod_read_seen.wait(0.25)
        pod_read_seen.clear()
    if other_sentinel not in pod_read_keys:
        raise AssertionError("POD subscriber did not receive other-CN read ordering sentinel")
    if other_target in other_keys:
        raise AssertionError("other-CN session received a slot publish")

    # Keep declarations alive until every assertion has completed.
    assert all((allowed_publisher, broad_publisher, other_write_barrier, inbound_sub,
                inbound_queryable, inbound_liveliness_sub, fabric_token,
                fabric_liveliness_sub, fabric_liveliness_sentinel_sub, local_token,
                liveliness_sentinel_token, local_wildcard, control_sub,
                wildcard_barrier_queryable, outside_barrier_queryable, other_slot_sub,
                pod_slot_sub, pod_read_barrier))
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
