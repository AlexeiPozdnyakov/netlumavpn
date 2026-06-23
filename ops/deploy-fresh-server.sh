#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

shell_quote() {
  local value="${1}"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

append_remote_env() {
  local key="${1}"
  local value="${2:-}"
  [[ -n "$value" ]] || return
  REMOTE_ENV+=("$key=$(shell_quote "$value")")
}

require_env() {
  local key="${1}"
  [[ -n "${!key:-}" ]] || die "$key is required"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${NETLUMAVPN_DOMAIN:=${QUICKVPN_DOMAIN:-netlumavpn.example}}"
: "${QUICKVPN_DOMAIN:=$NETLUMAVPN_DOMAIN}"
: "${NETLUMAVPN_MOBILE_API_KEY:=${QUICKVPN_MOBILE_API_KEY:-}}"
: "${QUICKVPN_MOBILE_API_KEY:=$NETLUMAVPN_MOBILE_API_KEY}"
: "${QUICKVPN_ADMIN_USER:=${NETLUMAVPN_ADMIN_USER:-}}"
: "${QUICKVPN_ADMIN_PASSWORD:=${NETLUMAVPN_ADMIN_PASSWORD:-}}"
: "${QUICKVPN_ADMIN_API_KEY:=${NETLUMAVPN_ADMIN_API_KEY:-}}"
: "${QUICKVPN_CERTBOT_EMAIL:=${NETLUMAVPN_CERTBOT_EMAIL:-}}"
: "${QUICKVPN_FORCE_REGENERATE:=${NETLUMAVPN_FORCE_REGENERATE:-}}"
: "${SSH_USER:=root}"
: "${SSH_PORT:=22}"
: "${SSH_KEY:=$HOME/.ssh/quickvpn_vps_ed25519}"
: "${REMOTE_DIR:=/tmp/quickvpn-deploy}"

require_env NEW_SERVER_IP
require_env QUICKVPN_MOBILE_API_KEY

SSH_ARGS=(-p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
if [[ -f "$SSH_KEY" ]]; then
  SSH_ARGS+=(-i "$SSH_KEY")
fi

RSYNC_RSH="ssh"
for arg in "${SSH_ARGS[@]}"; do
  RSYNC_RSH+=" $(shell_quote "$arg")"
done

SSH_TARGET="$SSH_USER@$NEW_SERVER_IP"

PUBKEY_BASE64="${PUBKEY_BASE64:-}"
if [[ -z "$PUBKEY_BASE64" && -f "$SSH_KEY.pub" ]]; then
  PUBKEY_BASE64="$(base64 <"$SSH_KEY.pub" | tr -d '\n')"
fi

log "Copying deploy bundle to $SSH_TARGET:$REMOTE_DIR"
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "mkdir -p $(shell_quote "$REMOTE_DIR")"
rsync -az --delete -e "$RSYNC_RSH" \
  "$REPO_ROOT/archive" \
  "$REPO_ROOT/ops" \
  "$REPO_ROOT/server_mvp" \
  "$SSH_TARGET:$REMOTE_DIR/"

REMOTE_ENV=()
append_remote_env QUICKVPN_DEPLOY_ROOT "$REMOTE_DIR"
append_remote_env QUICKVPN_DOMAIN "$QUICKVPN_DOMAIN"
append_remote_env QUICKVPN_PUBLIC_IP "$NEW_SERVER_IP"
append_remote_env QUICKVPN_MOBILE_API_KEY "$QUICKVPN_MOBILE_API_KEY"
append_remote_env QUICKVPN_ADMIN_USER "${QUICKVPN_ADMIN_USER:-admin}"
append_remote_env QUICKVPN_ADMIN_PASSWORD "${QUICKVPN_ADMIN_PASSWORD:-}"
append_remote_env QUICKVPN_ADMIN_API_KEY "${QUICKVPN_ADMIN_API_KEY:-}"
append_remote_env QUICKVPN_CERTBOT_EMAIL "${QUICKVPN_CERTBOT_EMAIL:-}"
append_remote_env QUICKVPN_FORCE_REGENERATE "${QUICKVPN_FORCE_REGENERATE:-}"
append_remote_env PUBKEY_BASE64 "$PUBKEY_BASE64"

REMOTE_COMMAND=""
for item in "${REMOTE_ENV[@]}"; do
  REMOTE_COMMAND+="$item "
done
REMOTE_COMMAND+="bash $(shell_quote "$REMOTE_DIR/ops/provision-fresh-server.sh")"

log "Running fresh-server provisioner"
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "$REMOTE_COMMAND"

log "Fetching generated credential summary"
ssh "${SSH_ARGS[@]}" "$SSH_TARGET" "sed -n '1,40p' /root/quickvpn-app-credentials.txt"

cat <<NEXT

Next verification from this machine:
  NETLUMAVPN_DOMAIN=$QUICKVPN_DOMAIN \\
  EXPECTED_IP=$NEW_SERVER_IP \\
  NETLUMAVPN_MOBILE_API_KEY='<same mobile key>' \\
  ./ops/verify-fresh-server.sh
NEXT
