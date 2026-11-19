#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIRST_BOOT_SCRIPT="${FIRST_BOOT_SCRIPT_UNDER_TEST:-$ROOT/host/first-boot.sh}"
WORK="$(mktemp -d)"
cleanup() {
    find "$WORK" \( -type f -o -type l \) -delete 2>/dev/null || true
    find "$WORK" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup EXIT

REPO="$WORK/repo"
BIN="$WORK/bin"
mkdir -p "$REPO/host" "$REPO/profiles/test" "$REPO/compose" "$BIN"
cp "$FIRST_BOOT_SCRIPT" "$ROOT/host/zenoh-router.json5.tmpl" \
    "$ROOT/host/goat-doctor.sh" "$ROOT/host/fabric-peer-identity.sh" \
    "$ROOT/host/goat-context.sh" \
    "$ROOT/host/secure-remove.sh" \
    "$ROOT/host/goat-doctor.service.example" \
    "$ROOT/host/goat-doctor.timer.example" \
    "$ROOT/host/goat-pod-api.service.example" "$REPO/host/"
: > "$WORK/bundle.cbor"

cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
cat > "$BIN/goat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_GOAT_CALLS:?}"
case "${1:-} ${2:-}" in
  "ca ls") printf '{"count":%s}\n' "${STUB_CA_COUNT:-1}" ;;
  "profile init"|"profile rotate")
    if [ "${STUB_INIT_FAILS:-0}" = 1 ]; then
      echo 'E_BUNDLE_INVALID: bundle activation deadline (unix=1) passed at now=2 — operator must reissue' >&2
      exit 1
    fi
    context="${GOAT_CONTEXT:-default}"
    dir="$GOAT_PROFILE_DIR/contexts/$context"
    mkdir -p "$dir"
    printf 'cert\n' > "$dir/mtls.cert.pem"
    printf 'key\n' > "$dir/mtls.key.pem"
    printf 'roots\n' > "$dir/ca-roots.pem"
    printf 'router_endpoint = "tls/example.invalid:7447"\n' > "$dir/profile.toml"
    printf 'current_context = "%s"\n' "$context" > "$GOAT_PROFILE_DIR/config.toml" ;;
  *) exit 0 ;;
esac
EOF
cat > "$BIN/openssl" <<'EOF'
#!/usr/bin/env bash
cert_cn="${STUB_CERT_CN:-slot-a}"
case "$*" in
  *contexts/default/mtls.cert.pem*) cert_cn="${STUB_DEFAULT_CERT_CN:-$cert_cn}" ;;
esac
case " $* " in
  *" s_client "*)
    printf '%s\n' '-----BEGIN CERTIFICATE-----' 'fixture' \
        '-----END CERTIFICATE-----' 'Verify return code: 0 (ok)' ;;
  *" -nameopt RFC2253 "*)
    if [ "${STUB_NO_CN:-0}" = 1 ]; then
      printf 'subject=O=example\n'
    else
      printf 'subject=CN=%s\n' "$cert_cn"
    fi ;;
  *" -in "*)
    printf '    CN = %s\n' "$cert_cn" ;;
  *)
    printf '    CN = %s\n' "${STUB_FABRIC_CERT_CN:-fabric-router}" ;;
esac
EOF
cat > "$BIN/install" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -d ]; then
  shift
  while [[ "${1:-}" = -* || "${1:-}" =~ ^[0-9]+$ ]]; do shift; done
  mkdir -p "$@"
  exit
fi
args=("$@")
src="${args[${#args[@]}-2]}"; dst="${args[${#args[@]}-1]}"
cp "$src" "$dst"
EOF
cat > "$BIN/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "inspect -f {{.State.Status}} goat-moon-zenoh-router") echo running ;;
  "inspect -f {{if .State.Health}}{{.State.Health.Status}}{{end}} goat-moon-zenoh-router")
    echo healthy ;;
esac
exit 0
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_SYSTEMCTL_CALLS:?}"
EOF
cat > "$BIN/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_CHOWN_CALLS:?}"
EOF
chmod +x "$BIN"/*

SYSTEMD_UNIT_DIR="$WORK/systemd-units"
SYSTEMD_RUNTIME_DIR="$WORK/systemd-runtime"
mkdir -p "$SYSTEMD_UNIT_DIR" "$SYSTEMD_RUNTIME_DIR"
export SYSTEMD_UNIT_DIR SYSTEMD_RUNTIME_DIR
export STUB_CHOWN_CALLS="$WORK/chown-calls"

write_profile() {
    cat > "$REPO/profiles/test/profile.env" <<EOF
POD_STATE_DIR=$WORK/state
PARTNER_NAMESPACE=slot-a
POD_ID=test-pod
VERIFY_CERT_SLOT_BINDING=$1
GOAT_CLIENT_MODE=netbird-only
ZENOH_LISTEN_PORT=7447
EOF
}

write_installed_profile() {
    local context="${1:-default}" configured="${2:-${1:-default}}"
    local profile_dir="$WORK/state/goat-cli" context_dir
    context_dir="$profile_dir/contexts/$context"
    mkdir -p "$context_dir"
    printf 'current_context = "%s"\n' "$configured" > "$profile_dir/config.toml"
    printf 'live-cert\n' > "$context_dir/mtls.cert.pem"
    printf 'live-key\n' > "$context_dir/mtls.key.pem"
    printf 'live-roots\n' > "$context_dir/ca-roots.pem"
    printf 'router_endpoint = "tls/example.invalid:7447"\n' > "$context_dir/profile.toml"
    sha256sum "$WORK/bundle.cbor" | cut -d' ' -f1 > "$profile_dir/.bundle.sha256"
}

write_profile 1
mkdir -p "$WORK/state"

mkdir -p "$WORK/state/.bundle-preflight.left"
printf 'fake-key\n' > "$WORK/state/.bundle-preflight.left/mtls.key.pem"
: > "$WORK/goat-calls"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    STUB_SYSTEMCTL_CALLS="$WORK/systemctl-calls" \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/first-run.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] \
    || { echo "FAIL: first full run exited $status" >&2; exit 1; }
if find "$WORK/state" -maxdepth 1 -name '.bundle-preflight.*' -print | grep -q .; then
    echo "FAIL: first-boot left a pre-flight profile with key copies" >&2
    exit 1
fi

find "$WORK/state" \( -type f -o -type l \) -delete
find "$WORK/state" -depth -type d -empty -delete
mkdir -p "$WORK/state"
printf 'original bundle\n' > "$WORK/bundle.cbor"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CA_COUNT=0 \
    IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/no-trust.out" 2>&1
status=$?
set -e
[ "$status" -eq 3 ] || { echo "FAIL: empty trust store exited $status" >&2; exit 1; }
grep -q "no CA root is trusted under $WORK/state/goat-cli" "$WORK/no-trust.out" \
    || { echo "FAIL: empty trust message did not name the live profile" >&2; exit 1; }
if grep -q '.bundle-preflight' "$WORK/no-trust.out"; then
    echo "FAIL: empty trust message named the throwaway profile" >&2
    exit 1
fi

find "$WORK/state" \( -type f -o -type l \) -delete
find "$WORK/state" -depth -type d -empty -delete
mkdir -p "$WORK/state"
: > "$WORK/bundle.cbor"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/match.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] \
    || { echo "FAIL: matching identity preflight exited $status" >&2; exit 1; }
grep -q 'certificate identity matches slot ID' "$WORK/match.out" \
    || { echo "FAIL: matching identity preflight was not reported" >&2; exit 1; }
if awk -v work="$WORK" 'length > 80 && index($0, work) == 0 {found=1} END {exit !found}' \
        "$WORK/match.out"; then
    echo 'FAIL: identity-only first-boot output exceeded 80 columns' >&2
    exit 1
fi

write_installed_profile
: > "$WORK/goat-calls"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    STUB_INIT_FAILS=1 IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/installed.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] \
    || { echo "FAIL: installed-bundle preflight exited $status" >&2; exit 1; }
grep -q 'bundle already installed and unchanged' "$WORK/installed.out" \
    || { echo "FAIL: unchanged installed bundle was re-verified" >&2; exit 1; }
grep -q 'certificate identity matches slot ID' "$WORK/installed.out" \
    || { echo "FAIL: installed certificate binding was not checked" >&2; exit 1; }
if awk '/bundle already installed|certificate instead of re-verifying/ && length > 80 {
        print length ": " $0; found=1
    } END { exit !found }' "$WORK/installed.out" >&2; then
    echo "FAIL: installed-bundle preflight output exceeded 80 columns" >&2
    exit 1
fi
if grep -q '^profile init' "$WORK/goat-calls"; then
    echo "FAIL: unchanged installed bundle called profile init" >&2
    exit 1
fi

write_installed_profile other default
: > "$WORK/goat-calls"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    STUB_DEFAULT_CERT_CN=wrong-slot STUB_INIT_FAILS=1 GOAT_CONTEXT=other \
    IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/other-context.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] \
    || { echo "FAIL: GOAT_CONTEXT=other preflight exited $status" >&2; exit 1; }
grep -q 'certificate identity matches slot ID' "$WORK/other-context.out" \
    || { echo "FAIL: GOAT_CONTEXT did not select its certificate" >&2; exit 1; }

: > "$WORK/goat-calls"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=wrong-slot \
    STUB_INIT_FAILS=1 IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" > "$WORK/installed-mismatch.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] \
    || { echo "FAIL: changed slot ID against installed certificate exited $status" >&2; exit 1; }
grep -q 'does not match the configured slot ID' "$WORK/installed-mismatch.out" \
    || { echo "FAIL: changed slot ID did not report the installed certificate mismatch" >&2; exit 1; }
if grep -q '^profile init' "$WORK/goat-calls"; then
    echo "FAIL: changed slot ID caused unchanged bundle verification" >&2
    exit 1
fi

set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" GOAT_CONTEXT=.. \
    IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/invalid-context.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] \
    || { echo "FAIL: invalid GOAT_CONTEXT exited $status" >&2; exit 1; }
grep -q 'invalid active goat context: ..' "$WORK/invalid-context.out" \
    || { echo "FAIL: invalid GOAT_CONTEXT was not explained" >&2; exit 1; }

find "$WORK/state/goat-cli/contexts" \( -type f -o -type l \) -delete
find "$WORK/state/goat-cli/contexts" -depth -type d -empty -delete
mkdir -p "$WORK/state/goat-cli/contexts/default.bak"
printf 'router_endpoint = "tls/backup.invalid:7447"\n' \
    > "$WORK/state/goat-cli/contexts/default.bak/profile.toml"
write_installed_profile

: > "$WORK/goat-calls"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_NO_CN=1 \
    VERIFY_CERT_SLOT_BINDING=1 IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/installed-no-cn.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] \
    || { echo "FAIL: installed certificate without a CN exited $status" >&2; exit 1; }
grep -q 'could not read a common name from the certificate' \
    "$WORK/installed-no-cn.out" \
    || { echo "FAIL: missing installed certificate CN was not reported" >&2; exit 1; }
grep -q "$WORK/state/goat-cli/contexts/default/mtls.cert.pem" \
    "$WORK/installed-no-cn.out" \
    || { echo "FAIL: missing CN output did not name the live certificate" >&2; exit 1; }
if grep -q 'staged' "$WORK/installed-no-cn.out"; then
    echo "FAIL: installed certificate output called the live certificate staged" >&2
    exit 1
fi

: > "$WORK/goat-calls"
: > "$STUB_CHOWN_CALLS"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    STUB_INIT_FAILS=1 STUB_SYSTEMCTL_CALLS="$WORK/systemctl-calls" \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" > "$WORK/installed-full.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] \
    || { echo "FAIL: full first-boot run exited $status" >&2; exit 1; }
grep -q 'profile present and bundle unchanged' "$WORK/installed-full.out" \
    || { echo "FAIL: full re-run did not reuse the unchanged installed profile" >&2; exit 1; }
grep -q '==> \[2/6\]' "$WORK/installed-full.out" \
    || { echo "FAIL: full re-run did not continue past bundle verification" >&2; exit 1; }
if grep -q 'activation deadline' "$WORK/installed-full.out"; then
    echo "FAIL: full re-run hit the bundle activation deadline" >&2
    exit 1
fi
grep -q 'router endpoint from bundle: tls/example.invalid:7447' \
    "$WORK/installed-full.out" \
    || { echo "FAIL: full run did not use the active context endpoint" >&2; exit 1; }
if grep -q 'backup.invalid' "$WORK/installed-full.out"; then
    echo "FAIL: full run selected the backup context endpoint" >&2
    exit 1
fi
for unit in goat-clientd.service goat-doctor.service goat-doctor.timer; do
    if [ "$unit" = goat-clientd.service ]; then
        continue
    fi
    [ -f "$SYSTEMD_UNIT_DIR/$unit" ] \
        || { echo "FAIL: full run did not write $unit under the test directory" >&2; exit 1; }
done
grep -q '^daemon-reload$' "$WORK/systemctl-calls" \
    || { echo "FAIL: full run did not record systemctl daemon-reload" >&2; exit 1; }
grep -q '^enable --now goat-doctor.timer$' "$WORK/systemctl-calls" \
    || { echo "FAIL: full run did not record timer enablement" >&2; exit 1; }
expected_chown="root:65532 $WORK/state/zenoh/tls/pod-cert.pem $WORK/state/zenoh/tls/pod-key.pem $WORK/state/zenoh/tls/ca-roots.pem"
[ "$(cat "$STUB_CHOWN_CALLS")" = "$expected_chown" ] \
    || { echo "FAIL: full run did not limit ownership changes to its TLS files" >&2; exit 1; }
if find /etc/systemd/system -maxdepth 1 \
        \( -name goat-doctor.service -o -name goat-doctor.timer \
        -o -name goat-clientd.service \) -newer "$WORK/bundle.cbor" -print \
        2>/dev/null | grep -q .; then
    echo "FAIL: full run wrote a system unit outside the test directory" >&2
    exit 1
fi

# With goat-pod-api installed and a portal signer certificate in the profile, first-boot writes the
# goat-pod-api configuration, renders carried sources through it, and installs its service.
POD_API_STUB_DIR="$WORK/pod-api-bin"
mkdir -p "$POD_API_STUB_DIR"
cat > "$POD_API_STUB_DIR/goat-pod-api" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_POD_API_CALLS:?}"
if [ "${1:-}" = render ]; then
  while [ $# -gt 0 ]; do
    if [ "$1" = --out ]; then printf 'rendered-by-goat-pod-api\n' > "$2"; fi
    shift
  done
fi
EOF
chmod +x "$POD_API_STUB_DIR/goat-pod-api"
printf 'signer\n' > "$WORK/portal-signer.pem"
write_profile 1
printf 'POD_API_SIGNER_CERT=%s\nPOD_API_LISTEN="127.0.0.1:8447 100.127.0.10:8447"\n' \
    "$WORK/portal-signer.pem" >> "$REPO/profiles/test/profile.env"
: > "$WORK/systemctl-calls"
: > "$STUB_CHOWN_CALLS"
set +e
PATH="$POD_API_STUB_DIR:$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    STUB_POD_API_CALLS="$WORK/pod-api-calls" STUB_SYSTEMCTL_CALLS="$WORK/systemctl-calls" \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" > "$WORK/pod-api.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] \
    || { cat "$WORK/pod-api.out" >&2; echo "FAIL: first-boot with goat-pod-api exited $status" >&2; exit 1; }
POD_API_CONFIG="$WORK/state/pod-api/config.json"
python3 -I - "$POD_API_CONFIG" "$WORK" <<'PY' || { echo "FAIL: goat-pod-api config is wrong" >&2; exit 1; }
import json, sys
c = json.load(open(sys.argv[1]))
work = sys.argv[2]
assert c["pod_slot"] == "slot-a", c["pod_slot"]
assert c["listen"] == ["127.0.0.1:8447", "100.127.0.10:8447"], c["listen"]
assert c["portal_signer_cert"] == work + "/portal-signer.pem"
assert c["router"]["base_config"] == work + "/state/zenoh/config.base.json5"
assert c["router"]["config"] == work + "/state/zenoh/config.json5"
assert c["router"]["container"] == "goat-moon-zenoh-router"
assert c["fabric_router_cn"] == "fabric-router", c["fabric_router_cn"]
PY
grep -q "^render --config $POD_API_CONFIG --out " "$WORK/pod-api-calls" \
    || { echo "FAIL: first-boot did not render through goat-pod-api" >&2; exit 1; }
grep -q 'rendered-by-goat-pod-api' "$WORK/state/zenoh/config.json5" \
    || { echo "FAIL: the goat-pod-api rendering is not the live router config" >&2; exit 1; }
grep -q '@carriage-rules' "$WORK/state/zenoh/config.base.json5" \
    || { echo "FAIL: the base router config was not kept for goat-pod-api" >&2; exit 1; }
[ -f "$SYSTEMD_UNIT_DIR/goat-pod-api.service" ] \
    || { echo "FAIL: goat-pod-api.service not written" >&2; exit 1; }
for call in 'enable goat-pod-api.service' 'restart goat-pod-api.service'; do
    grep -qx "$call" "$WORK/systemctl-calls" \
        || { echo "FAIL: systemctl $call not run" >&2; exit 1; }
done
# A profile value that would change the file's structure is refused.
printf '%s\n' "POD_API_PORTAL_URL='https://x\"y'" >> "$REPO/profiles/test/profile.env"
set +e
PATH="$POD_API_STUB_DIR:$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    STUB_POD_API_CALLS="$WORK/pod-api-calls" STUB_SYSTEMCTL_CALLS="$WORK/systemctl-calls" \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" > "$WORK/pod-api-bad.out" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ] || ! grep -q 'contains a quote' "$WORK/pod-api-bad.out"; then
    echo "FAIL: a quote in a profile value reached the goat-pod-api config" >&2
    exit 1
fi
write_profile 1

unlink "$WORK/state/goat-cli/contexts/default/profile.toml"
[ -f "$WORK/state/goat-cli/contexts/default.bak/profile.toml" ] \
    || { echo "FAIL: backup-context fixture is missing" >&2; exit 1; }
: > "$WORK/goat-calls"
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=slot-a \
    STUB_INIT_FAILS=1 STUB_SYSTEMCTL_CALLS="$WORK/systemctl-calls" \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/backup-only.out" 2>&1
status=$?
set -e
if grep -q 'backup.invalid' "$WORK/backup-only.out"; then
    echo "FAIL: full run read profile.toml from a backup context" >&2
    exit 1
fi
[ "$status" -eq 1 ] \
    || { echo "FAIL: run without an active profile.toml exited $status" >&2; exit 1; }
grep -q 'bundle carried no router_endpoint' "$WORK/backup-only.out" \
    || { echo "FAIL: missing active profile.toml was not explained" >&2; exit 1; }
printf 'router_endpoint = "tls/example.invalid:7447"\n' \
    > "$WORK/state/goat-cli/contexts/default/profile.toml"

printf 'old-hash\n' > "$WORK/state/goat-cli/.bundle.sha256"
before_cert=$(sha256sum "$WORK/state/goat-cli/contexts/default/mtls.cert.pem")
before_hash=$(sha256sum "$WORK/state/goat-cli/.bundle.sha256")
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=wrong-slot \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" > "$WORK/mismatch.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: binding mismatch exited $status" >&2; exit 1; }
[ "$before_cert" = "$(sha256sum "$WORK/state/goat-cli/contexts/default/mtls.cert.pem")" ] \
    || { echo "FAIL: binding mismatch changed the installed certificate" >&2; exit 1; }
[ "$before_hash" = "$(sha256sum "$WORK/state/goat-cli/.bundle.sha256")" ] \
    || { echo "FAIL: binding mismatch changed the installed bundle hash" >&2; exit 1; }
grep -q 'live profile and services were not changed' "$WORK/mismatch.out" \
    || { echo "FAIL: binding mismatch did not report unchanged live state" >&2; exit 1; }

write_profile 0
set +e
PATH="$BIN:$PATH" STUB_GOAT_CALLS="$WORK/goat-calls" STUB_CERT_CN=wrong-slot \
    IDENTITY_PREFLIGHT_ONLY=1 \
    bash "$REPO/host/first-boot.sh" test "$WORK/bundle.cbor" \
    > "$WORK/off.out" 2>&1
status=$?
set -e
[ "$status" -eq 0 ] \
    || { echo "FAIL: binding-off preflight exited $status" >&2; exit 1; }
grep -q 'identity binding was not checked (profile setting is off)' "$WORK/off.out" \
    || { echo "FAIL: binding-off preflight was not reported" >&2; exit 1; }
if grep -q 'identity matches slot ID' "$WORK/off.out"; then
    echo "FAIL: setting-off output implied the binding passed" >&2
    exit 1
fi

echo "PASS: first-boot identity staging and profile gate"
