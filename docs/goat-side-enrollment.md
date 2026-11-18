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

The complete handover contains:

| Input | Supplied by | Single-use |
|---|---|---|
| `GOATNET` | Goat side, in the welcome package | No |
| `NETBIRD_MANAGEMENT_URL` | Goat side, in the welcome package | No |
| `NETBIRD_SETUP_KEY` | Goat side, in the welcome package | Yes |
| `PARTNER_NAMESPACE` (the slot ID) | Goat side, in the welcome package | No |
| `POD_ID` | Goat side, in the welcome package | No |
| Signed join bundle (tarball or `.cbor`) | Goat side | No |
| CA root (`CA_ROOT_PEM`, or the `.pem` in the bundle tarball) | Goat side | No |
| `EXPECTED_CA_FINGERPRINT` | Goat side, through a different channel from the CA root | No |
| `goat` binary and its `.sha256` file | Goat side | No |
| Host, Docker, encrypted state volume | Partner, prepared in Part 1 | No |

`POD_ID` is the host name NetBird registers for this POD: 1-59 lowercase letters, digits, or
hyphens, starting and ending with a letter or digit.

The partner's `goat` trusts no CA root until they add the goatnet's root, and `first-boot.sh`
cannot verify the bundle without it. The onboarding tarball carries it as
`<prefix>-goat-cli-ca.pem` only when the portal that built it is set up to ship the root;
confirm the tarball has it, or copy it from an enrolled workstation into the package.
Tell the partner which CA-ID signs the bundle and provide that root's fingerprint through a
channel other than the one that carries the root. `moon_pod_setup.sh` requires
`EXPECTED_CA_FINGERPRINT` unless the POD already trusts a CA root and refuses a mismatch.
Deliver the host-architecture `goat` binary with its matching `.sha256` file; Part 1 refuses
an unverified binary.

## Operator authorization

Operator verbs authorize by the per-person op_ key installed as the goat profile's
portal token. `E_NOT_ADMIN` with a valid credential means the presented token's
identity holds no active op_ key; fix the key, not the role.
