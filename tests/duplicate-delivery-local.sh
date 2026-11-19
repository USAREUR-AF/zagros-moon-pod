#!/usr/bin/env bash
# Measure whether one publication reaches a core subscriber more than once when the publisher
# has two live paths to the core (ADR 1251 phase 1, goatcore design pod-carriage-and-provenance §6).
#
# Topology (zenohd 1.9.0, pinned by digest like the other fixtures):
#   core router  <-- pod-a router (network A)
#                <-- pod-b router (network B)
# The two pods sit on separate Docker networks, as two sites would, and both dial the core.
# Each pod is rendered from host/zenoh-router.json5.tmpl with its own router certificate and ID,
# and admits one device certificate as the writer of the device's slot (the shape a carriage
# rule renders). The subscriber is a client of the core.
#
# Cases (the publisher always uses the device certificate):
#   control-client-one-pod  client mode, connect = [pod-a]                 expected 1 per publication
#   client-two-pods         client mode, connect = [pod-a, pod-b]
#   peer-pod-and-core       peer mode,   connect = [pod-a, core]
#   peer-two-pods           peer mode,   connect = [pod-a, pod-b]
#
# Each case runs RUNS times with a fresh publisher session, publishing N sequence-numbered samples
# with reliable transport and blocking congestion control. The script prints, per run, the
# routers and peers the publisher session was connected to and how many samples arrived 0, 1, 2
# or more times. It fails only when the control case is not exactly once per publication.
#
# Usage: N=1000 RUNS=3 bash tests/duplicate-delivery-local.sh [results.json]
set -euo pipefail

POD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=host/fabric-peer-identity.sh
source "${POD_DIR}/host/fabric-peer-identity.sh"
ROUTER_TEMPLATE="${ROUTER_TEMPLATE:-${POD_DIR}/host/zenoh-router.json5.tmpl}"
IMAGE="eclipse/zenoh:1.9.0@sha256:157965d71e0bfd0a044d76a985ff0e5c306ad3968929168fb9678cd2a7fec23f"
N="${N:-1000}"
RUNS="${RUNS:-3}"
RESULTS="${1:-}"
DEVICE_SLOT="7f3c2a10-0000-4000-8000-00000000d0d1"
DEVICE_CN="${DEVICE_SLOT}.g1"
INBOUND="release/goat"
FABRIC_CN="synthetic-fabric-router"
CORE_ZID="c0e0000000000000000000000000c0e1"
WORK="$(mktemp -d "${POD_DIR}/.duplicate-delivery.XXXXXX")"
RUN_ID="$(basename "$WORK" | tr -cd 'A-Za-z0-9')"
NET_A="moon-dup-a-${RUN_ID}"
NET_B="moon-dup-b-${RUN_ID}"
CORE="moon-dup-core-${RUN_ID}"
POD_A="moon-dup-pod-a-${RUN_ID}"
POD_B="moon-dup-pod-b-${RUN_ID}"

log() { printf '==> %s\n' "$*"; }
dump() {
  for c in "$CORE" "$POD_A" "$POD_B"; do
    echo "--- $c"
    docker logs "$c" 2>&1 | tail -n 60 || true
  done
}
cleanup() {
  docker rm -f "$POD_A" "$POD_B" "$CORE" >/dev/null 2>&1 || true
  docker network rm "$NET_A" "$NET_B" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

for tool in docker envsubst openssl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool not found: $tool"; exit 2; }
done

mkdir -p "$WORK/tls"
openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/tls/ca.key" 2>/dev/null
openssl req -x509 -new -key "$WORK/tls/ca.key" -sha256 -days 2 \
  -subj "/CN=synthetic-duplicate-ca" -addext "basicConstraints=critical,CA:TRUE" \
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
mint_leaf core "$FABRIC_CN"
mint_leaf pod-a "7f3c2a10-0000-4000-8000-0000000000aa.g1"
mint_leaf pod-b "7f3c2a10-0000-4000-8000-0000000000bb.g1"
mint_leaf device "$DEVICE_CN"
mint_leaf observer "synthetic-core-observer"

cat > "$WORK/core.json5" <<EOF
{
  id: "${CORE_ZID}",
  mode: "router",
  listen: { endpoints: ["tls/0.0.0.0:7448"] },
  scouting: { multicast: { enabled: false } },
  transport: { link: { tls: {
    listen_certificate: "/work/tls/core.pem",
    listen_private_key: "/work/tls/core.key",
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

docker network create "$NET_A" >/dev/null
docker network create "$NET_B" >/dev/null
CORE_PORT="$(free_port)"
POD_A_PORT="$(free_port)"
POD_B_PORT="$(free_port)"
docker run -d --name "$CORE" --network "$NET_A" --network-alias upstream \
  -p "127.0.0.1:${CORE_PORT}:7448" -v "$WORK:/work:ro" "$IMAGE" -c /work/core.json5 >/dev/null
docker network connect --alias upstream "$NET_B" "$CORE"

# shellcheck disable=SC2016
render_pod() {
  local name="$1" out="$2"
  local cn
  cn="$(openssl x509 -in "$WORK/tls/${name}.pem" -noout -subject -nameopt multiline | awk -F' = ' '/commonName/ {print $2}')"
  # The router presents its own certificate and ID; the admitted writer (POD_CERT_CN) is the
  # device certificate, scoped to the device slot, as a rendered carriage rule would admit it.
  ZENOH_LISTEN_PORT=7447 ZENOH_FABRIC_ENDPOINT="tls/upstream:7448" \
    PARTNER_NAMESPACE="$DEVICE_SLOT" INBOUND_NAMESPACE="$INBOUND" \
    POD_CERT_CN="$DEVICE_CN" FABRIC_ROUTER_CERT_CN="$FABRIC_CN" \
    POD_ROUTER_ZID="$(derive_pod_router_zid "$cn")" \
    POD_CERT_PEM="/work/tls/${name}.pem" POD_KEY_PEM="/work/tls/${name}.key" CA_ROOTS_PEM=/work/tls/ca.pem \
    envsubst \
    '${ZENOH_LISTEN_PORT} ${POD_ROUTER_ZID} ${ZENOH_FABRIC_ENDPOINT} ${PARTNER_NAMESPACE} ${INBOUND_NAMESPACE} ${POD_CERT_CN} ${FABRIC_ROUTER_CERT_CN} ${POD_CERT_PEM} ${POD_KEY_PEM} ${CA_ROOTS_PEM}' \
    < "$ROUTER_TEMPLATE" > "$out"
  if grep -Fq '"${' "$out"; then
    echo "rendered router config for $name still contains placeholders"
    exit 1
  fi
  derive_pod_router_zid "$cn"
}
POD_A_ZID="$(render_pod pod-a "$WORK/pod-a.json5")"
POD_B_ZID="$(render_pod pod-b "$WORK/pod-b.json5")"

docker run -d --name "$POD_A" --network "$NET_A" \
  -p "127.0.0.1:${POD_A_PORT}:7447" -v "$WORK:/work:ro" "$IMAGE" -c /work/pod-a.json5 >/dev/null
docker run -d --name "$POD_B" --network "$NET_B" \
  -p "127.0.0.1:${POD_B_PORT}:7447" -v "$WORK:/work:ro" "$IMAGE" -c /work/pod-b.json5 >/dev/null

log "installing the Zenoh 1.9.0 test client"
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/pip" install -q eclipse-zenoh==1.9.0

log "measuring delivery count per publication (N=${N}, RUNS=${RUNS})"
if ! "$WORK/venv/bin/python" -I - "$CORE_PORT" "$POD_A_PORT" "$POD_B_PORT" "$WORK/tls" \
  "$DEVICE_SLOT" "$N" "$RUNS" "$CORE_ZID" "$POD_A_ZID" "$POD_B_ZID" "${RESULTS:-}" <<'PY'
import collections
import json
import sys
import threading
import time

import zenoh

(core_port, pod_a_port, pod_b_port, tls, slot, n, runs,
 core_zid, pod_a_zid, pod_b_zid, results_path) = sys.argv[1:]
n, runs = int(n), int(runs)
names = {core_zid: "core", pod_a_zid: "pod-a", pod_b_zid: "pod-b"}
ports = {"core": core_port, "pod-a": pod_a_port, "pod-b": pod_b_port}

def config(mode, targets, identity):
    return zenoh.Config.from_json5(json.dumps({
        "mode": mode,
        "connect": {"endpoints": [f"tls/127.0.0.1:{ports[t]}" for t in targets]},
        # Fixed topology: no multicast or gossip discovery, so the paths are the ones listed.
        "scouting": {"multicast": {"enabled": False}, "gossip": {"enabled": False}},
        "transport": {"link": {"tls": {
            "root_ca_certificate": f"{tls}/ca.pem",
            "connect_certificate": f"{tls}/{identity}.pem",
            "connect_private_key": f"{tls}/{identity}.key",
            "enable_mtls": True,
            "verify_name_on_connect": False,
        }}},
    }))

def open_retry(cfg, what):
    last = None
    for _ in range(30):
        try:
            return zenoh.open(cfg)
        except Exception as exc:  # routers may still be starting
            last = exc
            time.sleep(1)
    raise AssertionError(f"{what} did not connect: {last}")

CASES = (
    ("control-client-one-pod", "client", ("pod-a",)),
    ("client-two-pods", "client", ("pod-a", "pod-b")),
    ("peer-pod-and-core", "peer", ("pod-a", "core")),
    ("peer-two-pods", "peer", ("pod-a", "pod-b")),
)

observer = open_retry(config("client", ("core",), "observer"), "core observer")
counts = collections.Counter()
last_arrival = [time.monotonic()]
ready = threading.Event()
lock = threading.Lock()

def on_sample(sample):
    body = sample.payload.to_string()
    with lock:
        if body.endswith(":ready"):
            ready.set()
            return
        counts[body] += 1
        last_arrival[0] = time.monotonic()

subscriber = observer.declare_subscriber(f"{slot}/dup/**", on_sample)
report = {"n": n, "runs": runs, "zenoh": "1.9.0", "cases": []}
control_ok = True

for case, mode, targets in CASES:
    for run in range(1, runs + 1):
        pub = open_retry(config(mode, targets, "device"), f"{case} publisher")
        time.sleep(1)
        key = f"{slot}/dup/{case}"
        ready.clear()
        deadline = time.monotonic() + 15
        while not ready.is_set() and time.monotonic() < deadline:
            pub.put(key, f"{case}:{run}:ready")
            ready.wait(0.25)
        if not ready.is_set():
            raise AssertionError(f"{case} run {run}: no readiness sample reached the core")
        # Let both paths finish declaring routes before counting.
        time.sleep(3)
        routers = sorted(names.get(str(z), str(z)) for z in pub.info.routers_zid())
        peers = sorted(names.get(str(z), str(z)) for z in pub.info.peers_zid())
        with lock:
            counts.clear()
        started = time.monotonic()
        for seq in range(n):
            pub.put(key, f"{case}:{run}:{seq}",
                    congestion_control=zenoh.CongestionControl.BLOCK)
        sent_s = time.monotonic() - started
        with lock:
            last_arrival[0] = time.monotonic()
        # Wait for quiescence: 3 s with no new sample, at most 30 s.
        end = time.monotonic() + 30
        while time.monotonic() < end and time.monotonic() - last_arrival[0] < 3:
            time.sleep(0.2)
        with lock:
            per_seq = [counts.get(f"{case}:{run}:{seq}", 0) for seq in range(n)]
        hist = collections.Counter(per_seq)
        row = {
            "case": case, "mode": mode, "connect": list(targets), "run": run,
            "publisher_routers": routers, "publisher_peers": peers,
            "received_total": sum(per_seq),
            "times_received": {str(k): v for k, v in sorted(hist.items())},
            "publish_seconds": round(sent_s, 3),
        }
        report["cases"].append(row)
        print(f"{case:24s} run {run}: routers={routers} peers={peers} "
              f"received={row['received_total']}/{n} times_received={row['times_received']}")
        if case.startswith("control-") and hist != collections.Counter({1: n}):
            control_ok = False
        pub.close()

subscriber.undeclare()
observer.close()
if results_path:
    with open(results_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, indent=2)
if not control_ok:
    raise AssertionError("control case was not exactly once per publication; fixture is not sound")
print("PASS: measurement complete")
PY
then
  dump
  exit 1
fi
