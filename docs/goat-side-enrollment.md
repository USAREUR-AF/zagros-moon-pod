# Goat-side enrollment (operator runbook)

The partner's bundle exists only after the goat side enrolls the pod machine. This is
the operator's half of [`partner-run-guide.md`](partner-run-guide.md): what to run, and
the sharp edges as they stand today.

## Seed the custodian's grant (once)

```
goat machine grant <custodian> --quota N --affiliation <organisation>
```

`--affiliation` is required only on the first seed and stamps every machine this
custodian enrolls. Copy the exact string from the existing fleet (`goat machine ls`
shows it per row in parentheses); a second spelling of the same organisation forks the
registry. That fork is a server-side bug, not doctrine — a fix is up as
a goatcore change (the portal will
refuse a case/whitespace respelling of an organisation already on file, naming the existing
spelling); until it merges, exact-copy is the discipline. Adjusting an existing
quota omits the flag.

## Enroll the pod

PLATFORM class requires `--workloads` so the machine's mesh groups derive from the
functions the pod performs.

Known goat 0.4.43 bug: the CLI lowercases workloads into a case-sensitive server-side
derivation map, so every CLI enroll of a PLATFORM machine fails with a 400. Until the
fix lands, POST the API directly with UPPERCASE workloads and the operator's portal
token as Bearer.

Keep the token off the command line: an inline `-H "Authorization: Bearer ..."` lands
in shell history and is readable in `ps` for the life of the request. Put the header
in a file and hand curl the file:

```
read -rs TOKEN        # paste the operator portal token; nothing echoes
install -m 600 /dev/null /tmp/enroll-hdr
printf 'Authorization: Bearer %s\n' "$TOKEN" > /tmp/enroll-hdr
unset TOKEN

curl -X POST <portal>/api/machines/enroll \
  -H @/tmp/enroll-hdr \
  -H 'Content-Type: application/json' \
  -d '{"machine_handle":"<handle>","node_class":"PLATFORM","autonomy":"supervised",
       "workloads":["KID"],"custodian":"<custodian>"}'

rm /tmp/enroll-hdr
```

For the base pod (router + audit-sink), `["KID"]` is the derived-data workload set.

## When an enroll refuses

The CLI's 400 is a composite guess-list and hides the server's message. Repeat the
request with curl and read the JSON `error.message`; it names the actual objection
(for example `no_mesh_mapping`).

## Handle the mint response as a secret

A successful mint returns the slot, the machine's portal api_key, a tokenized bundle
URL, and a single-use mesh setup key with a 720h join window. Treat the whole response
as a secret in transit. Fetch the bundle tarball and deliver it to the pod host
out-of-band; a lapsed setup key is re-minted quota-neutrally with
`goat machine mesh-key <handle>` (no re-enroll).

The partner's `goat` trusts no CA until they add your goatnet's root, and `first-boot.sh`
cannot verify the bundle without it. The bundle tarball carries the root as
`<prefix>-goat-cli-ca.pem` only when the portal that built it is set up to ship the bundle-signing
CA's public key; confirm your tarball has it, or tell the partner to take the root from
`get.<goatnet>/ca-roots/`. With the package, tell them which CA-ID signs their bundle
and give them that root's fingerprint (`goat ca ls` on a machine that already trusts it)
through a channel other than the one that serves the root file — the fingerprint is the check,
so it must not arrive by the same road as the thing it checks. `moon_pod_setup.sh` will not add
the root until the partner confirms that fingerprint or passes it as `EXPECTED_CA_FINGERPRINT`.

## Operator authorization

Operator verbs authorize by the per-person op_ key installed as the goat profile's
portal token. `E_NOT_ADMIN` with a valid credential means the presented token's
identity holds no active op_ key; fix the key, not the role.
