#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

check_dns() {
  local name="${1}"
  local result
  result="$(dig +short A "$name" | tail -n 1)"
  printf '%-28s %s\n' "$name" "${result:-<empty>}"
  if [[ -n "${EXPECTED_IP:-}" && "$result" != "$EXPECTED_IP" ]]; then
    die "$name resolves to ${result:-empty}, expected $EXPECTED_IP"
  fi
}

: "${NETLUMAVPN_DOMAIN:=${QUICKVPN_DOMAIN:-netlumavpn.example}}"
: "${QUICKVPN_DOMAIN:=$NETLUMAVPN_DOMAIN}"
: "${NETLUMAVPN_MOBILE_API_KEY:=${QUICKVPN_MOBILE_API_KEY:-}}"
: "${QUICKVPN_MOBILE_API_KEY:=$NETLUMAVPN_MOBILE_API_KEY}"

require_command curl
require_command dig
require_command openssl

log "Checking DNS"
check_dns "$QUICKVPN_DOMAIN"
check_dns "www.$QUICKVPN_DOMAIN"
check_dns "api.$QUICKVPN_DOMAIN"
check_dns "admin.$QUICKVPN_DOMAIN"
check_dns "vpn.$QUICKVPN_DOMAIN"
check_dns "trojan.$QUICKVPN_DOMAIN"

log "Checking admin HTTPS"
curl -fsSI "https://admin.$QUICKVPN_DOMAIN/login" | sed -n '1,8p'

log "Checking website pages"
for path in / /support /privacy /terms; do
  curl -fsS "https://$QUICKVPN_DOMAIN$path" >/dev/null
  printf '%-28s OK\n' "https://$QUICKVPN_DOMAIN$path"
done

log "Checking API status"
curl -fsS "https://api.$QUICKVPN_DOMAIN/api/v1/status"
printf '\n'

if [[ -n "${QUICKVPN_MOBILE_API_KEY:-}" ]]; then
  log "Checking mobile API"
  curl -fsS "https://api.$QUICKVPN_DOMAIN/api/v1/mobile/servers" \
    -H "X-NetlumaVPN-Client-Key: $QUICKVPN_MOBILE_API_KEY" \
    -H "X-QuickVPN-Client-Key: $QUICKVPN_MOBILE_API_KEY"
  printf '\n'
else
  log "Skipping mobile API auth check because QUICKVPN_MOBILE_API_KEY is not set"
fi

log "Checking TLS certificate names"
echo | openssl s_client -connect "api.$QUICKVPN_DOMAIN:443" -servername "api.$QUICKVPN_DOMAIN" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

log "Fresh server public checks passed"
