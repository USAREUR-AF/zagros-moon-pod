#!/usr/bin/env bash
# moon-pod — install the pinned goat-pod-api release (ADR 1251 pod carriage).
#
#   install-goat-pod-api.sh [pin-file]      default: host/goat-pod-api.pin beside this script
#
# Downloads the release the pin names (goatcore .github/workflows/goat-pod-api-release.yml) and
# installs goat-pod-api to ${GOAT_POD_API_BIN_DIR:-/usr/local/bin} and gatepost.html to
# ${GOAT_POD_API_SHARE_DIR:-/usr/local/share/goat-pod-api}. Every download is verified before
# anything is installed, and any mismatch refuses the install:
#   1. SHA256SUMS has the digest the pin names;
#   2. cosign verifies SHA256SUMS.cosign-bundle as made by goatcore's goat-pod-api-release.yml
#      workflow for exactly the pinned tag (keyless, GitHub OIDC issuer);
#   3. the binary and gatepost.html have the digests SHA256SUMS lists.
# A checksum alone is never enough: without cosign the install is refused.
#
# Idempotent: when the installed files already have the release's digests, nothing changes.
#
# Exit status: 0 installed or already installed; 1 refused (a check failed, or a tool is
# missing); 2 usage; 3 no release is pinned yet (nothing was downloaded or changed).
#
# Test hooks: GOAT_POD_API_BASE_URL replaces the release download URL; COSIGN names the cosign
# binary; GOAT_POD_API_ARCH replaces the detected architecture.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIN="${1:-${HERE}/goat-pod-api.pin}"
BIN_DIR="${GOAT_POD_API_BIN_DIR:-/usr/local/bin}"
SHARE_DIR="${GOAT_POD_API_SHARE_DIR:-/usr/local/share/goat-pod-api}"
COSIGN="${COSIGN:-cosign}"
OIDC_ISSUER="https://token.actions.githubusercontent.com"

refuse() { echo "goat-pod-api install refused: $*" >&2; exit 1; }

[ -f "${PIN}" ] || { echo "no such pin file: ${PIN}" >&2; exit 2; }
GOAT_POD_API_REPO=""
GOAT_POD_API_TAG=""
GOAT_POD_API_SHA256SUMS_SHA256=""
# shellcheck disable=SC1090
source "${PIN}"
if [ -z "${GOAT_POD_API_TAG}" ] || [ -z "${GOAT_POD_API_SHA256SUMS_SHA256}" ]; then
  echo "no goat-pod-api release is pinned in ${PIN}; nothing was installed." >&2
  exit 3
fi
[ -n "${GOAT_POD_API_REPO}" ] || refuse "the pin names no repository"
case "${GOAT_POD_API_TAG}" in
  goat-pod-api/v[0-9]*) ;;
  *) refuse "pinned tag ${GOAT_POD_API_TAG} is not a goat-pod-api/v<semver> tag" ;;
esac
case "${GOAT_POD_API_SHA256SUMS_SHA256}" in
  *[!0-9a-f]*) refuse "the pinned SHA256SUMS digest is not lowercase hex" ;;
esac
[ "${#GOAT_POD_API_SHA256SUMS_SHA256}" -eq 64 ] || refuse "the pinned SHA256SUMS digest is not 64 hex characters"

for tool in curl sha256sum install; do
  command -v "${tool}" >/dev/null 2>&1 || refuse "required tool not found: ${tool}"
done
command -v "${COSIGN}" >/dev/null 2>&1 \
  || refuse "cosign is not installed; the release signature cannot be checked, and a checksum alone is not enough (https://docs.sigstore.dev/cosign/system_config/installation/)"

arch="${GOAT_POD_API_ARCH:-$(uname -m)}"
case "${arch}" in
  x86_64|amd64) arch=amd64 ;;
  aarch64|arm64) arch=arm64 ;;
  *) refuse "no goat-pod-api build for architecture ${arch}" ;;
esac
BIN_ASSET="goat-pod-api-linux-${arch}"
BASE="${GOAT_POD_API_BASE_URL:-https://github.com/${GOAT_POD_API_REPO}/releases/download/${GOAT_POD_API_TAG}}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

for f in SHA256SUMS SHA256SUMS.cosign-bundle "${BIN_ASSET}" gatepost.html; do
  curl -fsSL --retry 3 -o "${work}/${f}" "${BASE}/${f}" || refuse "could not download ${BASE}/${f}"
done

# 1. The pinned digest of SHA256SUMS.
got="$(sha256sum "${work}/SHA256SUMS" | cut -d' ' -f1)"
[ "${got}" = "${GOAT_POD_API_SHA256SUMS_SHA256}" ] \
  || refuse "SHA256SUMS of ${GOAT_POD_API_TAG} has digest ${got}, the pin names ${GOAT_POD_API_SHA256SUMS_SHA256}"

# 2. The signature, made by goatcore's release workflow for exactly this tag.
tag_re="$(printf '%s' "${GOAT_POD_API_TAG}" | sed 's/[.]/\\./g')"
repo_re="$(printf '%s' "${GOAT_POD_API_REPO}" | sed 's/[.]/\\./g')"
identity="^https://github\.com/${repo_re}/\.github/workflows/goat-pod-api-release\.yml@refs/tags/${tag_re}$"
"${COSIGN}" verify-blob --bundle "${work}/SHA256SUMS.cosign-bundle" \
  --certificate-identity-regexp "${identity}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  "${work}/SHA256SUMS" >"${work}/cosign.out" 2>&1 || {
  tail -n 5 "${work}/cosign.out" >&2
  refuse "the signature on SHA256SUMS does not verify as goatcore's goat-pod-api-release.yml for ${GOAT_POD_API_TAG}"
}

# 3. Each asset's digest as SHA256SUMS lists it.
digest_of() {
  awk -v f="$1" '$2 == f || $2 == "*" f { print $1 }' "${work}/SHA256SUMS"
}
for f in "${BIN_ASSET}" gatepost.html; do
  want="$(digest_of "${f}")"
  [ -n "${want}" ] || refuse "SHA256SUMS lists no digest for ${f}"
  have="$(sha256sum "${work}/${f}" | cut -d' ' -f1)"
  [ "${have}" = "${want}" ] || refuse "${f} has digest ${have}, SHA256SUMS lists ${want}"
done

# Install, unless already installed.
installed_digest() { [ -f "$1" ] && sha256sum "$1" | cut -d' ' -f1 || true; }
if [ "$(installed_digest "${BIN_DIR}/goat-pod-api")" = "$(digest_of "${BIN_ASSET}")" ] && \
   [ "$(installed_digest "${SHARE_DIR}/gatepost.html")" = "$(digest_of gatepost.html)" ]; then
  echo "goat-pod-api ${GOAT_POD_API_TAG} is already installed"
  exit 0
fi
install -d -m 0755 "${BIN_DIR}" "${SHARE_DIR}"
# Stage beside the target, then rename, so a running service never sees a partial file.
install -m 0755 "${work}/${BIN_ASSET}" "${BIN_DIR}/.goat-pod-api.new"
mv "${BIN_DIR}/.goat-pod-api.new" "${BIN_DIR}/goat-pod-api"
install -m 0644 "${work}/gatepost.html" "${SHARE_DIR}/.gatepost.html.new"
mv "${SHARE_DIR}/.gatepost.html.new" "${SHARE_DIR}/gatepost.html"
printf '%s\n' "${GOAT_POD_API_TAG}" > "${SHARE_DIR}/INSTALLED_TAG"
echo "installed goat-pod-api ${GOAT_POD_API_TAG} (${BIN_ASSET}) to ${BIN_DIR} and gatepost.html to ${SHARE_DIR}"
