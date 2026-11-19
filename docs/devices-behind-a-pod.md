# Devices behind a pod

How a device that connects through this pod is identified today, the one key convention to use until that changes, and
what changes next. Canon: goatcore
[ADR 1251](https://github.com/USAREUR-AF/goatcore/blob/main/docs/adr/1251-every-source-keeps-its-identity-through-a-pod-carriage-rules-provenance-at-entry-and-pod-local-authority.md)
and [`pod-carriage-and-provenance.md`](https://github.com/USAREUR-AF/goatcore/blob/main/docs/design/pod-carriage-and-provenance.md).

## Today: everything behind the pod is the pod

The pod router admits local clients with the pod's own certificate (`pod-peer` in
[`host/zenoh-router.json5.tmpl`](../host/zenoh-router.json5.tmpl)), and the goat core router accepts writes from the pod's
connection only under the pod's slot. A device behind the pod therefore has no identity of its own on the fabric:

- It publishes under `<pod-slot>/…`.
- It reads only the pod's slot and the one inbound prefix `INBOUND_NAMESPACE`.
- Shutting off the pod's slot stops every device behind it.

A device that holds its own goat identity (for example a billie node) and connects to goat directly is managed on its own,
and none of this applies to it.

## Do not hand-edit the pod's ACL

Adding another slot to the pod's ACL changes nothing at the core: the core router still accepts only the pod's slot from the
pod's connection and drops the rest without an error. Remove any hand-added entries and keep the ACL as `first-boot.sh`
renders it.

## Interim key convention

Until per-device identity through a pod is built, data that the pod forwards for a device goes under:

```
<pod-slot>/routed/<source-slot>/<rest of the key>
```

- `<source-slot>` is the device's own slot when it has one, otherwise a stable name the pod's operator assigns.
- **The `<source-slot>` segment is unverified.** Any client of the pod can write any value there. Subscribers must not
  treat it as proof of who published.
- Use it so that every pod names routed data the same way, and so that each device's data can move to its own slot later
  without subscribers guessing.

## What changes next

| Change | Status |
|---|---|
| Carriage rules: which pods may forward which devices, written per org and rendered into the pod's and the core's ACLs | Designed, not built |
| Each device publishes and reads through the pod under its own slot | Designed, not built |
| A signed record of where each sample entered goat (device-signed, adapter-attested, pod-vouched) | Designed, not built |
| A pod cut off from goat keeps its last rules; a named local authority changes them on site | Designed, not built |

When carriage rules reach a pod, a device that holds its own slot moves with a route-only update (no new certificate), a
device without one is enrolled, and the pod's operator retires the `<pod-slot>/routed/` prefix.
