#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2329
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT_SOURCE="${SETUP_SCRIPT_UNDER_TEST:-$ROOT/moon_pod_setup.sh}"
WORK="$(mktemp -d)"
cleanup_test() {
    find "$WORK" \( -type f -o -type l \) -delete 2>/dev/null || true
    find "$WORK" -depth -type d -empty -delete 2>/dev/null || true
}
trap cleanup_test EXIT

fail_test() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
    local message="$1"
    shift
    if "$@"; then fail_test "$message"; fi
}
assert_absent() {
    local regex="$1" file="$2" message="$3"
    if grep -Eq "$regex" "$file"; then fail_test "$message"; fi
}

SCRIPT_FIXTURE="$WORK/script-repo"
mkdir -p "$SCRIPT_FIXTURE/profiles/zagros-local" "$SCRIPT_FIXTURE/compose" \
    "$SCRIPT_FIXTURE/host"
cp "$SETUP_SCRIPT_SOURCE" "$SCRIPT_FIXTURE/moon_pod_setup.sh"
cp "$ROOT/host/goat-context.sh" "$SCRIPT_FIXTURE/host/"
SETUP_SCRIPT="$SCRIPT_FIXTURE/moon_pod_setup.sh"

BIN="$WORK/bin"; STUB="$WORK/stub"; mkdir -p "$BIN" "$STUB"
export STUB CALLS="$STUB/calls" NETBIRD_JSON="$STUB/netbird.json"
: > "$CALLS"

cat > "$BIN/netbird" <<'EOF'
#!/usr/bin/env bash
printf 'netbird-keyenv=%s\n' "${NETBIRD_SETUP_KEY-unset}" >> "$CALLS"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then cat "$NETBIRD_JSON"; exit; fi
if [ "${1:-}" = status ]; then
  if sed -n '1p' "$NETBIRD_JSON" | grep -q '^Daemon status:'; then
    cat "$NETBIRD_JSON"; exit
  fi
  printf 'Management: Connected\nFQDN: pod-1.example\nPeers count: 1/1 Connected\n'; exit
fi
if [ "${1:-} ${2:-}" = 'up --help' ]; then
  if [ ! -e "$STUB/no-key-file-support" ]; then
    printf '%s\n' 'Usage: netbird up --setup-key-file FILE' '  --hostname string'
  else
    printf '%s\n' 'Usage: netbird up --setup-key KEY' '  --hostname string'
  fi
  exit
fi
if [ "${1:-}" = up ]; then
  printf 'netbird %s\n' "$*" >> "$CALLS"
  [ ! -f "$STUB/up-fails" ] || exit 1
  cp "$STUB/ready.json" "$NETBIRD_JSON"
  exit
fi
EOF
cat > "$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker-keyenv=%s\n' "${NETBIRD_SETUP_KEY-unset}" >> "$CALLS"
printf 'docker %s\n' "$*" >> "$CALLS"
case "${1:-} ${2:-}" in
  'compose version') echo 'Docker Compose version test' ;;
  'ps --format') printf 'goat-moon-zenoh-router\tUp 1 minute\ngoat-moon-audit-sink\tUp 1 minute\n' ;;
esac
exit 0
EOF
cat > "$BIN/goat" <<'EOF'
#!/usr/bin/env bash
printf 'goat-keyenv=%s\n' "${NETBIRD_SETUP_KEY-unset}" >> "$CALLS"
printf 'goat %s\n' "$*" >> "$CALLS"
args=("$@")
if [ "${args[0]:-}" = --context ]; then
  printf 'goat-context %s\n' "${args[1]}" >> "$CALLS"
  args=("${args[@]:2}")
fi
if [ "${args[0]:-}" = pub ]; then
  printf 'pub-profile %s\n' "$GOAT_PROFILE_DIR" >> "$CALLS"
  [ ! -d "$GOAT_PROFILE_DIR/contexts/other" ] \
    || printf 'pub-context-copy other\n' >> "$CALLS"
  for ((i=0; i<${#args[@]}; i++)); do
    if [ "${args[$i]}" = --payload-file ]; then
      n=0; [ ! -f "$STUB/payload-count" ] || n=$(cat "$STUB/payload-count")
      n=$((n + 1)); printf '%s' "$n" > "$STUB/payload-count"
      cp "${args[$((i + 1))]}" "$STUB/payload-$n.json"
    fi
  done
  if [ -n "${DOCTOR_STATUS_FILE:-}" ] && [ -f "$DOCTOR_STATUS_FILE" ]; then
    modified=$(stat -c %Y "$DOCTOR_STATUS_FILE")
    touch -d "@$((modified + 1))" "$DOCTOR_STATUS_FILE"
  fi
fi
case "${1:-} ${2:-}" in
  '--version ') echo 'goat test' ;;
  'ca ls') echo '{"count":1}' ;;
  'doctor --all') echo 'doctor healthy' ;;
esac
exit 0
EOF
cat > "$BIN/findmnt" <<'EOF'
#!/usr/bin/env bash
echo '/dev/mapper/goat-moon'
EOF
cat > "$BIN/timedatectl" <<'EOF'
#!/usr/bin/env bash
echo yes
EOF
cat > "$BIN/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
n=0; [ ! -f "$STUB/curl-count" ] || n=$(cat "$STUB/curl-count")
n=$((n + 1)); echo "$n" > "$STUB/curl-count"
value=1; [ "$n" -gt 1 ] && value=2
printf 'goat_audit_samples_total %s\n' "$value"
EOF
cat > "$BIN/git" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/envsubst" <<'EOF'
#!/usr/bin/env bash
cat
EOF
cat > "$BIN/python3" <<'EOF'
#!/usr/bin/env bash
if [ -e "$STUB/unsupported-python" ] && [ "${1:-}" = -c ]; then exit 1; fi
exec /usr/bin/python3 "$@"
EOF
cat > "$BIN/openssl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && { echo 0; exit; }
exec /usr/bin/id "$@"
EOF
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"

cat > "$STUB/need-login.json" <<'EOF'
{"daemonStatus":"NeedsLogin","management":{"connected":false},"peers":{"connected":0},"fqdn":"","publicKey":""}
EOF
cat > "$STUB/need-login-legacy.txt" <<'EOF'
Daemon status: NeedsLogin

Run UP command to log in with SSO (interactive login):
netbird up
EOF
cat > "$STUB/unexpected-status.txt" <<'EOF'
something unexpected
EOF
cat > "$STUB/ready.json" <<'EOF'
{"daemonStatus":"Connected","management":{"connected":true},"peers":{"connected":1},"fqdn":"pod-1.example","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
EOF
cat > "$STUB/enrolled-no-peers.json" <<'EOF'
{"daemonStatus":"Connected","management":{"connected":true},"peers":{"connected":0},"fqdn":"pod-1.example","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
EOF
cat > "$STUB/enrolled-management-down.json" <<'EOF'
{"daemonStatus":"Connected","management":{"connected":false},"peers":{"connected":1},"fqdn":"pod-1.example","publicKey":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
EOF

printf 'q\n' | TERM=dumb COLUMNS=80 bash "$SETUP_SCRIPT" > "$WORK/terminal-first.out"
grep -q 'NOT RUN YET' "$WORK/terminal-first.out"

# shellcheck source=../moon_pod_setup.sh
set +e
# shellcheck disable=SC1090
source "$SETUP_SCRIPT"
set -e
trap cleanup_test EXIT
case "$REPO_DIR" in
    "$WORK"/*) ;;
    *) fail_test "sourced setup script escaped its temporary fixture" ;;
esac

cp "$STUB/need-login-legacy.txt" "$NETBIRD_JSON"
set +e
mesh_enrollment_state
legacy_state=$?
set -e
[ "$legacy_state" -eq 1 ] \
    || { echo "FAIL: legacy NeedsLogin status returned $legacy_state, expected 1" >&2; exit 1; }
cp "$STUB/unexpected-status.txt" "$NETBIRD_JSON"
set +e
mesh_enrollment_state
unexpected_state=$?
set -e
[ "$unexpected_state" -eq 2 ] \
    || { echo "FAIL: unexpected non-JSON status returned $unexpected_state, expected 2" >&2; exit 1; }

STATE_DIR="$WORK/state"; mkdir -p "$STATE_DIR"
KEY_FIXTURE="$WORK/key-repo"
mkdir -p "$KEY_FIXTURE/profiles/zagros-local" "$KEY_FIXTURE/.git"
REPO_DIR="$KEY_FIXTURE"; PROFILE_NAME=zagros-local; SOURCE_PROFILE=zagros
INPUT_STATE_FILE="$KEY_FIXTURE/profiles/zagros-local/setup-inputs.env"
POD_ID=pod-1; POD_ID_EXPLICIT=1
NETBIRD_MANAGEMENT_URL=https://management.example
NETBIRD_SETUP_KEY=secret-setup-value; NETBIRD_SETUP_KEY_FILE=""
cp "$STUB/need-login.json" "$NETBIRD_JSON"
out=$(netbird_up_if_needed 2>&1)
grep -q -- '--hostname pod-1' "$CALLS"
grep -q -- '--setup-key-file' "$CALLS"
if grep -q 'secret-setup-value' "$CALLS" "$WORK"/state/* 2>/dev/null; then
    fail_test "typed setup key leaked to a child or state file"
fi
[[ "$out" != *secret-setup-value* ]]

: > "$CALLS"; cp "$STUB/need-login.json" "$NETBIRD_JSON"
POD_ID='bad/label'; NETBIRD_SETUP_KEY=another-secret
expect_failure "invalid POD_ID allowed mesh enrollment" \
    netbird_up_if_needed > "$WORK/invalid.out" 2>&1
grep -q "POD_ID 'bad/label' is not valid" "$WORK/invalid.out"
assert_absent '^netbird up' "$CALLS" \
    "invalid POD_ID spent the setup key"

: > "$CALLS"; cp "$STUB/need-login.json" "$NETBIRD_JSON"
POD_ID=POD_1; NETBIRD_SETUP_KEY=another-secret
expect_failure "non-canonical POD_ID allowed mesh enrollment" \
    netbird_up_if_needed > "$WORK/uppercase-pod-id.out" 2>&1
grep -q "POD_ID 'POD_1' is not valid" "$WORK/uppercase-pod-id.out"
rule_continuation="$(awk '/Required form:/ { getline; print; exit }' \
    "$WORK/uppercase-pod-id.out")"
[[ "$rule_continuation" = '  '* ]] || {
    echo "FAIL: the wrapped POD_ID rule continuation was not indented" >&2
    exit 1
}
assert_absent '^netbird up' "$CALLS" \
    "non-canonical POD_ID spent the setup key"

: > "$CALLS"; cp "$STUB/enrolled-no-peers.json" "$NETBIRD_JSON"
POD_ID=pod-1; NETBIRD_SETUP_KEY=must-not-be-used
expect_failure "enrolled host without peers was reported ready" \
    netbird_up_if_needed > "$WORK/enrolled.out" 2>&1
grep -q 'setup key is already used' "$WORK/enrolled.out"
grep -q 'goat side owns peer group assignment' "$WORK/enrolled.out" \
    || fail_test "no-peer message did not name the goat-side owner"
assert_absent '^netbird up' "$CALLS" \
    "enrolled host tried to spend another setup key"

: > "$CALLS"; cp "$STUB/enrolled-management-down.json" "$NETBIRD_JSON"
NETBIRD_SETUP_KEY=must-not-be-used
expect_failure "management-disconnected host was reported ready" \
    netbird_up_if_needed > "$WORK/management-down.out" 2>&1
grep -q "partner checks this host's network path" "$WORK/management-down.out" \
    || fail_test "management-disconnected message did not name the partner action"
if awk 'length > 80 {found=1} END {exit !found}' "$WORK/management-down.out"; then
    fail_test "management-disconnected output exceeded 80 columns"
fi
assert_absent '^netbird up' "$CALLS" \
    "enrolled management-disconnected host tried to spend another key"

# A disposable repository surface lets the real run_part2 function exercise every gate without
# modifying this checkout or invoking a real bundle, mesh, or container runtime.
FIXTURE="$WORK/repo"; mkdir -p "$FIXTURE/host" "$FIXTURE/profiles/zagros" \
    "$FIXTURE/profiles/zagros-local" "$FIXTURE/compose" "$FIXTURE/.git"
cat > "$FIXTURE/profiles/zagros/profile.env" <<EOF
POD_STATE_DIR=$STATE_DIR
PARTNER_NAMESPACE=CHANGE-ME-slot
VERIFY_CERT_SLOT_BINDING=1
EOF
cat > "$FIXTURE/profiles/zagros-local/profile.env" <<EOF
POD_STATE_DIR=$STATE_DIR
PARTNER_NAMESPACE=slot-a
POD_ID=pod-1
EOF
cat > "$FIXTURE/host/first-boot.sh" <<'EOF'
#!/usr/bin/env bash
printf 'firstboot-keyenv=%s\n' "${NETBIRD_SETUP_KEY-unset}" >> "$CALLS"
printf 'firstboot preflight=%s\n' "${IDENTITY_PREFLIGHT_ONLY:-0}" >> "$CALLS"
[ ! -f "$STUB/wrong-bundle" ]
EOF
cp "$ROOT/host/goat-context.sh" "$FIXTURE/host/"
chmod +x "$FIXTURE/host/first-boot.sh"
BUNDLE="$WORK/bundle.cbor"; : > "$BUNDLE"

REPO_DIR="$FIXTURE"; PROFILE_ENV="$FIXTURE/profiles/zagros-local/profile.env"
STATE_DIR="$WORK/state"; GOAT_PROFILE_DIR="$STATE_DIR/goat-cli"
: > "$CALLS"

ambiguous_key_file="$WORK/ambiguous-key"
printf 'file-key\n' > "$ambiguous_key_file"
chmod 0644 "$ambiguous_key_file"
NETBIRD_SETUP_KEY=typed-key
NETBIRD_SETUP_KEY_FILE="$ambiguous_key_file"
: > "$CALLS"
expect_failure "ambiguous setup-key sources passed pre-flight" \
    part2_preflight > "$WORK/ambiguous-key.out" 2>&1
grep -q 'typed setup key and NETBIRD_SETUP_KEY_FILE are both set' \
    "$WORK/ambiguous-key.out" \
    || fail_test "ambiguous setup-key refusal was not explained"
assert_absent '^netbird up' "$CALLS" \
    "ambiguous setup-key sources spent a key"
NETBIRD_SETUP_KEY=unused-secret
NETBIRD_SETUP_KEY_FILE=""

: > "$STUB/no-key-file-support"
GOAT_ARCH=arm64
expect_failure "Part 1 readiness ignored missing setup-key-file support" \
    part1_ready_probe
expect_failure "Part 1 checklist passed without setup-key-file support" \
    part1_checklist > "$WORK/part1-checklist.out"
grep -q 'NetBird --setup-key-file support.*FAIL' "$WORK/part1-checklist.out" \
    || fail_test "Part 1 checklist did not show the NetBird support failure"
FAILED=0
expect_failure "Part 1 reported complete after a failed checklist row" \
    finish_part1 > "$WORK/part1-finish-fail.out"
[ "$PART1_FAILED" -eq 1 ] \
    || fail_test "Part 1 did not record the failed checklist row"
grep -q "PART 1 finished with failures" "$WORK/part1-finish-fail.out" \
    || fail_test "Part 1 did not report the failed checklist row"
assert_absent "PART 1 complete" "$WORK/part1-finish-fail.out" \
    "Part 1 claimed completion after a failed checklist row"
(
    part1_checklist() { return 0; }
    FAILED=0
    finish_part1
) > "$WORK/part1-finish-pass.out" \
    || fail_test "Part 1 failed after a passing checklist"
grep -q "PART 1 complete" "$WORK/part1-finish-pass.out" \
    || fail_test "Part 1 did not report completion after a passing checklist"
FAILED=0
unlink "$STUB/no-key-file-support"

: > "$STUB/unsupported-python"
expect_failure "Part 1 readiness accepted an unsupported Python" \
    part1_ready_probe
expect_failure "Part 1 checklist accepted an unsupported Python" \
    part1_checklist > "$WORK/part1-python.out"
grep -q 'Python 3.9+.*FAIL' "$WORK/part1-python.out" \
    || fail_test "Part 1 checklist did not show the Python version failure"
unlink "$STUB/unsupported-python"

command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = envsubst ]; then return 1; fi
    builtin command "$@"
}
expect_failure "Part 1 readiness ignored missing envsubst" part1_ready_probe
expect_failure "Part 1 checklist passed without envsubst" \
    part1_checklist > "$WORK/part1-envsubst.out"
unset -f command
grep -q 'envsubst.*FAIL' "$WORK/part1-envsubst.out" \
    || fail_test "Part 1 checklist did not show the envsubst failure"

report_netbird_deferred > "$WORK/netbird-installed.out"
grep -q 'NetBird is installed' "$WORK/netbird-installed.out" \
    || fail_test "installed NetBird was not reported"
command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = netbird ]; then return 1; fi
    builtin command "$@"
}
report_netbird_deferred > "$WORK/netbird-missing.out"
unset -f command
grep -q 'Part 2 cannot join the mesh until it installs' "$WORK/netbird-missing.out" \
    || fail_test "missing NetBird did not explain the Part 2 block"

part2_case() (
    set +e
    local case_fixture
    case_fixture="$(mktemp -d "$WORK/part2-case.XXXXXX")"
    cp -R "$FIXTURE/." "$case_fixture/"
    REPO_DIR="$case_fixture"; PROFILE_NAME=zagros-local; SOURCE_PROFILE=zagros
    PROFILE_DIR="$case_fixture/profiles/zagros-local"; PROFILE_ENV="$PROFILE_DIR/profile.env"
    INPUT_STATE_FILE="$PROFILE_DIR/setup-inputs.env"
    STATE_DIR="$WORK/state"; GOAT_PROFILE_DIR="$STATE_DIR/goat-cli"
    BUNDLE_PATH="$BUNDLE"; BUNDLE_TARBALL="$WORK/bundle.tar.gz"
    PARTNER_NAMESPACE=slot-a; POD_ID=pod-1; POD_ID_EXPLICIT=1
    GOATNET=example.invalid; NETBIRD_MANAGEMENT_URL=https://management.example
    [ ! -f "$STUB/missing-goatnet" ] || GOATNET=""
    CA_ROOT_PEM=""; EXPECTED_CA_FINGERPRINT=""; NETBIRD_SETUP_KEY=unused-secret; NETBIRD_SETUP_KEY_FILE=""
    trust_ca_root() { [ ! -f "$STUB/untrusted" ]; }
    run_part2
)

part2_refusal_case() {
    local name="$1" marker="$2" expected="$3"
    : > "$CALLS"
    cp "$STUB/need-login.json" "$NETBIRD_JSON"
    : > "$STUB/$marker"
    expect_failure "$name unexpectedly passed Part 2" \
        part2_case > "$WORK/$name.out" 2>&1
    if [ -n "$expected" ]; then
        grep -q "$expected" "$WORK/$name.out" \
            || fail_test "$name did not report the expected refusal"
    fi
    assert_absent '^netbird up' "$CALLS" \
        "$name spent the setup key after a failed gate"
    unlink "$STUB/$marker"
}

reset_input_env_flags() {
    POD_ID_EXPLICIT=0
    ENV_PARTNER_NAMESPACE_SET=0; ENV_POD_ID_SET=0
    ENV_GOATNET_SET=0; ENV_MANAGEMENT_SET=0
    ENV_BUNDLE_TARBALL_SET=0; ENV_BUNDLE_PATH_SET=0
    ENV_CA_ROOT_SET=0; ENV_CA_FP_SET=0
}

# An environment setup key is refused, and a later typed value is not exported to children.
: > "$CALLS"
NETBIRD_SETUP_KEY=environment-secret bash -c '
    source "$1"
    show_header
    part2_preflight || true
    NETBIRD_SETUP_KEY=typed-secret
    netbird status >/dev/null
    docker compose version >/dev/null
    goat doctor >/dev/null
    bash "$2" >/dev/null
' env-key-test "$SETUP_SCRIPT" "$FIXTURE/host/first-boot.sh" > "$WORK/env-key.out"
[ "$(grep -c 'NETBIRD_SETUP_KEY from the environment was ignored' "$WORK/env-key.out")" -eq 2 ]
for child in netbird docker goat firstboot; do
    grep -q "^${child}-keyenv=unset$" "$CALLS"
done
if grep -qE 'environment-secret|typed-secret' "$CALLS" "$WORK/env-key.out"; then
    fail_test "setup key leaked to a child command or output"
fi

part2_refusal_case missing-goatnet missing-goatnet \
    'GOATNET is missing or invalid'
part2_refusal_case untrusted untrusted ''
grep -q '^VERIFY_CERT_SLOT_BINDING=1$' \
    "$WORK"/part2-case.*/profiles/zagros-local/profile.env \
    || fail_test "Part 2 did not copy the slot-binding requirement"

part2_refusal_case wrong-bundle wrong-bundle ''

: > "$CALLS"; cp "$STUB/need-login-legacy.txt" "$NETBIRD_JSON"
part2_case > "$WORK/legacy-part2.out" 2>&1 \
    || { echo "FAIL: legacy NeedsLogin host did not pass Part 2" >&2; exit 1; }
grep -q '^netbird up .*--setup-key-file' "$CALLS" \
    || { echo "FAIL: legacy NeedsLogin host did not join with --setup-key-file" >&2; exit 1; }
if grep -q 'enrollment state is unreadable' "$WORK/legacy-part2.out"; then
    echo "FAIL: legacy NeedsLogin host was reported as unreadable" >&2
    exit 1
fi

: > "$CALLS"; cp "$STUB/enrolled-no-peers.json" "$NETBIRD_JSON"
expect_failure "enrolled host without peers unexpectedly passed Part 2" \
    part2_case > "$WORK/disconnected.out" 2>&1
grep -q 'firstboot preflight=1' "$CALLS"
assert_absent 'firstboot preflight=0' "$CALLS" \
    "disconnected Part 2 ran the live first-boot path"
assert_absent '^netbird up' "$CALLS" \
    "enrolled disconnected host tried to spend another setup key"

# Configure inputs works both before NetBird is installed and with the text
# NeedsLogin response from NetBird before 0.67. It saves only non-secrets, and
# loading again recovers the saved label and slot instead of placeholders.
REPO_DIR="$FIXTURE"; PROFILE_NAME=zagros-local; SOURCE_PROFILE=zagros
INPUT_STATE_FILE="$FIXTURE/profiles/zagros-local/setup-inputs.env"
REAL_HOME="$WORK/home"; mkdir -p "$REAL_HOME"; POD_ID=moon-pod; POD_ID_EXPLICIT=0
PARTNER_NAMESPACE=CHANGE-ME-zagros-uuid-slot; GOATNET=your.goatnet.domain
NETBIRD_MANAGEMENT_URL=""; BUNDLE_TARBALL="$WORK/pod.tar.gz"; BUNDLE_PATH="$BUNDLE"
CA_ROOT_PEM=""; EXPECTED_CA_FINGERPRINT=""; NETBIRD_SETUP_KEY=""
cat > "$WORK/configure-answers" <<'EOF'
pod-1
slot-a
example.invalid
https://management.example



0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
typed-setup-key

EOF

command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = netbird ]; then return 1; fi
    builtin command "$@"
}
configure_inputs < "$WORK/configure-answers" > "$WORK/configure-not-installed.out"
[ "$NETBIRD_SETUP_KEY" = typed-setup-key ] || {
    echo "FAIL: configure inputs did not collect the key before NetBird installation" >&2
    exit 1
}
if grep -Eq 'enrollment state is unknown|already enrolled' \
        "$WORK/configure-not-installed.out"; then
    echo "FAIL: pre-install configure inputs reported the wrong enrollment state" >&2
    exit 1
fi
unset -f command
if grep -q 'typed-setup-key' "$INPUT_STATE_FILE" \
        "$WORK/configure-not-installed.out"; then
    echo "FAIL: pre-install configure inputs exposed the setup key" >&2
    exit 1
fi

PARTNER_NAMESPACE=CHANGE-ME-zagros-uuid-slot; POD_ID=moon-pod
reset_input_env_flags
load_saved_inputs
if [ "$PARTNER_NAMESPACE" != slot-a ] || [ "$POD_ID" != pod-1 ] \
        || [ "$POD_ID_EXPLICIT" -ne 1 ]; then
    echo "FAIL: pre-install configure inputs did not reload saved values" >&2
    exit 1
fi

POD_ID=moon-pod; POD_ID_EXPLICIT=0
PARTNER_NAMESPACE=CHANGE-ME-zagros-uuid-slot; GOATNET=your.goatnet.domain
NETBIRD_MANAGEMENT_URL=""; BUNDLE_TARBALL="$WORK/pod.tar.gz"
BUNDLE_PATH="$BUNDLE"; CA_ROOT_PEM=""; EXPECTED_CA_FINGERPRINT=""
NETBIRD_SETUP_KEY=""
cp "$STUB/need-login-legacy.txt" "$NETBIRD_JSON"
configure_inputs < "$WORK/configure-answers" > "$WORK/configure-legacy.out"
[ "$NETBIRD_SETUP_KEY" = typed-setup-key ] || {
    echo "FAIL: configure inputs did not collect the key from legacy NetBird" >&2
    exit 1
}
if grep -Eq 'enrollment state is unknown|already enrolled' \
        "$WORK/configure-legacy.out"; then
    echo "FAIL: configure inputs treated legacy NeedsLogin as enrolled or unknown" >&2
    exit 1
fi
if grep -q 'typed-setup-key' "$INPUT_STATE_FILE" "$WORK/configure-legacy.out"; then
    echo "FAIL: legacy configure inputs exposed the setup key" >&2
    exit 1
fi

PARTNER_NAMESPACE=CHANGE-ME-zagros-uuid-slot; POD_ID=moon-pod
reset_input_env_flags
load_saved_inputs
if [ "$PARTNER_NAMESPACE" != slot-a ] || [ "$POD_ID" != pod-1 ] \
        || [ "$POD_ID_EXPLICIT" -ne 1 ]; then
    echo "FAIL: legacy configure inputs did not reload saved values" >&2
    exit 1
fi
NETBIRD_SETUP_KEY=""
{ show_header; show_status; } > "$WORK/terminal-rerun.out"
grep -q 'slot-a' "$WORK/terminal-rerun.out"
grep -q 'pod-1' "$WORK/terminal-rerun.out"

DEFAULT_PATH_FIXTURE="$WORK/default-path-repo"
mkdir -p "$DEFAULT_PATH_FIXTURE/profiles/zagros-local"
REPO_DIR="$DEFAULT_PATH_FIXTURE"; PROFILE_NAME=zagros-local; SOURCE_PROFILE=zagros
INPUT_STATE_FILE="$DEFAULT_PATH_FIXTURE/profiles/zagros-local/setup-inputs.env"
REAL_HOME="$WORK/default-home"; PARTNER_NAMESPACE=slot-a; POD_ID=pod-a
GOATNET=example.invalid; NETBIRD_MANAGEMENT_URL=https://management.example
BUNDLE_TARBALL="$REAL_HOME/pod-a-bundle.tar.gz"
BUNDLE_PATH="$REAL_HOME/goat-bundle/slot-a-goat-cli.cbor"
CA_ROOT_PEM=""; EXPECTED_CA_FINGERPRINT=""
persist_inputs > "$WORK/default-path-save.out"
grep -q '^BUNDLE_TARBALL=$' "$INPUT_STATE_FILE" \
    || fail_test "derived bundle tarball was saved as an explicit path"
grep -q '^BUNDLE_PATH=$' "$INPUT_STATE_FILE" \
    || fail_test "derived bundle path was saved as an explicit path"
PARTNER_NAMESPACE=slot-b; POD_ID=pod-b; BUNDLE_TARBALL=""; BUNDLE_PATH=""
ENV_PARTNER_NAMESPACE_SET=1; ENV_POD_ID_SET=1
ENV_BUNDLE_TARBALL_SET=0; ENV_BUNDLE_PATH_SET=0
ENV_GOATNET_SET=1; ENV_MANAGEMENT_SET=1; ENV_CA_ROOT_SET=1; ENV_CA_FP_SET=1
load_saved_inputs
[ "$BUNDLE_TARBALL" = "$REAL_HOME/pod-b-bundle.tar.gz" ] \
    || fail_test "derived bundle tarball did not follow the POD ID"
[ "$BUNDLE_PATH" = "$REAL_HOME/goat-bundle/slot-b-goat-cli.cbor" ] \
    || fail_test "derived bundle path did not follow the slot"

# A saved POD_ID in the former accepted form is named instead of being
# silently replaced and then reported as missing.
REJECTED_FIXTURE="$WORK/rejected-repo"
mkdir -p "$REJECTED_FIXTURE/profiles/zagros-local" "$REJECTED_FIXTURE/compose"
printf 'POD_ID=POD_1\n' > "$REJECTED_FIXTURE/profiles/zagros-local/profile.env"
REPO_DIR="$REJECTED_FIXTURE"; PROFILE_NAME=zagros-local
INPUT_STATE_FILE="$REJECTED_FIXTURE/profiles/zagros-local/setup-inputs.env"
PARTNER_NAMESPACE=""; POD_ID=""; POD_ID_EXPLICIT=0; GOATNET=""
NETBIRD_MANAGEMENT_URL=""; BUNDLE_TARBALL=""; BUNDLE_PATH=""
CA_ROOT_PEM=""; EXPECTED_CA_FINGERPRINT=""; SAVED_POD_ID_REJECTED=""
reset_input_env_flags
load_saved_inputs
if [ "$SAVED_POD_ID_REJECTED" != POD_1 ] || [ "$POD_ID_EXPLICIT" -ne 0 ] \
        || [ "$POD_ID" != moon-pod ]; then
    echo "FAIL: load_saved_inputs did not retain the rejected saved POD_ID" >&2
    exit 1
fi

: > "$CALLS"
REPO_DIR="$FIXTURE"; STATE_DIR="$WORK/state"; GOAT_PROFILE_DIR="$STATE_DIR/goat-cli"
PARTNER_NAMESPACE=slot-a; GOATNET=example.invalid
NETBIRD_MANAGEMENT_URL=https://management.example
BUNDLE_TARBALL="$WORK/bundle.tar.gz"; BUNDLE_PATH="$BUNDLE"
CA_ROOT_PEM=""; EXPECTED_CA_FINGERPRINT=""; NETBIRD_SETUP_KEY=unused-secret
NETBIRD_SETUP_KEY_FILE=""; POD_ID=moon-pod; POD_ID_EXPLICIT=0
SAVED_POD_ID_REJECTED=POD_1
cp "$STUB/need-login.json" "$NETBIRD_JSON"
expect_failure "rejected saved POD_ID passed pre-flight" \
    part2_preflight > "$WORK/rejected-saved-pod-id.out" 2>&1
grep -q "saved POD_ID 'POD_1' is not in the required form" \
    "$WORK/rejected-saved-pod-id.out" || {
    echo "FAIL: preflight did not name the rejected saved POD_ID" >&2
    exit 1
}
grep -q 'Required form:' "$WORK/rejected-saved-pod-id.out" || {
    echo "FAIL: rejected saved POD_ID did not print the required form" >&2
    exit 1
}
if grep -q 'missing or invalid' "$WORK/rejected-saved-pod-id.out"; then
    echo "FAIL: rejected saved POD_ID was reported as missing" >&2
    exit 1
fi
if grep -q '^netbird up' "$CALLS"; then
    echo "FAIL: rejected saved POD_ID allowed a mesh join" >&2
    exit 1
fi

POD_ID=Moon_Pod; POD_ID_EXPLICIT=1; SAVED_POD_ID_REJECTED=""
expect_failure "invalid explicit POD_ID passed pre-flight" \
    part2_preflight > "$WORK/explicit-invalid-pod-id.out" 2>&1
grep -q "POD_ID 'Moon_Pod' is not valid" \
    "$WORK/explicit-invalid-pod-id.out" || {
    echo "FAIL: preflight did not name the explicit invalid POD_ID" >&2
    exit 1
}

# Drive the real Part 3 path with stubbed services and a staged profile. It must publish without
# stopping or starting the router and must accept only current catalog evidence.
mkdir -p "$STATE_DIR/goat-cli/contexts/default" "$STATE_DIR/doctor" "$FIXTURE/host" "$FIXTURE/compose"
printf 'current_context = "default"\n' > "$STATE_DIR/goat-cli/config.toml"
mkdir -p "$STATE_DIR/goat-cli/contexts/other"
printf 'router_endpoint = "tls/fabric.invalid:7447"\n' > "$STATE_DIR/goat-cli/contexts/other/profile.toml"
for file in mtls.cert.pem mtls.key.pem ca-roots.pem; do printf x > "$STATE_DIR/goat-cli/contexts/other/$file"; done
cp "$STATE_DIR/goat-cli/contexts/other/"* \
    "$STATE_DIR/goat-cli/contexts/default/"
printf 'PARTNER_NAMESPACE=slot-a\nZENOH_LOCAL_ENDPOINT=tls/127.0.0.1:7447\n' \
    > "$FIXTURE/compose/.env"
printf '{}\n' > "$STATE_DIR/doctor/status.json"
export DOCTOR_STATUS_FILE="$STATE_DIR/doctor/status.json"
cat > "$FIXTURE/host/catalog-publish-count.py" <<'EOF'
#!/usr/bin/env bash
printf 'catalog %s\n' "$*" >> "$CALLS"
n=0; [ ! -f "$STUB/catalog-count" ] || n=$(cat "$STUB/catalog-count")
n=$((n + 1)); echo "$n" > "$STUB/catalog-count"
now=$(date +%s)
[ "$n" -eq 1 ] && printf '5\t%s\n' "$((now - 10))" || printf '6\t%s\n' "$now"
EOF
chmod +x "$FIXTURE/host/catalog-publish-count.py"
: > "$CALLS"; unlink "$STUB/catalog-count" 2>/dev/null || true; unlink "$STUB/curl-count" 2>/dev/null || true
cp "$STUB/ready.json" "$NETBIRD_JSON"
REPO_DIR="$FIXTURE"; GOAT_PROFILE_DIR="$STATE_DIR/goat-cli"; PARTNER_NAMESPACE=slot-a; POD_ID=pod-1
export GOAT_CONTEXT=other
wait_for() { shift 3; "$@"; }
set +e
run_part3 > "$WORK/part3.out"
part3_status=$?
set -e
[ "$part3_status" -eq 0 ] \
    || fail_test "Part 3 did not accept a timer tick during delivery"
grep -q 'Delivery:.*Delivered' "$WORK/part3.out"
grep -q 'VERIFIED' "$WORK/part3.out"
assert_absent '^docker (stop|start|restart) ' "$CALLS" \
    "Part 3 stopped, started, or restarted the router"
grep -Eq '^goat (--context other )?pub slot-a/test/ping --payload-file' \
    "$CALLS" || fail_test "Part 3 did not use the fixed acceptance key"
grep -Eq 'goat --context other pub slot-a/test/ping --payload-file' \
    "$CALLS" || fail_test "Part 3 published without an explicit active context"
grep -q '^goat-context other$' "$CALLS" \
    || fail_test "Part 3 did not pass the active context to goat pub"
grep -q '^pub-context-copy other$' "$CALLS" \
    || fail_test "Part 3 did not copy the active context into its temporary profile"
grep -q '^catalog .*--context other' "$CALLS" \
    || fail_test "Part 3 did not pass the active context to the catalog helper"
grep -q "^pub-profile $STATE_DIR/.acceptance-profile\." "$CALLS"
grep -q '^  nonce=[0-9a-f]\{8\}$' "$WORK/part3.out" \
    || fail_test "Part 3 did not print the payload nonce"
python3 - "$STUB/payload-1.json" <<'PY'
import json
import re
import sys

document = json.load(open(sys.argv[1], encoding="utf-8"))
if not re.fullmatch(r"[0-9a-f]{8}", document.get("nonce", "")):
    raise SystemExit("FAIL: acceptance payload has no eight-hex nonce")
PY
publish_through_local_router >/dev/null
published_keys=$(awk '/^goat --context other pub / {print $5}' "$CALLS" | tail -2)
[ "$published_keys" = $'slot-a/test/ping\nslot-a/test/ping' ] \
    || fail_test "two acceptance runs did not reuse the fixed test key"
grep -q 'publish_count=.*last_publish_at=' "$WORK/part3.out" \
    || fail_test "Part 3 did not print the catalog timestamp"
grep -q 'status.json is fresh' "$WORK/part3.out" \
    || fail_test "a timer tick during delivery did not satisfy step 3.3"
{ show_status; } > "$WORK/terminal-verified.out"
grep -q 'VERIFIED' "$WORK/terminal-verified.out"

: > "$CALLS"; PARTNER_NAMESPACE=CHANGE-ME-zagros-uuid-slot
expect_failure "placeholder slot unexpectedly ran Part 3" \
    run_part3 > "$WORK/placeholder.out" 2>&1
grep -q 'nothing was published' "$WORK/placeholder.out"
assert_absent '^goat pub' "$CALLS" \
    "placeholder slot published an acceptance message"
PARTNER_NAMESPACE=slot-a

slot_case() {
    local name="$1" compose_value="$2" configured="$3" expected="$4" status
    : > "$CALLS"
    printf '%s\nZENOH_LOCAL_ENDPOINT=tls/127.0.0.1:7447\n' "$compose_value" \
        > "$FIXTURE/compose/.env"
    PARTNER_NAMESPACE=$configured
    set +e
    run_part3 > "$WORK/$name.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 1 ] || fail_test "$name exited $status instead of 1"
    grep -q "$expected" "$WORK/$name.out" \
        || fail_test "$name did not explain the router slot problem"
    assert_absent '^goat .* pub ' "$CALLS" \
        "$name published despite the router slot problem"
    assert_absent '^catalog ' "$CALLS" \
        "$name read the catalog despite the router slot problem"
}
slot_case missing-router-slot '# no slot' slot-a \
    'compose/.env does not say which slot the router runs for'
slot_case changed-router-slot 'PARTNER_NAMESPACE=slot-a' slot-b \
    'The router runs for slot slot-a, but the configured slot is slot-b'
printf 'PARTNER_NAMESPACE=slot-a\nZENOH_LOCAL_ENDPOINT=tls/127.0.0.1:7447\n' \
    > "$FIXTURE/compose/.env"
PARTNER_NAMESPACE=slot-a

# An unsynchronized clock skips delivery but still runs the local checks.
wait_for() { return 0; }
clock_synchronized_probe() { return 1; }
: > "$CALLS"
set +e
run_part3 > "$WORK/clock-failed.out" 2>&1
clock_status=$?
set -e
[ "$clock_status" -eq 2 ]
grep -q 'nothing was published' "$WORK/clock-failed.out"
grep -q 'NOT VERIFIED' "$WORK/clock-failed.out"
grep -q 'Delivery:.*Not verified' "$WORK/clock-failed.out"
assert_absent '^goat pub' "$CALLS" \
    "unsynchronized clock published an acceptance message"
clock_synchronized_probe() { return 0; }
unset GOAT_CONTEXT

saved_profile_dir=$GOAT_PROFILE_DIR
GOAT_PROFILE_DIR="$WORK/backup-only-profile"
mkdir -p "$GOAT_PROFILE_DIR/contexts/default.bak"
printf 'current_context = "default"\n' > "$GOAT_PROFILE_DIR/config.toml"
printf x > "$GOAT_PROFILE_DIR/contexts/default.bak/mtls.cert.pem"
expect_failure "backup certificate satisfied the active-profile probe" \
    goat_profile_present_probe
GOAT_PROFILE_DIR=$saved_profile_dir

delivery_case() (
    set +e
    local name="$1" audit_values="$2" catalog_values="$3" publish_rc="$4" expected="$5"
    local timeout="${6:-2}"
    local catalog_delay="${7:-0}"
    local audit_file="$WORK/audit-$name" catalog_file="$WORK/catalog-$name" value rc
    local clock_file="$WORK/clock-$name" now
    FABRIC_CONFIRM_TIMEOUT="$timeout"; FABRIC_COUNT_RETRY_DELAY=1
    printf 0 > "$audit_file"; printf 0 > "$catalog_file"; printf 100 > "$clock_file"
    date() { if [ "${1:-}" = +%s ]; then cat "$clock_file"; else command date "$@"; fi; }
    sleep() {
        now=$(cat "$clock_file")
        if [ -n "${PUBLISH_STARTED_AT:-}" ] \
                && [ "$now" -ge "$((PUBLISH_STARTED_AT + FABRIC_CONFIRM_TIMEOUT))" ]; then
            : > "$WORK/deadline-$name"
            return 0
        fi
        printf '%s' "$((now + $1))" > "$clock_file"
    }
    audit_samples_total() {
        local n; n=$(cat "$audit_file"); n=$((n + 1)); printf '%s' "$n" > "$audit_file"
        value=$(printf '%s' "$audit_values" | cut -d, -f"$n")
        [ -n "$value" ] || value=$(printf '%s' "$audit_values" | awk -F, '{print $NF}')
        [ "$value" != x ] || return 1
        echo "$value"
    }
    catalog_count_read() {
        local n; n=$(cat "$catalog_file"); n=$((n + 1)); printf '%s' "$n" > "$catalog_file"
        if [ "$n" -gt 1 ]; then
            now=$(cat "$clock_file")
            printf '%s' "$((now + catalog_delay))" > "$clock_file"
        fi
        value=$(printf '%s' "$catalog_values" | cut -d, -f"$n")
        [ -n "$value" ] || value=$(printf '%s' "$catalog_values" | awk -F, '{print $NF}')
        case "$value" in
            forbidden) echo 'not confirmed: portal refused the catalog read with HTTP 403'; return 2 ;;
            rate) echo 'not confirmed: portal refused the catalog read with HTTP 429'; return 3 ;;
            timeout) echo 'not confirmed: catalog read timed out'; return 124 ;;
            unreachable) echo 'not confirmed: catalog read could not reach the portal'; return 1 ;;
            *) printf '%b\n' "$value"; return 0 ;;
        esac
    }
    publish_through_local_router() {
        : > "$WORK/published-$name"
        PUBLISH_STARTED_AT=$(cat "$clock_file")
        PUBLISH_STARTED_UTC=1970-01-01T00:01:40Z
        DELIVERY_KEY=slot-a/test/ping
        DELIVERY_NONCE=deadbeef
        return "$publish_rc"
    }
    run_delivery_check > "$WORK/delivery-$name.out" 2>&1
    [ ! -e "$WORK/deadline-$name" ] \
        || fail_test "delivery poll slept after its deadline"
    [ "$DELIVERY_OUTCOME" = "$expected" ] || {
        echo "FAIL: $name returned $DELIVERY_OUTCOME, expected $expected" >&2; exit 1;
    }
    printf '%s\n' "$DELIVERY_DETAIL" >> "$WORK/delivery-$name.out"
    now=$(cat "$clock_file")
    if [ -n "$PUBLISH_STARTED_AT" ]; then
        [ "$now" -le "$((PUBLISH_STARTED_AT + FABRIC_CONFIRM_TIMEOUT + catalog_delay))" ] \
            || fail_test "$name passed the delivery deadline and one in-progress read"
    fi
)
delivery_case publish-failed '1' '5\t0' 1 'Publish failed'
delivery_case not-delivered '1,1,1' '5\t0,6\t100' 0 'Not delivered'
delivery_case audit-unreadable 'x' '5\t0' 0 'Not verified'
delivery_case audit-after-unreadable '1,x,x' '5\t0,5\t0' 0 'Not verified'
delivery_case local-only '1,2,2' '5\t0,5\t0' 0 'Local only'
delivery_case stale-rise '1,2' '5\t0,6\t99' 0 'Local only'
delivery_case delivered '1,2' '5\t0,6\t100' 0 'Delivered'
delivery_case zero-baseline '1,2' '0\t0,1\t100' 0 'Delivered'
delivery_case rise-then-unreachable '1,1,2' '5\t0,6\t100,unreachable' 0 'Delivered' 6
delivery_case slow-catalog-read '1,2' '5\t0,5\t0' 0 'Local only' 3 20
delivery_case ok-then-forbidden '1,2' '5\t0,5\t0,forbidden' 0 'Not verified' 4
delivery_case ok-then-rate '1,2' '5\t0,5\t0,rate' 0 'Not verified' 4
delivery_case ok-then-timeout '1,2' '5\t0,5\t0,timeout' 0 'Not verified' 4
delivery_case control-no-rise '1,2' '5\t0' 0 'Local only' 4
for cause in forbidden rate timeout unreachable; do
    delivery_case "$cause" '1,2' "$cause" 0 'Not verified'
done
[ ! -e "$WORK/published-audit-unreadable" ] \
    || fail_test "audit-unreadable published after its verdict was settled"
grep -q 'baseline: publish_count=0 last_publish_at=none' \
    "$WORK/delivery-zero-baseline.out" \
    || fail_test "zero catalog timestamp was not printed as none"

set +e
(
    audit_samples_total() { return 1; }
    run_part3
) > "$WORK/not-verified.out" 2>&1
not_verified_rc=$?
set -e
[ "$not_verified_rc" -eq 2 ]
grep -q 'NOT VERIFIED' "$WORK/not-verified.out"

grep -q 'bundle verification or certificate/slot binding failed' "$WORK/wrong-bundle.out"
grep -q '\[FAILED\].*3.0 (Inputs)' "$WORK/placeholder.out"
grep -q 'Delivery:.*Delivered' "$WORK/part3.out"
for state in first rerun verified; do
    if LC_ALL=C grep -q $'\033' "$WORK/terminal-$state.out"; then
        echo "FAIL: terminal $state output contains color in TERM=dumb mode" >&2; exit 1
    fi
done
python3 - "$WORK/terminal-first.out" "$WORK/terminal-rerun.out" \
    "$WORK/terminal-verified.out" "$WORK/missing-goatnet.out" \
    "$WORK/clock-failed.out" "$WORK/not-verified.out" "$WORK/part3.out" \
    "$WORK/uppercase-pod-id.out" "$WORK/missing-router-slot.out" \
    "$WORK/changed-router-slot.out" <<'PY'
import pathlib
import sys

for name in sys.argv[1:]:
    for number, line in enumerate(pathlib.Path(name).read_text().splitlines(), 1):
        if len(line) > 80:
            raise SystemExit(
                f"FAIL: {name}:{number} exceeds 80 columns ({len(line)}): {line}"
            )
PY
printf 'terminal states (80 columns, no color, no TTY): first, rerun, blocked, failed, passed\n'

echo "PASS: setup stub end-to-end gates and verdicts"
