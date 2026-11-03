#!/usr/bin/env python3
"""Reference: the SAME mTLS client, over QUIC instead of TLS/TCP.

Illustrative, not production. A runnable shape you can adapt.

The point of this example is how *little* changes. Zenoh selects the transport
from the **scheme of the endpoint you dial** — nothing else moves:

    tls/<router>:7447    →  TLS over TCP   (the fleet default)
    quic/<router>:7448   →  QUIC over UDP

Same `mode: client`, same `transport/link/tls` block (the mTLS cert/key/CA and
`enable_mtls`/`verify_name_on_connect` are shared — QUIC reuses the TLS 1.3
handshake), same key expressions, same ACL. On the PQ / PQ-FIPS router image
QUIC inherits X25519MLKEM768 from the same crypto provider that gives TLS its
PQ, so **the post-quantum handshake is free on QUIC too** — it is not a reason
to pick one over the other.

WHY YOU MIGHT WANT QUIC (and why the fleet still defaults to TLS): see
`docs/transport-tls-vs-quic.md`. Short version — QUIC's per-stream independence
(no head-of-line blocking under loss), connection migration across IP changes,
and faster reconnect map well to a lossy / mobile / disconnected edge; TLS is the
battle-tested default and there is no forcing need to move. **Familiarise
yourself with both** — the choice is a connect-config decision, made per
endpoint against a measured benefit, not a blanket flip.

Requirements on the router side: the goatnet must have the QUIC listener enabled
(a router-side transport-listen decision; UDP :7448 published) — it is on the zagros
sandbox. If it is not enabled on your goatnet, the connect simply fails and you
stay on TLS; nothing else is affected.

This example is a self-contained round-trip (one session both publishes and
subscribes under your own slot) so you can PROVE QUIC works end to end from your
pod before you rely on it. It has been validated live against a sandbox router:
a QUIC client was admitted by the same ACL and the subscriber
received the publish over `quic/7448`.

Connection config comes from the goat profile the pod/bundle gives you — set
GOAT_ROUTER to the QUIC endpoint (note the `quic/` scheme and :7448 port):
  GOAT_ROUTER     quic/<router-host>:7448      (vs tls/<router-host>:7447)
  GOAT_MTLS_CERT  path to mtls.cert.pem        (SAME cert as TLS)
  GOAT_MTLS_KEY   path to mtls.key.pem
  GOAT_CA_ROOTS   path to ca-roots.pem
  GOAT_KEY_EXPR   a key under YOUR slot, e.g. <slot_id>/hello   (default below)

Run:
  GOAT_ROUTER=quic/<your-goatnet-router>:7448 \
  GOAT_MTLS_CERT=... GOAT_MTLS_KEY=... GOAT_CA_ROOTS=... \
  GOAT_KEY_EXPR=<slot_id>/hello  python3 transport_quic.py
Deps: pip install eclipse-zenoh==1.9.0
"""

import json
import os
import sys
import time

import zenoh


def open_session(endpoint: str) -> zenoh.Session:
    """Open an mTLS client session against the goat router over `endpoint`.

    The transport is chosen entirely by the endpoint scheme (tls/ vs quic/);
    the mTLS block is inserted whole (per-sub-key inserts do NOT enable the
    client-cert send path on eclipse-zenoh-python 1.x).
    """
    conf = zenoh.Config()
    conf.insert_json5("mode", json.dumps("client"))
    conf.insert_json5("connect/endpoints", json.dumps([endpoint]))
    conf.insert_json5("transport/link/tls", json.dumps({
        "root_ca_certificate": os.environ["GOAT_CA_ROOTS"],
        "connect_certificate": os.environ["GOAT_MTLS_CERT"],
        "connect_private_key": os.environ["GOAT_MTLS_KEY"],
        "enable_mtls": True,
        # Off because the fabric router cert's SAN binds its mesh address, not the
        # DNS name being dialed — turning it on fails the handshake (matches the
        # rendered pod router config in host/zenoh-router.json5.tmpl).
        "verify_name_on_connect": False,
    }))
    return zenoh.open(conf)


def main() -> int:
    endpoint = os.environ.get("GOAT_ROUTER", "")
    if not endpoint:
        # No baked-in fallback on purpose: a default endpoint silently dials whichever
        # goatnet the example was written against. Bundles publish only the TLS
        # endpoint (tls/<host>:7447) in NOTES.md — pasting that here opens a working
        # TLS session and the example silently stops demonstrating QUIC. The QUIC
        # listener address comes from the goat-side operator.
        print("GOAT_ROUTER is not set. Set it to your goatnet's QUIC listener, "
              "e.g. quic/<host>:<port>. Your bundle's NOTES.md carries only the "
              "TLS endpoint; ask your goat-side operator for the QUIC listener "
              "address.", file=sys.stderr)
        return 2
    key = os.environ.get("GOAT_KEY_EXPR", "CHANGE-ME-slot/hello")
    scheme = endpoint.split("/", 1)[0]
    print(f"[transport] dialing {endpoint}  (transport = {scheme.upper()})", flush=True)

    t0 = time.time()
    session = open_session(endpoint)
    print(f"[transport] session open in {int((time.time() - t0) * 1000)} ms", flush=True)

    got = []
    sub = session.declare_subscriber(
        key + "/**",
        lambda sample: got.append((str(sample.key_expr), sample.payload.to_bytes())),
    )
    time.sleep(1.0)  # let the subscription propagate to the router

    payload = b"transport-check " + scheme.encode() + b" " + str(int(time.time())).encode()
    pub = session.declare_publisher(key + "/transport-check")
    pub.put(payload)
    print(f"[transport] published {payload!r} on {key}/transport-check", flush=True)

    time.sleep(2.5)
    session.close()

    ok = any(payload in p for _, p in got)
    print(f"[transport] received: {got}", flush=True)
    if ok:
        print(f"RESULT: PASS — {scheme.upper()} pub->sub round-trip through the router + ACL", flush=True)
        return 0
    print("RESULT: FAIL — no delivery. Check: (1) QUIC listener enabled on this "
          "goatnet (UDP :7448)? (2) GOAT_KEY_EXPR under YOUR slot? "
          "(3) cert admitted by the ACL? (a silent ACL denial looks exactly like this).",
          file=sys.stderr, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
