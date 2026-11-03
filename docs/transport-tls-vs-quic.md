# Transport: TLS vs QUIC

**One idea:** Zenoh picks the transport from the **scheme of the endpoint you
dial** — everything else (identity, ACL, key expressions, code) is unchanged.

```
tls/<router>:7447    →  TLS over TCP   (the fleet default today)
quic/<router>:7448   →  QUIC over UDP  (enabled on the zagros sandbox; opt-in)
```

Both use the same mTLS client cert, the same offline-CA root, and the same
slot ACL (keyed off the cert CN — the `cert_common_names` subject axis on
zagros). On the PQ / PQ-FIPS router image both negotiate
**X25519MLKEM768** from the same crypto provider — so **post-quantum is free on
either**, and is *not* a reason to choose one over the other.

Runnable proof in this pod: [`examples/transport_quic.py`](../examples/transport_quic.py)
— the same client as the TLS examples, one line different, self-contained
pub→sub round-trip so you can confirm QUIC works from your pod before relying on
it. (Validated live against a sandbox router: a QUIC client was admitted by the
same ACL and received its own publish over `quic/7448`.)

## Why you might reach for QUIC

QUIC's properties map to a **lossy / mobile / disconnected edge** — exactly where a
field-deployed pod often lives:

- **No head-of-line blocking under loss.** TCP is one ordered byte stream: a
  single lost segment stalls *everything* behind it until it is retransmitted.
  QUIC carries independent streams, so one lost packet doesn't hold up unrelated
  data. On a bursty-loss uplink this is the difference that matters.
- **Connection migration.** A QUIC connection survives the client's IP changing
  (satellite/CGNAT re-addressing, failover to a different path) without a full
  reconnect — the session is keyed on a connection ID, not the 4-tuple.
- **Faster (re)connect.** QUIC folds transport + TLS setup into fewer round
  trips, so re-establishing after a drop is quicker.

## Why the fleet still defaults to TLS

- **It works, and nothing is forcing a move.** No transport-level problem has
  been observed that QUIC would fix. TLS is the older, more widely battle-tested
  path.
- **UDP reachability.** QUIC is UDP. Inside the goat mesh it rides the same
  NetBird/WireGuard tunnel as everything else, so it reaches the router fine —
  but any environment that throttles or blocks UDP is friendlier to TCP.
- **Complexity budget.** A blanket flip is churn for no measured benefit. The
  right unit of adoption is **one endpoint at a time, against a measured win**
  (fewer stalls / reconnects for *that* endpoint), not "newer is better."

## The recommendation: know both, pick per endpoint

Neither is "the answer." **Familiarise yourself with both approaches** — the
choice is a *connect-config* decision, not a code change and not a per-message
knob. For most pods, start on TLS (the default). Move an endpoint to QUIC when
its link characteristics (bursty loss, changing IPs, frequent reconnects)
predict a real benefit, and **measure it from your own pod** — compare
reconnect and stall counts in your client logs and `goat doctor --json` probes
before and after the flip.

## What has to be true on the router

The goatnet must have the QUIC listener enabled (UDP :7448 published alongside
`tls/`:7447). It **is** enabled on the zagros
sandbox. If a goatnet has not enabled it, a `quic/` connect simply fails and you
stay on TLS — nothing else is affected. Enabling QUIC is a transport-listen
decision on the router, covered by the PQC adoption pattern (ADR 1086); the ACL,
mTLS, and slot model are identical to TLS.
