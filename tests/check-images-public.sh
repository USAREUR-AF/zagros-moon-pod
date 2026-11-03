#!/usr/bin/env bash
# check-images-public.sh — assert every image referenced in the compose files
# (compose/docker-compose*.yml, base + overlays) is ANONYMOUSLY pullable. A partner-custodial
# pod has no usareur-af ghcr credentials, so a private image is a hard deploy blocker. Run before any pod
# deploy; wire into CI for the pod repo.
#
# Uses the registry HTTP API (no docker daemon needed): for each image, fetch an anonymous
# pull token and HEAD the manifest. 200 = public, 401/403 = private.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "${HERE}/compose/docker-compose.yml" ] || { echo "no compose file at ${HERE}/compose/"; exit 2; }

# Extract `image:` refs from every compose file. POSIX char classes because \s is not portable
# to BSD sed on macOS; while-read instead of mapfile because macOS ships bash 3.2.
IMAGES=()
while IFS= read -r img; do
  IMAGES+=("$img")
done < <(grep -hE '^[[:space:]]*image:' "${HERE}"/compose/docker-compose*.yml \
         | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+#.*//')
[ "${#IMAGES[@]}" -gt 0 ] || { echo "no image refs found in ${HERE}/compose/"; exit 2; }

fail=0
for ref in "${IMAGES[@]}"; do
  # ref forms: registry/repo:tag@sha256:... | repo:tag | repo@sha256:...
  # Resolve registry + repo + reference (digest or tag).
  digest=""; case "$ref" in *@sha256:*) digest="sha256:${ref##*@sha256:}";; esac
  noref="${ref%@*}"                      # drop @digest
  case "$noref" in
    *.*/*|*:*/*) reg="${noref%%/*}"; repo="${noref#*/}";;   # has a registry host
    */*)         reg="docker.io"; repo="$noref";;
    *)           reg="docker.io"; repo="library/$noref";;
  esac
  tag="latest"; case "$repo" in *:*) tag="${repo##*:}"; repo="${repo%%:*}";; esac
  manref="${digest:-$tag}"

  # Normalize docker.io → registry-1.docker.io.
  host="$reg"; [ "$reg" = "docker.io" ] && host="registry-1.docker.io"

  # Anonymous token (ghcr + dockerhub both use token auth realms).
  case "$host" in
    ghcr.io)              token=$(curl -fsSL "https://ghcr.io/token?scope=repository:${repo}:pull" 2>/dev/null | sed -E 's/.*"token":"([^"]+)".*/\1/');;
    registry-1.docker.io) token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null | sed -E 's/.*"token":"([^"]+)".*/\1/');;
    *)                    token="";;
  esac

  code=$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "https://${host}/v2/${repo}/manifests/${manref}" 2>/dev/null || true)

  if [ "$code" = "200" ]; then
    echo "PUBLIC  $ref"
  else
    echo "PRIVATE/UNREACHABLE ($code)  $ref"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo
  echo "FAIL: at least one pod image is not anonymously pullable. A partner pod cannot pull it."
  echo "      Make each listed image public in its registry's package settings."
  exit 1
fi
echo
echo "OK: all pod images are anonymously pullable."
