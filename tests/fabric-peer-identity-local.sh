#!/usr/bin/env bash
# Exercise the certificate-identity helper used by first-boot and router tests.
set -euo pipefail

POD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=host/fabric-peer-identity.sh
source "${FABRIC_IDENTITY_HELPER:-${POD_DIR}/host/fabric-peer-identity.sh}"
WORK="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

for tool in openssl python3 timeout; do
  command -v "$tool" >/dev/null 2>&1 || { echo "required tool not found: $tool"; exit 2; }
done

cat > "$WORK/tls-server.py" <<'PY'
import socket
import ssl
import sys

port, cert, key, ca = sys.argv[1:]
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
context.load_verify_locations(ca)
context.verify_mode = ssl.CERT_REQUIRED
with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", int(port)))
    listener.listen()
    while True:
        connection, _ = listener.accept()
        try:
            with context.wrap_socket(connection, server_side=True):
                pass
        except ssl.SSLError:
            connection.close()
PY

mint_ca() {
  local name="$1"
  openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/${name}-ca.key" 2>/dev/null
  openssl req -x509 -new -key "$WORK/${name}-ca.key" -sha256 -days 2 \
    -subj "/CN=${name}-ca" -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$WORK/${name}-ca.pem" 2>/dev/null
}

mint_leaf() {
  local name="$1" cn="$2" ca="$3"
  openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/${name}.key" 2>/dev/null
  openssl req -new -key "$WORK/${name}.key" -subj "/CN=${cn}" -out "$WORK/${name}.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth,clientAuth\n' \
    > "$WORK/${name}.ext"
  openssl x509 -req -in "$WORK/${name}.csr" -CA "$WORK/${ca}-ca.pem" \
    -CAkey "$WORK/${ca}-ca.key" -CAcreateserial -CAserial "$WORK/${ca}-ca.srl" \
    -days 2 -sha256 -extfile "$WORK/${name}.ext" -out "$WORK/${name}.pem" 2>/dev/null
}

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

start_server() {
  local cert="$1" ca="$2"
  [ -z "$SERVER_PID" ] || { kill "$SERVER_PID" >/dev/null 2>&1 || true; wait "$SERVER_PID" 2>/dev/null || true; }
  SERVER_PORT="$(free_port)"
  python3 "$WORK/tls-server.py" "$SERVER_PORT" "$WORK/${cert}.pem" \
    "$WORK/${cert}.key" "$WORK/${ca}-ca.pem" \
    >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 50); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$WORK/server.log" >&2
      echo "TLS stand-in exited before accepting connections" >&2
      exit 1
    fi
    if python3 - "$SERVER_PORT" <<'PY'
import socket
import sys

try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2):
        pass
except OSError:
    raise SystemExit(1)
PY
    then
      return
    fi
    sleep 0.1
  done
  cat "$WORK/server.log" >&2
  echo "TLS stand-in did not accept connections within 5 seconds" >&2
  exit 1
}

expect_refusal() {
  local description="$1" expected="$2"
  shift 2
  if "$@" >"$WORK/refusal.out" 2>&1; then
    echo "expected refusal: $description" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$WORK/refusal.out"; then
    echo "refusal used the wrong rule: $description" >&2
    cat "$WORK/refusal.out" >&2
    exit 1
  fi
  if awk 'length > 80 { found=1 } END { exit !found }' "$WORK/refusal.out"; then
    echo "refusal output exceeds 80 columns: $description" >&2
    awk 'length > 80 { print length ": " $0 }' "$WORK/refusal.out" >&2
    exit 1
  fi
}

mint_ca trusted
mint_ca untrusted
mint_leaf pod pod-client trusted
mint_leaf router fabric-router trusted
mint_leaf wrong-ca-router fabric-router untrusted
mint_leaf unsafe-router 'fabric router' trusted
mint_leaf same-cn pod-client trusted

parse_fabric_tls_endpoint 'tls/router.example:7447?rel=0'
[ "$FABRIC_TLS_ADDRESS" = 'router.example:7447' ] && [ "$FABRIC_TLS_HOST" = router.example ] \
  || { echo "plain-host TLS endpoint parsing failed"; exit 1; }
parse_fabric_tls_endpoint 'tls/[2001:db8::1]:7447#router'
[ "$FABRIC_TLS_ADDRESS" = '[2001:db8::1]:7447' ] && [ "$FABRIC_TLS_HOST" = '2001:db8::1' ] \
  || { echo "bracketed-IPv6 TLS endpoint parsing failed"; exit 1; }

start_server router trusted
if ! resolve_fabric_certificate_cn "tls/127.0.0.1:${SERVER_PORT}?rel=0#peer" "" pod-client \
  "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"; then
  cat "$WORK/server.log" >&2
  exit 1
fi
[ "$FABRIC_ROUTER_CERT_CN" = fabric-router ] || { echo "verified discovery returned the wrong CN"; exit 1; }

resolve_fabric_certificate_cn "tls/127.0.0.1:${SERVER_PORT}" fabric-router pod-client \
  "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"
expect_refusal "a TLS pin that differs from the presented CN" \
  'router CN does not match the configured pin' \
  resolve_fabric_certificate_cn "tls/127.0.0.1:${SERVER_PORT}" other-router pod-client \
    "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"

start_server wrong-ca-router trusted
expect_refusal "a router certificate signed by an untrusted CA" \
  'CA-verified mTLS handshake did not verify' \
  resolve_fabric_certificate_cn "tls/127.0.0.1:${SERVER_PORT}" "" pod-client \
    "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"

start_server unsafe-router trusted
expect_refusal "a router CN containing unsupported characters" \
  'router certificate CN has unsupported characters' \
  resolve_fabric_certificate_cn "tls/127.0.0.1:${SERVER_PORT}" "" pod-client \
    "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"

start_server same-cn trusted
expect_refusal "identical pod and router CNs" \
  'router and pod certificate CNs are identical' \
  resolve_fabric_certificate_cn "tls/127.0.0.1:${SERVER_PORT}" "" pod-client \
    "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"

expect_refusal "a non-TLS endpoint without an operator-provided CN" \
  'non-TLS endpoint has no router certificate CN pin' \
  resolve_fabric_certificate_cn 'quic/router.example:7448' "" pod-client \
    "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"
resolve_fabric_certificate_cn 'quic/router.example:7448' fabric-router pod-client \
  "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"
expect_refusal "an empty pod certificate CN" \
  'pod identity check failed: certificate CN is missing or unsupported' \
  resolve_fabric_certificate_cn 'quic/router.example:7448' fabric-router "" \
    "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"
expect_refusal "a TLS endpoint without a port" \
  'TLS endpoint has no supported host:port' \
  resolve_fabric_certificate_cn 'tls/router.example#peer' "" pod-client \
    "$WORK/pod.pem" "$WORK/pod.key" "$WORK/trusted-ca.pem"

echo "PASS: fabric peer discovery verifies trust, endpoint syntax, safe CNs, pins, and distinct identities"
