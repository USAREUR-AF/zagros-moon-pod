#!/usr/bin/env bash
# host/install-goat-pod-api.sh installs a pinned goat-pod-api release only when the pinned digest
# of SHA256SUMS, the cosign signature and every asset digest all check, and refuses otherwise,
# leaving an existing install untouched.
#
# The release is a local directory served as file:// and cosign is a stand-in that accepts a
# bundle only when it names the exact SHA256SUMS digest and is asked for goatcore's release
# workflow identity at the pinned tag. This tests the installer's decisions; the cosign
# verification itself is cosign's (and goatcore's release workflow verifies its own signature
# the same way).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/host/install-goat-pod-api.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TAG="goat-pod-api/v0.1.0"
fail() { echo "FAIL: $*" >&2; exit 1; }

REL="$WORK/release"
BIN="$WORK/bin"
mkdir -p "$REL" "$BIN"
printf '#!/bin/sh\necho goat-pod-api test build\n' > "$REL/goat-pod-api-linux-amd64"
printf '<!doctype html><title>Gatepost</title>\n' > "$REL/gatepost.html"
(cd "$REL" && sha256sum goat-pod-api-linux-amd64 gatepost.html > SHA256SUMS)
sign() { printf 'signed-sha256=%s\n' "$(sha256sum "$REL/SHA256SUMS" | cut -d' ' -f1)" > "$REL/SHA256SUMS.cosign-bundle"; }
sign

# cosign stand-in: verify-blob --bundle B --certificate-identity-regexp R --certificate-oidc-issuer I FILE
cat > "$BIN/cosign" <<'EOF'
#!/usr/bin/env bash
[ "$1" = verify-blob ] || exit 9
shift
bundle="" identity="" issuer="" file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) bundle="$2"; shift 2 ;;
    --certificate-identity-regexp) identity="$2"; shift 2 ;;
    --certificate-oidc-issuer) issuer="$2"; shift 2 ;;
    *) file="$1"; shift ;;
  esac
done
printf '%s\n' "$identity" > "${STUB_COSIGN_IDENTITY:?}"
[ "$issuer" = https://token.actions.githubusercontent.com ] || { echo "wrong issuer" >&2; exit 1; }
# The identity the installer asks for must name goatcore's release workflow at the pinned tag.
id='https://github.com/USAREUR-AF/goatcore/.github/workflows/goat-pod-api-release.yml@refs/tags/goat-pod-api/v0.1.0'
printf '%s' "$id" | grep -Eq "$identity" || { echo "identity $identity does not admit $id" >&2; exit 1; }
printf '%s' "${id}x" | grep -Eq "$identity" && { echo "identity $identity is not anchored" >&2; exit 1; }
[ "$(cat "$bundle")" = "signed-sha256=$(sha256sum "$file" | cut -d' ' -f1)" ] || { echo "bundle does not verify" >&2; exit 1; }
EOF
chmod +x "$BIN/cosign"
export STUB_COSIGN_IDENTITY="$WORK/identity"

pin() {
  local tag="$1" sum="$2"
  printf 'GOAT_POD_API_REPO=USAREUR-AF/goatcore\nGOAT_POD_API_TAG=%s\nGOAT_POD_API_SHA256SUMS_SHA256=%s\n' "$tag" "$sum" > "$WORK/pin"
}
sums() { sha256sum "$REL/SHA256SUMS" | cut -d' ' -f1; }
DEST="$WORK/dest"
run() {
  set +e
  PATH="$BIN:$PATH" GOAT_POD_API_BASE_URL="file://$REL" GOAT_POD_API_ARCH=x86_64 \
    GOAT_POD_API_BIN_DIR="$DEST/bin" GOAT_POD_API_SHARE_DIR="$DEST/share" \
    bash "$INSTALLER" "$WORK/pin" > "$WORK/out" 2>&1
  status=$?
  set -e
}
expect_refused() {
  local why="$1" pattern="$2"
  run
  [ "$status" -eq 1 ] || { cat "$WORK/out" >&2; fail "$why: exit $status, want 1"; }
  grep -q "$pattern" "$WORK/out" || { cat "$WORK/out" >&2; fail "$why: no '$pattern' in the refusal"; }
}

# Nothing pinned: nothing downloaded or installed.
pin "" ""
run
if [ "$status" -ne 3 ] || [ -e "$DEST" ]; then fail "unpinned release: exit $status, or files were installed"; fi

# A good release installs both files.
pin "$TAG" "$(sums)"
run
[ "$status" -eq 0 ] || { cat "$WORK/out" >&2; fail "good release refused"; }
cmp -s "$DEST/bin/goat-pod-api" "$REL/goat-pod-api-linux-amd64" || fail "binary not installed"
cmp -s "$DEST/share/gatepost.html" "$REL/gatepost.html" || fail "gatepost.html not installed"
[ -x "$DEST/bin/goat-pod-api" ] || fail "binary not executable"
[ "$(cat "$DEST/share/INSTALLED_TAG")" = "$TAG" ] || fail "installed tag not recorded"
grep -q 'goat-pod-api-release' "$WORK/identity" || fail "cosign was not asked for the release workflow identity"

# Running again changes nothing.
before="$(ls -li "$DEST/bin/goat-pod-api")"
run
if [ "$status" -ne 0 ] || ! grep -q 'already installed' "$WORK/out"; then fail "second run did not report already installed"; fi
[ "$(ls -li "$DEST/bin/goat-pod-api")" = "$before" ] || fail "second run replaced the binary"
installed="$(sha256sum "$DEST/bin/goat-pod-api")"

# A SHA256SUMS other than the pinned one.
pin "$TAG" "$(printf '0%.0s' $(seq 1 64))"
expect_refused "pin mismatch" "the pin names"

# SHA256SUMS changed and the pin moved to it, but the signature is over the old SHA256SUMS.
printf '#!/bin/sh\necho replaced\n' > "$REL/goat-pod-api-linux-amd64"
(cd "$REL" && sha256sum goat-pod-api-linux-amd64 gatepost.html > SHA256SUMS)
pin "$TAG" "$(sums)"
expect_refused "signature over other content" "signature on SHA256SUMS does not verify"

# Signed and pinned, but the binary served differs from what SHA256SUMS lists.
sign
printf '#!/bin/sh\necho tampered\n' > "$REL/goat-pod-api-linux-amd64"
expect_refused "tampered binary" "goat-pod-api-linux-amd64 has digest"

# A pin for another tag: the signature identity no longer matches the stand-in's workflow run.
(cd "$REL" && sha256sum goat-pod-api-linux-amd64 gatepost.html > SHA256SUMS)
sign
pin "goat-pod-api/v9.9.9" "$(sums)"
expect_refused "signature for another tag" "signature on SHA256SUMS does not verify"

# No cosign: a checksum alone is not enough.
pin "$TAG" "$(sums)"
rm "$BIN/cosign"
set +e
PATH="$BIN:$PATH" GOAT_POD_API_BASE_URL="file://$REL" GOAT_POD_API_ARCH=x86_64 \
  GOAT_POD_API_BIN_DIR="$DEST/bin" GOAT_POD_API_SHARE_DIR="$DEST/share" COSIGN="$BIN/cosign" \
  bash "$INSTALLER" "$WORK/pin" > "$WORK/out" 2>&1
status=$?
set -e
if [ "$status" -ne 1 ] || ! grep -q 'cosign is not installed' "$WORK/out"; then
  cat "$WORK/out" >&2
  fail "install went ahead without cosign"
fi

# Every refusal left the first install as it was.
[ "$(sha256sum "$DEST/bin/goat-pod-api")" = "$installed" ] || fail "a refused install changed the installed binary"
echo "PASS: goat-pod-api installer verifies the pin, the signature and every digest, and refuses on any mismatch"
