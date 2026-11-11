#!/usr/bin/env bash
# Shared certificate-identity checks for the pod router and its regression tests.

certificate_cn() {
  openssl x509 -in "$1" -noout -subject -nameopt sep_multiline 2>/dev/null \
    | sed -n 's/^[[:space:]]*CN[[:space:]]*=[[:space:]]*//p' \
    | head -1
}

safe_certificate_cn() {
  [ -n "$1" ] && case "$1" in *[!A-Za-z0-9._:-]*) return 1;; esac
}

valid_zenoh_zid() {
  [ -n "$1" ] && [ "${#1}" -le 32 ] && case "$1" in
    0*|*[!0-9a-f]*) return 1 ;;
  esac
}

derive_pod_router_zid() {
  local pod_cn="$1" zid
  zid="$(printf '%s' "${pod_cn}|moon-pod-router" | sha256sum | cut -c1-32)"
  zid="${zid#"${zid%%[!0]*}"}"
  valid_zenoh_zid "$zid" || return 1
  printf '%s\n' "$zid"
}

fabric_identity_error() {
  printf 'fabric identity check failed: %s\n' "$1" >&2
}

fabric_operator_next_step() {
  printf '    Goat-side operator: confirm the endpoint and router certificate.\n' >&2
  printf '    Partner: apply the correction, then re-run first-boot.\n' >&2
}

check_fabric_identity_continuity() {
  local discovered_cn="$1" pinned_cn="$2" recorded_cn="$3"

  if [ -z "$pinned_cn" ] && [ -n "$recorded_cn" ] && \
    ! safe_certificate_cn "$recorded_cn"; then
    fabric_identity_error 'the recorded router certificate name is invalid.'
    printf '    Partner: do not replace the record by hand. Ask the goat-side\n' >&2
    printf '    operator to confirm the endpoint identity, then set the confirmed\n' >&2
    printf '    ZENOH_FABRIC_CERT_CN in the active profile and re-run first-boot.\n' >&2
    return 1
  fi
  if [ -z "$pinned_cn" ] && [ -n "$recorded_cn" ] && \
    [ "$discovered_cn" != "$recorded_cn" ]; then
    fabric_identity_error 'fabric router certificate name changed.'
    printf '    The endpoint now presents a different name than the applied one.\n' >&2
    printf '    Goat-side operator: confirm the new name through the trusted\n' >&2
    printf '    onboarding channel. Partner: set ZENOH_FABRIC_CERT_CN to the\n' >&2
    printf '    confirmed value in the active profile, then re-run first-boot.\n' >&2
    return 1
  fi
  if [ -z "$pinned_cn" ] && [ -z "$recorded_cn" ]; then
    printf '    fabric certificate name accepted on first use; set\n'
    printf '    ZENOH_FABRIC_CERT_CN in the active profile to pin future runs.\n'
  fi
}

record_applied_fabric_cn() {
  local path="$1" cn="$2" temporary
  safe_certificate_cn "$cn" || return 1
  temporary="$(mktemp "${path}.tmp.XXXXXX")" || return 1
  if ! chmod 600 "$temporary" || ! printf '%s\n' "$cn" >"$temporary" || \
    ! mv "$temporary" "$path"; then
    rm -f "$temporary"
    return 1
  fi
}

parse_fabric_tls_endpoint() {
  local endpoint="$1" address host port
  case "$endpoint" in
    tls/*) address="${endpoint#tls/}" ;;
    *) return 2 ;;
  esac
  address="${address%%\?*}"
  address="${address%%\#*}"
  case "$address" in
    \[*\]:*)
      host="${address#\[}"
      host="${host%%\]*}"
      port="${address##*]:}"
      ;;
    *:*)
      host="${address%:*}"
      port="${address##*:}"
      case "$host" in *:*) return 1;; esac
      ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] && [ -n "$port" ] || return 1
  case "$port" in *[!0-9]*) return 1;; esac
  FABRIC_TLS_ADDRESS="$address"
  FABRIC_TLS_HOST="$host"
}

discover_fabric_certificate_cn() {
  local endpoint="$1" cert="$2" key="$3" ca="$4" wait_seconds="${5:-15}"
  local peer_output discovered
  parse_fabric_tls_endpoint "$endpoint" || return 2
  peer_output="$(
    timeout "$wait_seconds" openssl s_client -showcerts \
      -connect "$FABRIC_TLS_ADDRESS" -servername "$FABRIC_TLS_HOST" \
      -cert "$cert" -key "$key" -CAfile "$ca" -verify_return_error </dev/null 2>&1
  )" || true
  grep -q 'Verify return code: 0 (ok)' <<<"$peer_output" || return 1
  discovered="$(
    printf '%s\n' "$peer_output" \
      | openssl x509 -noout -subject -nameopt sep_multiline 2>/dev/null \
      | sed -n 's/^[[:space:]]*CN[[:space:]]*=[[:space:]]*//p' \
      | head -1
  )" || discovered=""
  unset peer_output
  safe_certificate_cn "$discovered" || return 3
  printf '%s\n' "$discovered"
}

resolve_fabric_certificate_cn() {
  local endpoint="$1" pinned_cn="$2" pod_cn="$3" cert="$4" key="$5" ca="$6"
  local discovered="" discovery_status

  if ! safe_certificate_cn "$pod_cn"; then
    printf 'pod identity check failed: certificate CN is missing or unsupported.\n' >&2
    printf '    Goat-side operator: issue a pod certificate whose CN uses only\n' >&2
    printf '    A-Z, a-z, 0-9, dot, underscore, colon, or hyphen.\n' >&2
    printf '    Partner: install the corrected bundle, then re-run first-boot.\n' >&2
    return 1
  fi
  if [ -n "$pinned_cn" ] && ! safe_certificate_cn "$pinned_cn"; then
    fabric_identity_error 'ZENOH_FABRIC_CERT_CN contains unsupported characters.'
    fabric_operator_next_step
    return 1
  fi

  case "$endpoint" in
    tls/*)
      if ! parse_fabric_tls_endpoint "$endpoint"; then
        fabric_identity_error 'the TLS endpoint has no supported host:port.'
        fabric_operator_next_step
        return 1
      fi
      if discovered="$(discover_fabric_certificate_cn "$endpoint" "$cert" "$key" "$ca")"; then
        :
      else
        discovery_status=$?
        if [ "$discovery_status" -eq 3 ]; then
          fabric_identity_error 'router certificate CN has unsupported characters.'
          fabric_operator_next_step
        else
          fabric_identity_error 'the CA-verified mTLS handshake did not verify.'
          printf '    Partner: confirm the mesh is connected and the endpoint is reachable.\n' >&2
          printf '    If both pass, ask the goat-side operator to confirm the endpoint\n' >&2
          printf '    certificate and CA, then re-run first-boot.\n' >&2
        fi
        return 1
      fi
      if [ -n "$pinned_cn" ] && [ "$pinned_cn" != "$discovered" ]; then
        fabric_identity_error 'router CN does not match the configured pin.'
        fabric_operator_next_step
        return 1
      fi
      FABRIC_ROUTER_CERT_CN="$discovered"
      ;;
    quic/*)
      if [ -z "$pinned_cn" ]; then
        fabric_identity_error 'QUIC endpoint has no router certificate CN pin.'
        printf '    Goat-side operator: provide the expected CN through the trusted\n' >&2
        printf '    onboarding channel. Partner: set ZENOH_FABRIC_CERT_CN in the active\n' >&2
        printf '    profile, then re-run first-boot.\n' >&2
        return 1
      fi
      FABRIC_ROUTER_CERT_CN="$pinned_cn"
      ;;
    *)
      fabric_identity_error 'endpoint transport must be tls or quic.'
      fabric_operator_next_step
      return 1
      ;;
  esac

  if [ "$FABRIC_ROUTER_CERT_CN" = "$pod_cn" ]; then
    fabric_identity_error 'router and pod certificate CNs are identical.'
    printf '    Goat-side operator: issue distinct identities so the ACL can separate\n' >&2
    printf '    their privileges. Partner: install them, then re-run first-boot.\n' >&2
    return 1
  fi
}
