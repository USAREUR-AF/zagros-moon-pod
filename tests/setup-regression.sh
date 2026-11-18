#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2317,SC2329
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT_SOURCE="${SETUP_SCRIPT_UNDER_TEST:-$ROOT/moon_pod_setup.sh}"
PROFILE_ROOT="${PROFILE_ROOT_UNDER_TEST:-$ROOT/profiles}"
command -v grep >/dev/null 2>&1 || { echo "FAIL: grep is required" >&2; exit 1; }

test_temp_dirs=()
test_temp_pids=()
cleanup_test_temp_dirs() {
    local directory process
    for process in "${test_temp_pids[@]}"; do
        kill "$process" 2>/dev/null || true
        wait "$process" 2>/dev/null || true
    done
    for directory in "${test_temp_dirs[@]}"; do
        [ ! -d "$directory" ] || find "$directory" \( -type f -o -type l \) -delete
        [ ! -d "$directory" ] || find "$directory" -depth -type d -empty -delete
    done
}
trap cleanup_test_temp_dirs EXIT

script_fixture="$(mktemp -d)"
test_temp_dirs+=("$script_fixture")
mkdir -p "$script_fixture/profiles/zagros-local" "$script_fixture/compose"
cp "$SETUP_SCRIPT_SOURCE" "$script_fixture/moon_pod_setup.sh"
SETUP_SCRIPT="$script_fixture/moon_pod_setup.sh"

# shellcheck source=../moon_pod_setup.sh
set +e
# shellcheck disable=SC1090
source "$SETUP_SCRIPT"
set -e
# Sourcing the setup script replaces the test's EXIT trap.
trap 'cleanup || true; cleanup_test_temp_dirs' EXIT
case "$REPO_DIR" in
    "$script_fixture"/*|"$script_fixture") ;;
    *) echo "FAIL: sourced setup script escaped its temporary fixture" >&2; exit 1 ;;
esac

pass=0
fail_test() { echo "FAIL: $*" >&2; exit 1; }
accept() { mesh_ready_probe "$1" || fail_test "expected ready: $1"; pass=$((pass + 1)); }
reject() {
    local expected_reason="$1" status="$2"
    ! mesh_ready_probe "$status" || fail_test "expected not ready: $status"
    [ "$MESH_NOT_READY_REASON" = "$expected_reason" ] \
        || fail_test "wrong mesh reason: $MESH_NOT_READY_REASON"
    pass=$((pass + 1))
}

accept $'Management: Connected\nPeers count: 1/3 Connected'
reject 'the management connection is not Connected' \
    $'Management: Disconnected\nPeers count: 1/3 Connected'
reject 'no peers are connected' $'Management: Connected\nPeers count: 0/3 Connected'
reject 'the management connection is not Connected' $'Peers count: 3/3 Connected'

long_valid_label="$(printf 'a%.0s' {1..59})"
long_invalid_label="${long_valid_label}a"
accepted_labels=(pod-1 a a1b2 "$long_valid_label")
rejected_labels=(POD_1 Pod-1 pod_1 -pod pod- pod.example bad/label "$long_invalid_label" "")
for label in "${accepted_labels[@]}"; do
    valid_label "$label" || fail_test "valid POD_ID was rejected: '$label'"
done
for label in "${rejected_labels[@]}"; do
    ! valid_label "$label" || fail_test "invalid POD_ID was accepted: '$label'"
done
pass=$((pass + 1))

# These globals and stubs are consumed indirectly by luks_mounted_probe from the sourced script.
# shellcheck disable=SC2034
STATE_DIR=/var/lib/goat-moon
# shellcheck disable=SC2034
LUKS_MAPPER=/dev/mapper/goat-moon
# shellcheck disable=SC2329
findmnt() { echo /dev/mapper/unencrypted-lvm-root; }
! luks_mounted_probe || fail_test "an arbitrary device-mapper filesystem must not count as the POD LUKS volume"
# shellcheck disable=SC2329
findmnt() { echo /dev/mapper/goat-moon; }
luks_mounted_probe || fail_test "the dedicated POD LUKS mapper must be accepted"
unset -f findmnt
pass=$((pass + 1))

persist_copy_dir="$(mktemp -d)"
test_temp_dirs+=("$persist_copy_dir")
mkdir -p "$persist_copy_dir/profiles/zagros-local"
if ! (
    REPO_DIR="$persist_copy_dir"
    PROFILE_NAME=zagros-local
    SOURCE_PROFILE=zagros
    INPUT_STATE_FILE="$persist_copy_dir/profiles/zagros-local/setup-inputs.env"
    PARTNER_NAMESPACE=slot-a
    POD_ID=pod-1
    GOATNET=example.invalid
    NETBIRD_MANAGEMENT_URL=https://management.example
    BUNDLE_TARBALL=/tmp/bundle.tar.gz
    BUNDLE_PATH=/tmp/bundle.cbor
    CA_ROOT_PEM=/tmp/root.pem
    EXPECTED_CA_FINGERPRINT=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    NETBIRD_SETUP_KEY=must-not-be-saved
    persist_inputs
) > "$persist_copy_dir/output" 2>&1; then
    fail_test "persist_inputs refused a copy that is not a git checkout"
fi
[ "$(stat -c %a "$persist_copy_dir/profiles/zagros-local/setup-inputs.env")" = 600 ] \
    || fail_test "saved inputs from a non-git copy must have mode 600"
grep -q '^PARTNER_NAMESPACE=slot-a$' \
    "$persist_copy_dir/profiles/zagros-local/setup-inputs.env" \
    || fail_test "saved inputs from a non-git copy omitted PARTNER_NAMESPACE"
! grep -q 'must-not-be-saved' "$persist_copy_dir/profiles/zagros-local/setup-inputs.env" \
    || fail_test "saved inputs from a non-git copy contained the setup key"
grep -q 'not a git checkout - saving inputs without a git-ignore check' \
    "$persist_copy_dir/output" \
    || fail_test "saving inputs from a non-git copy did not warn about the skipped check"

persist_checkout_dir="$(mktemp -d)"
test_temp_dirs+=("$persist_checkout_dir")
mkdir -p "$persist_checkout_dir/profiles/zagros-local"
git -C "$persist_checkout_dir" init -q
if (
    REPO_DIR="$persist_checkout_dir"
    PROFILE_NAME=zagros-local
    SOURCE_PROFILE=zagros
    INPUT_STATE_FILE="$persist_checkout_dir/profiles/zagros-local/setup-inputs.env"
    persist_inputs
) > "$persist_checkout_dir/output" 2>&1; then
    fail_test "persist_inputs saved an input file that is not git-ignored"
fi
grep -q 'is not git-ignored' "$persist_checkout_dir/output" \
    || fail_test "persist_inputs did not explain the missing ignore rule"

pass=$((pass + 1))

archive_test_dir="$(mktemp -d)"
test_temp_dirs+=("$archive_test_dir")
python3 - "$archive_test_dir/traversal.tar.gz" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:gz") as archive:
    member = tarfile.TarInfo("../escaped")
    member.size = 1
    archive.addfile(member, io.BytesIO(b"x"))
PY
! archive_members_safe "$archive_test_dir/traversal.tar.gz" >/dev/null 2>&1 \
    || fail_test "archive traversal member must be refused"
[ ! -e "$archive_test_dir/../escaped" ] || fail_test "archive traversal escaped its destination"
pass=$((pass + 1))

fabric_evidence_is_current 12 13 1700000010 1700000000 \
    || fail_test "a rising count with a current timestamp must pass"
! fabric_evidence_is_current 12 13 1699999999 1700000000 \
    || fail_test "a rising count from an older event must fail"
! fabric_evidence_is_current 12 12 1700000010 1700000000 \
    || fail_test "an unchanged count must fail"
pass=$((pass + 1))

[ "$(classify_delivery_outcome 0 1 0 1 0)" = "Publish failed" ] \
    || fail_test "publish error must be Publish failed"
[ "$(classify_delivery_outcome 1 1 0 1 1)" = "Not delivered" ] \
    || fail_test "a catalog rise cannot hide a missing local rise"
[ "$(classify_delivery_outcome 1 0 0 1 0)" = "Not verified" ] \
    || fail_test "an unreadable local count must be Not verified"
[ "$(classify_delivery_outcome 1 1 1 1 0)" = "Local only" ] \
    || fail_test "a local-only rise must be Local only"
[ "$(classify_delivery_outcome 1 1 1 1 1)" = "Delivered" ] \
    || fail_test "both rises must be Delivered"
pass=$((pass + 1))

context_dir="$(mktemp -d)"
test_temp_dirs+=("$context_dir")
context_case() {
    local name="$1" environment="$2" config="$3" expected_status="$4" expected="$5"
    local output status
    local -a env_args
    find "$context_dir" \( -type f -o -type l \) -delete
    [ "$config" = NONE ] || printf 'current_context = "%s"\n' "$config" \
        > "$context_dir/config.toml"
    case "$environment" in
        UNSET) env_args=(-u GOAT_CONTEXT) ;;
        EMPTY) env_args=(GOAT_CONTEXT=) ;;
        *) env_args=("GOAT_CONTEXT=$environment") ;;
    esac
    set +e
    # shellcheck disable=SC2016
    output=$(env "${env_args[@]}" bash -c 'source "$1"; goat_active_context "$2"' \
        context-shell "$ROOT/host/goat-context.sh" "$context_dir" 2>&1)
    status=$?
    set -e
    [ "$status" -eq "$expected_status" ] \
        || fail_test "$name context status was $status"
    [ "$output" = "$expected" ] \
        || fail_test "$name context result was '$output'"
}

context_case env-set other default 0 other
context_case env-empty EMPTY default 1 \
    'GOAT_CONTEXT is set but empty; unset it or name a context'
context_case config UNSET pod 0 pod
context_case default UNSET NONE 0 default
context_case dotdot .. default 1 'invalid active goat context: ..'
context_case slash a/b default 1 'invalid active goat context: a/b'
pass=$((pass + 1))

checksum_dir="$(mktemp -d)"
test_temp_dirs+=("$checksum_dir")
checksum_binary="$checksum_dir/goat-linux-arm64"
printf 'verified goat binary\n' > "$checksum_binary"
checksum_hash=$(sha256sum "$checksum_binary" | awk '{print $1}')
printf 'different file\n' > "$checksum_dir/other.txt"
other_hash=$(sha256sum "$checksum_dir/other.txt" | awk '{print $1}')

checksum_case() {
    local name="$1" contents="$2" expected="$3" checksum_file
    checksum_file="$checksum_dir/$name.sha256"
    if [ "$contents" = MISSING ]; then
        unlink "$checksum_file" 2>/dev/null || true
    else
        printf '%b' "$contents" > "$checksum_file"
    fi
    if goat_checksum_matches "$checksum_binary" "$checksum_file"; then
        [ "$expected" = accept ] \
            || fail_test "checksum case $name accepted an invalid checksum"
    else
        [ "$expected" = reject ] \
            || fail_test "checksum case $name rejected a valid checksum"
    fi
}

checksum_case correct "$checksum_hash  goat-linux-arm64\n" accept
checksum_case binary-marker "$checksum_hash *goat-linux-arm64\n" accept
checksum_case uppercase "${checksum_hash^^}  goat-linux-arm64\n" accept
checksum_case other-file "$other_hash  other.txt\n" reject
checksum_case wrong-hash "$(printf '0%.0s' {1..64})  goat-linux-arm64\n" reject
checksum_case two-lines "$checksum_hash  goat-linux-arm64\n$checksum_hash  goat-linux-arm64\n" reject
checksum_case empty '' reject
checksum_case missing MISSING reject
checksum_case name-mismatch "$checksum_hash  goat-linux-amd64\n" reject
checksum_case path-name "$checksum_hash  dir/goat-linux-arm64\n" reject
pass=$((pass + 1))

install_calls="$checksum_dir/install-calls"
install() { printf '%s\n' "$*" >> "$install_calls"; }
cp "$checksum_dir/correct.sha256" "${checksum_binary}.sha256"
CURRENT_SHA=""; GOAT_INSTALL_TEMP_DIR=""; FAILED=0
install_goat_binary "$checksum_binary" > "$checksum_dir/install.out"
[ -s "$install_calls" ] || fail_test "verified goat binary was not installed"
installed_source=$(awk '{print $(NF-1)}' "$install_calls")
[ "$installed_source" != "$checksum_binary" ] \
    || fail_test "goat was installed from the mutable source path"
temp_root=${TMPDIR:-/tmp}; temp_root=${temp_root%/}
case "$installed_source" in
    "$temp_root"/*/goat-linux-arm64) ;;
    *) fail_test "goat was not installed from the temporary verified copy" ;;
esac
[ ! -e "$(dirname "$installed_source")" ] \
    || fail_test "verified goat temporary directory was not removed"

: > "$install_calls"
printf '%064d  goat-linux-arm64\n' 0 > "${checksum_binary}.sha256"
if install_goat_binary "$checksum_binary" > "$checksum_dir/mismatch.out"; then
    fail_test "mismatched goat checksum was accepted for installation"
fi
[ ! -s "$install_calls" ] \
    || fail_test "mismatched goat binary called install"
[ -z "$GOAT_INSTALL_TEMP_DIR" ] \
    || fail_test "failed goat verification left its temporary directory registered"
unset -f install

download_calls=0
curl() {
    download_calls=$((download_calls + 1))
    [ "$download_calls" -eq 1 ]
}
CURRENT_SHA=installed-hash; SOURCE_BIN=""; FAILED=0
download_goat_binary https://get.example.invalid arm64 "$checksum_dir" \
    > "$checksum_dir/download-installed.out"
[ "$FAILED" -eq 0 ] \
    || fail_test "a failed update download rejected the installed goat"
[ -z "$SOURCE_BIN" ] \
    || fail_test "a failed update download selected an incomplete goat binary"
grep -q 'keeping the installed goat' "$checksum_dir/download-installed.out" \
    || fail_test "a failed update download did not explain the installed fallback"

download_calls=0; CURRENT_SHA=""; SOURCE_BIN=""; FAILED=0
download_goat_binary https://get.example.invalid arm64 "$checksum_dir" \
    > "$checksum_dir/download-missing.out"
[ "$FAILED" -eq 1 ] \
    || fail_test "a failed initial goat download did not fail Part 1"
unset -f curl

pass=$((pass + 1))

curl() { return 1; }
if audit_samples_total >/dev/null 2>&1; then
    fail_test "a failed metric scrape must remain unknown"
fi
pass=$((pass + 1))

curl() { printf '%s\n' 'goat_audit_subscriber_session_state 1'; }
[ "$(audit_samples_total)" = 0 ] \
    || fail_test "a reachable fresh audit sink must have a zero-sample baseline"
pass=$((pass + 1))

unset -f curl
listener_port_file="$script_fixture/listener-port"
python3 - "$listener_port_file" <<'PY' &
import socket
import sys

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen()
with open(sys.argv[1], "w", encoding="ascii") as handle:
    handle.write(str(listener.getsockname()[1]))
    handle.flush()
connections = []
while True:
    connection, _ = listener.accept()
    connections.append(connection)
PY
listener_pid=$!
test_temp_pids+=("$listener_pid")
for _ in $(seq 1 200); do
    [ ! -s "$listener_port_file" ] || break
    kill -0 "$listener_pid" 2>/dev/null \
        || fail_test "stalled HTTP listener exited before readiness"
    sleep 0.05
done
[ -s "$listener_port_file" ] \
    || fail_test "stalled HTTP listener did not become ready within 10 seconds"
listener_url="http://127.0.0.1:$(cat "$listener_port_file")/metrics"

started_at=$(date +%s)
set +e
# shellcheck disable=SC2016
timeout 30 bash -c '
    source "$1"
    AUDIT_METRICS_URL="$2"
    AUDIT_METRICS_TIMEOUT=1
    audit_samples_total >/dev/null
' audit-timeout "$SETUP_SCRIPT" "$listener_url"
metric_status=$?
set -e
[ "$metric_status" -ne 124 ] \
    || fail_test "audit metric read did not return within 30s"
[ "$metric_status" -ne 0 ] \
    || fail_test "stalled audit metric read unexpectedly succeeded"
[ "$(( $(date +%s) - started_at ))" -lt 5 ] \
    || fail_test "audit metric read did not fail within 5 seconds"

pass=$((pass + 1))

if grep -nE '^[^#]*curl[[:space:]]' "$SETUP_SCRIPT" \
        | grep -v -- '--max-time'; then
    fail_test "a setup curl call has no --max-time limit"
fi
pass=$((pass + 1))

for required in grep python3; do
    command -v "$required" >/dev/null 2>&1 || fail_test "required test tool missing: $required"
done
if grep -En 'docker (stop|start) goat-moon-zenoh-router|goat flow .*--since' \
    "$SETUP_SCRIPT" "$ROOT/docs/partner-run-guide.md"; then
    fail_test "obsolete router manipulation or operator-audit verification remains"
fi
pass=$((pass + 1))

python3 - "$SETUP_SCRIPT" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
part1 = source.split("run_part1() {", 1)[1].split("#  PART 2 / 3", 1)[0]
if "netbird_up_if_needed" in part1:
    raise SystemExit("Part 1 still calls the mesh join")
if "netbird up" in part1:
    raise SystemExit("Part 1 still contains a direct netbird up call")
if "mesh_connected_probe" in source:
    raise SystemExit("the loose mesh probe still exists")
PY
pass=$((pass + 1))

grep -q '^VERIFY_CERT_SLOT_BINDING=1$' "$PROFILE_ROOT/zagros/profile.env" \
    || fail_test "zagros must enable certificate/slot binding"
grep -q '^# VERIFY_CERT_SLOT_BINDING=0' "$PROFILE_ROOT/production/profile.env.TODO" \
    || fail_test "production must leave certificate/slot binding off"
! grep -q "Fetch your goatnet's root from https://get" "$SETUP_SCRIPT" \
    || fail_test "missing trust must not direct an unenrolled POD to a mesh-only URL"
pass=$((pass + 1))

python3 - "$SETUP_SCRIPT" <<'PY'
import os, signal, subprocess, sys, tempfile, time

script = sys.argv[1]
for sig, expected in ((signal.SIGINT, 130), (signal.SIGTERM, 143), (signal.SIGHUP, 129)):
    with tempfile.TemporaryDirectory() as tmp:
        marker = os.path.join(tmp, "cleanup")
        ready = os.path.join(tmp, "ready")
        command = (
            'source "$1"; '
            'marker="$2"; ready="$3"; '
            'verify_temp_cleanup(){ printf x >> "$marker"; }; '
            'printf x > "$ready"; '
            'CLEANUP_DONE=0; while :; do sleep 30; done'
        )
        proc = subprocess.Popen(
            ["bash", "-c", command, "signal-test", script, marker, ready],
            start_new_session=True,
        )
        deadline = time.monotonic() + 10
        while not os.path.exists(ready):
            if proc.poll() is not None:
                raise SystemExit(f"signal {sig} child exited before readiness")
            if time.monotonic() >= deadline:
                proc.kill()
                raise SystemExit(f"signal {sig} child did not become ready")
            time.sleep(0.01)
        os.killpg(proc.pid, sig)
        code = proc.wait(timeout=5)
        if code != expected:
            raise SystemExit(f"signal {sig} exited {code}, expected {expected}")
        with open(marker, encoding="utf-8") as handle:
            if handle.read() != "x":
                raise SystemExit(f"signal {sig} did not run cleanup exactly once")
PY
pass=$((pass + 1))

echo "PASS: $pass setup regression checks"
