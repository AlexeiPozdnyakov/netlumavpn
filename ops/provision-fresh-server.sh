#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

quote_env_value() {
  local value="${1}"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'" "$value"
}

write_env_line() {
  local key="${1}"
  local value="${2}"
  printf "%s=%s\n" "$key" "$(quote_env_value "$value")"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "run this script as root on the VPS"
  fi
}

require_file() {
  local path="${1}"
  [[ -e "$path" ]] || die "missing required file: $path"
}

load_existing_env() {
  local env_path="/etc/quickvpn/quickvpn.env"
  if [[ -f "$env_path" && "${QUICKVPN_FORCE_REGENERATE:-0}" != "1" ]]; then
    # shellcheck disable=SC1090
    set -a
    . "$env_path"
    set +a
  fi
}

install_ssh_key_if_present() {
  if [[ -z "${PUBKEY_BASE64:-}" ]]; then
    return
  fi

  log "Installing SSH key for root and quickadmin"
  PUBKEY_BASE64="$PUBKEY_BASE64" bash "$OPS_SRC/bootstrap-quickvpn-ssh.sh" >/dev/null
  chmod 600 /root/quickvpn-ssh-credentials.txt
}

install_packages() {
  log "Installing Ubuntu packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates \
    certbot \
    curl \
    fail2ban \
    iproute2 \
    iptables \
    libnginx-mod-stream \
    nginx \
    openssl \
    python3 \
    python3-pip \
    python3-venv \
    rsync \
    sqlite3 \
    sudo \
    ufw \
    unzip \
    wireguard-tools
}

install_xray() {
  if [[ -x /usr/local/bin/xray ]]; then
    log "Xray already installed"
    return
  fi

  log "Installing Xray-core"
  curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install-release.sh
  bash /tmp/xray-install-release.sh install
}

create_users_and_dirs() {
  log "Creating QuickVPN users and directories"
  if ! getent group quickvpn >/dev/null 2>&1; then
    groupadd --system quickvpn
  fi
  if ! id quickvpn >/dev/null 2>&1; then
    useradd --system --gid quickvpn --home-dir /opt/quickvpn --shell /usr/sbin/nologin quickvpn
  fi

  install -d -m 755 /opt/quickvpn
  install -d -m 755 -o quickvpn -g quickvpn /opt/quickvpn/app
  install -d -m 750 -o quickvpn -g quickvpn /opt/quickvpn/data
  install -d -m 750 /etc/quickvpn
  install -d -m 755 /usr/local/etc/xray
  install -d -m 750 /etc/xray/certs
  install -d -m 755 /var/log/xray
  install -d -m 755 /var/www/letsencrypt
  install -d -m 755 /etc/nginx/stream.d
  install -d -m 755 /etc/wireguard

  touch /var/log/xray/access.log /var/log/xray/error.log
  chown -R quickvpn:quickvpn /opt/quickvpn /usr/local/etc/xray
  chown quickvpn:quickvpn /etc/wireguard
  if id nobody >/dev/null 2>&1; then
    chown root:"$(id -gn nobody)" /etc/xray/certs
    chown -R "nobody:$(id -gn nobody)" /var/log/xray
  fi
}

deploy_app_files() {
  log "Deploying FastAPI app"
  require_file "$APP_SRC/app.py"
  require_file "$APP_SRC/requirements.txt"

  rsync -a --delete "$APP_SRC/" /opt/quickvpn/app/
  chown -R quickvpn:quickvpn /opt/quickvpn/app

  python3 -m venv /opt/quickvpn/venv
  /opt/quickvpn/venv/bin/pip install --upgrade pip
  /opt/quickvpn/venv/bin/pip install -r /opt/quickvpn/app/requirements.txt
}

generate_reality_keys() {
  local output
  output="$(/usr/local/bin/xray x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$output" | awk -F': ' '/Private key:/ {print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$output" | awk -F': ' '/Public key:/ {print $2}')"
  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "failed to generate Reality key pair"
}

generate_wireguard_keys() {
  WIREGUARD_SERVER_PRIVATE_KEY="$(wg genkey)"
  WIREGUARD_SERVER_PUBLIC_KEY="$(printf '%s\n' "$WIREGUARD_SERVER_PRIVATE_KEY" | wg pubkey)"
}

prepare_secrets() {
  log "Preparing server secrets"
  load_existing_env

  : "${NETLUMAVPN_DOMAIN:=${QUICKVPN_DOMAIN:-netlumavpn.example}}"
  : "${QUICKVPN_DOMAIN:=$NETLUMAVPN_DOMAIN}"
  : "${NETLUMAVPN_ADMIN_USER:=${QUICKVPN_ADMIN_USER:-admin}}"
  : "${QUICKVPN_ADMIN_USER:=$NETLUMAVPN_ADMIN_USER}"
  : "${NETLUMAVPN_PUBLIC_IP:=${QUICKVPN_PUBLIC_IP:-$(curl -fsS https://api.ipify.org || hostname -I | awk '{print $1}')}}"
  : "${QUICKVPN_PUBLIC_IP:=$NETLUMAVPN_PUBLIC_IP}"
  : "${NETLUMAVPN_MOBILE_API_KEY:=${QUICKVPN_MOBILE_API_KEY:-${MOBILE_API_KEY:-}}}"
  : "${QUICKVPN_MOBILE_API_KEY:=$NETLUMAVPN_MOBILE_API_KEY}"
  : "${NETLUMAVPN_APP_STORE_URL:=${APP_STORE_URL:-https://apps.apple.com/search?term=NetlumaVPN}}"
  : "${QUICKVPN_ADMIN_PASSWORD:=${NETLUMAVPN_ADMIN_PASSWORD:-}}"
  : "${QUICKVPN_ADMIN_API_KEY:=${NETLUMAVPN_ADMIN_API_KEY:-}}"
  : "${QUICKVPN_CERTBOT_EMAIL:=${NETLUMAVPN_CERTBOT_EMAIL:-}}"
  : "${QUICKVPN_FORCE_REGENERATE:=${NETLUMAVPN_FORCE_REGENERATE:-}}"

  [[ -n "$QUICKVPN_MOBILE_API_KEY" ]] || die "QUICKVPN_MOBILE_API_KEY is required; use the value embedded in AppConstants.Backend.mobileClientKey unless you are shipping a rotated app build"

  ADMIN_USER="${ADMIN_USER:-$QUICKVPN_ADMIN_USER}"
  ADMIN_PASSWORD="${QUICKVPN_ADMIN_PASSWORD:-}"
  if [[ -z "${ADMIN_PASSWORD_HASH:-}" || -n "${QUICKVPN_ADMIN_PASSWORD:-}" || "${QUICKVPN_FORCE_REGENERATE:-0}" == "1" ]]; then
    ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -base64 24)}"
    ADMIN_PASSWORD_HASH="$(/opt/quickvpn/venv/bin/python /opt/quickvpn/app/app.py hash-password "$ADMIN_PASSWORD")"
  else
    ADMIN_PASSWORD="<unchanged; see the previous /root/quickvpn-app-credentials.txt>"
  fi

  SESSION_SECRET="${SESSION_SECRET:-$(openssl rand -hex 32)}"
  API_KEY="${QUICKVPN_ADMIN_API_KEY:-${API_KEY:-$(openssl rand -hex 32)}}"
  MOBILE_API_KEY="$QUICKVPN_MOBILE_API_KEY"
  APP_STORE_URL="$NETLUMAVPN_APP_STORE_URL"

  VPN_HOST="${VPN_HOST:-vpn.$QUICKVPN_DOMAIN}"
  VPN_PORT="${VPN_PORT:-443}"
  XRAY_LISTEN_HOST="${XRAY_LISTEN_HOST:-127.0.0.1}"
  XRAY_LISTEN_PORT="${XRAY_LISTEN_PORT:-1443}"

  TROJAN_HOST="${TROJAN_HOST:-trojan.$QUICKVPN_DOMAIN}"
  TROJAN_LISTEN_HOST="${TROJAN_LISTEN_HOST:-127.0.0.1}"
  TROJAN_LISTEN_PORT="${TROJAN_LISTEN_PORT:-2443}"
  TROJAN_CERT_FILE="${TROJAN_CERT_FILE:-/etc/xray/certs/api.$QUICKVPN_DOMAIN.fullchain.pem}"
  TROJAN_KEY_FILE="${TROJAN_KEY_FILE:-/etc/xray/certs/api.$QUICKVPN_DOMAIN.privkey.pem}"
  TROJAN_FINGERPRINT="${TROJAN_FINGERPRINT:-chrome}"

  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" || "${QUICKVPN_FORCE_REGENERATE:-0}" == "1" ]]; then
    generate_reality_keys
  fi
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(openssl rand -hex 8)}"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.microsoft.com}"
  REALITY_DEST="${REALITY_DEST:-$REALITY_SERVER_NAME:443}"
  REALITY_FINGERPRINT="${REALITY_FINGERPRINT:-chrome}"
  REALITY_SPIDER_X="${REALITY_SPIDER_X:-/}"
  VLESS_FLOW="${VLESS_FLOW:-}"
  VLESS_COMPATIBILITY_FLOW="${VLESS_COMPATIBILITY_FLOW:-}"

  WIREGUARD_CONFIG_PATH="${WIREGUARD_CONFIG_PATH:-/etc/wireguard/wg0.conf}"
  WIREGUARD_SERVICE="${WIREGUARD_SERVICE:-wg-quick@wg0}"
  WIREGUARD_INTERFACE="${WIREGUARD_INTERFACE:-wg0}"
  WIREGUARD_PORT="${WIREGUARD_PORT:-51820}"
  WIREGUARD_NETWORK="${WIREGUARD_NETWORK:-10.8.0.0/24}"
  WIREGUARD_SERVER_ADDRESS="${WIREGUARD_SERVER_ADDRESS:-10.8.0.1/24}"
  WIREGUARD_ALLOWED_IPS="${WIREGUARD_ALLOWED_IPS:-0.0.0.0/0}"
  WIREGUARD_PERSISTENT_KEEPALIVE="${WIREGUARD_PERSISTENT_KEEPALIVE:-25}"
  WIREGUARD_MTU="${WIREGUARD_MTU:-1280}"
  WIREGUARD_NAT_INTERFACE="${WIREGUARD_NAT_INTERFACE:-$(ip route get 1.1.1.1 | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')}"
  if [[ -z "${WIREGUARD_SERVER_PRIVATE_KEY:-}" || -z "${WIREGUARD_SERVER_PUBLIC_KEY:-}" || "${QUICKVPN_FORCE_REGENERATE:-0}" == "1" ]]; then
    generate_wireguard_keys
  fi
}

write_quickvpn_env() {
  log "Writing /etc/quickvpn/quickvpn.env"
  {
    write_env_line QUICKVPN_DB_PATH "/opt/quickvpn/data/quickvpn.sqlite3"
    write_env_line XRAY_CONFIG_PATH "/usr/local/etc/xray/config.json"
    write_env_line XRAY_BIN "/usr/local/bin/xray"
    write_env_line XRAY_API_SERVER "127.0.0.1:10085"
    write_env_line XRAY_SERVICE "xray"
    write_env_line VPN_HOST "$VPN_HOST"
    write_env_line VPN_PORT "$VPN_PORT"
    write_env_line XRAY_LISTEN_HOST "$XRAY_LISTEN_HOST"
    write_env_line XRAY_LISTEN_PORT "$XRAY_LISTEN_PORT"
    write_env_line TROJAN_HOST "$TROJAN_HOST"
    write_env_line TROJAN_LISTEN_HOST "$TROJAN_LISTEN_HOST"
    write_env_line TROJAN_LISTEN_PORT "$TROJAN_LISTEN_PORT"
    write_env_line TROJAN_CERT_FILE "$TROJAN_CERT_FILE"
    write_env_line TROJAN_KEY_FILE "$TROJAN_KEY_FILE"
    write_env_line TROJAN_FINGERPRINT "$TROJAN_FINGERPRINT"
    write_env_line REALITY_PRIVATE_KEY "$REALITY_PRIVATE_KEY"
    write_env_line REALITY_PUBLIC_KEY "$REALITY_PUBLIC_KEY"
    write_env_line REALITY_SHORT_ID "$REALITY_SHORT_ID"
    write_env_line REALITY_SERVER_NAME "$REALITY_SERVER_NAME"
    write_env_line REALITY_DEST "$REALITY_DEST"
    write_env_line REALITY_FINGERPRINT "$REALITY_FINGERPRINT"
    write_env_line REALITY_SPIDER_X "$REALITY_SPIDER_X"
    write_env_line VLESS_FLOW "$VLESS_FLOW"
    write_env_line VLESS_COMPATIBILITY_FLOW "$VLESS_COMPATIBILITY_FLOW"
    write_env_line ADMIN_USER "$ADMIN_USER"
    write_env_line ADMIN_PASSWORD_HASH "$ADMIN_PASSWORD_HASH"
    write_env_line SESSION_SECRET "$SESSION_SECRET"
    write_env_line API_KEY "$API_KEY"
    write_env_line MOBILE_API_KEY "$MOBILE_API_KEY"
    write_env_line APP_STORE_URL "$APP_STORE_URL"
    write_env_line WG_BIN "/usr/bin/wg"
    write_env_line WIREGUARD_CONFIG_PATH "$WIREGUARD_CONFIG_PATH"
    write_env_line WIREGUARD_SERVICE "$WIREGUARD_SERVICE"
    write_env_line WIREGUARD_INTERFACE "$WIREGUARD_INTERFACE"
    write_env_line WIREGUARD_PORT "$WIREGUARD_PORT"
    write_env_line WIREGUARD_NETWORK "$WIREGUARD_NETWORK"
    write_env_line WIREGUARD_SERVER_ADDRESS "$WIREGUARD_SERVER_ADDRESS"
    write_env_line WIREGUARD_SERVER_PRIVATE_KEY "$WIREGUARD_SERVER_PRIVATE_KEY"
    write_env_line WIREGUARD_SERVER_PUBLIC_KEY "$WIREGUARD_SERVER_PUBLIC_KEY"
    write_env_line WIREGUARD_ALLOWED_IPS "$WIREGUARD_ALLOWED_IPS"
    write_env_line WIREGUARD_PERSISTENT_KEEPALIVE "$WIREGUARD_PERSISTENT_KEEPALIVE"
    write_env_line WIREGUARD_MTU "$WIREGUARD_MTU"
    write_env_line WIREGUARD_NAT_INTERFACE "$WIREGUARD_NAT_INTERFACE"
  } >/etc/quickvpn/quickvpn.env
  chown root:quickvpn /etc/quickvpn/quickvpn.env
  chmod 640 /etc/quickvpn/quickvpn.env
}

write_credentials_file() {
  log "Writing /root/quickvpn-app-credentials.txt"
  cat >/root/quickvpn-app-credentials.txt <<CREDS
DOMAIN=$QUICKVPN_DOMAIN
PUBLIC_IP=$QUICKVPN_PUBLIC_IP
ADMIN_URL=https://admin.$QUICKVPN_DOMAIN/admin
ADMIN_USER=$ADMIN_USER
ADMIN_PASSWORD=$ADMIN_PASSWORD
ADMIN_API_KEY=$API_KEY
MOBILE_API_KEY=$MOBILE_API_KEY
MOBILE_API_BASE_URL=https://api.$QUICKVPN_DOMAIN
VPN_HOST=$VPN_HOST
TROJAN_HOST=$TROJAN_HOST
REALITY_PUBLIC_KEY=$REALITY_PUBLIC_KEY
REALITY_SHORT_ID=$REALITY_SHORT_ID
WIREGUARD_SERVER_PUBLIC_KEY=$WIREGUARD_SERVER_PUBLIC_KEY
CREDS
  chmod 600 /root/quickvpn-app-credentials.txt
}

configure_sudoers() {
  log "Configuring sudo permissions for quickvpn service user"
  cat >/etc/sudoers.d/quickvpn-services <<'SUDOERS'
quickvpn ALL=(root) NOPASSWD: /bin/systemctl restart xray
quickvpn ALL=(root) NOPASSWD: /bin/systemctl restart wg-quick@wg0
quickvpn ALL=(root) NOPASSWD: /bin/systemctl status xray
quickvpn ALL=(root) NOPASSWD: /bin/systemctl status wg-quick@wg0
SUDOERS
  chmod 440 /etc/sudoers.d/quickvpn-services
  visudo -cf /etc/sudoers.d/quickvpn-services >/dev/null
}

ensure_nginx_stream_include() {
  if grep -Rqs "stream.d/.*\\.conf" /etc/nginx/nginx.conf /etc/nginx/conf.d 2>/dev/null; then
    return
  fi

  log "Adding top-level nginx stream include"
  cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.quickvpn.bak
  awk '
    BEGIN { inserted = 0 }
    !inserted && $1 == "events" {
      print "include /etc/nginx/stream.d/*.conf;"
      print ""
      inserted = 1
    }
    { print }
  ' /etc/nginx/nginx.conf.quickvpn.bak >/etc/nginx/nginx.conf
}

write_pre_cert_nginx_config() {
  log "Writing temporary nginx config for ACME"
  rm -f /etc/nginx/sites-enabled/default
  cat >/etc/nginx/conf.d/quickvpn.conf <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $QUICKVPN_DOMAIN www.$QUICKVPN_DOMAIN admin.$QUICKVPN_DOMAIN api.$QUICKVPN_DOMAIN vpn.$QUICKVPN_DOMAIN trojan.$QUICKVPN_DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/letsencrypt;
        default_type text/plain;
    }

    location /api/v1/mobile/ {
        return 404;
    }

    location / {
        return 308 https://\$host\$request_uri;
    }
}
NGINX
  : >/etc/nginx/stream.d/quickvpn-stream.conf
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_letsencrypt_certificate() {
  if [[ "${QUICKVPN_SKIP_LETSENCRYPT:-0}" == "1" ]]; then
    die "QUICKVPN_SKIP_LETSENCRYPT=1 is not supported for final production provisioning; point DNS first, then run again without the flag"
  fi

  log "Issuing Let's Encrypt certificate for root/www/api/admin/trojan"
  local email_args
  if [[ -n "${QUICKVPN_CERTBOT_EMAIL:-}" ]]; then
    email_args=(--email "$QUICKVPN_CERTBOT_EMAIL")
  else
    email_args=(--register-unsafely-without-email)
  fi

  certbot certonly \
    --webroot \
    -w /var/www/letsencrypt \
    --cert-name "api.$QUICKVPN_DOMAIN" \
    --expand \
    --non-interactive \
    --agree-tos \
    "${email_args[@]}" \
    -d "$QUICKVPN_DOMAIN" \
    -d "www.$QUICKVPN_DOMAIN" \
    -d "api.$QUICKVPN_DOMAIN" \
    -d "admin.$QUICKVPN_DOMAIN" \
    -d "trojan.$QUICKVPN_DOMAIN"

  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/reload-quickvpn-nginx.sh <<HOOK
#!/usr/bin/env bash
set -euo pipefail

install -d -m 750 /etc/xray/certs
cp /etc/letsencrypt/live/api.$QUICKVPN_DOMAIN/fullchain.pem "$TROJAN_CERT_FILE"
cp /etc/letsencrypt/live/api.$QUICKVPN_DOMAIN/privkey.pem "$TROJAN_KEY_FILE"
if id nobody >/dev/null 2>&1; then
  chown root:"\$(id -gn nobody)" /etc/xray/certs
  chown root:"\$(id -gn nobody)" "$TROJAN_CERT_FILE" "$TROJAN_KEY_FILE"
else
  chown root:root "$TROJAN_CERT_FILE" "$TROJAN_KEY_FILE"
fi
chmod 644 "$TROJAN_CERT_FILE"
chmod 640 "$TROJAN_KEY_FILE"

nginx -t
systemctl reload nginx
systemctl try-restart xray
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-quickvpn-nginx.sh
  /etc/letsencrypt/renewal-hooks/deploy/reload-quickvpn-nginx.sh
}

render_domain_config() {
  local source_path="${1}"
  local destination_path="${2}"
  sed "s/netlumavpn\\.net/${QUICKVPN_DOMAIN//./\\.}/g" "$source_path" >"$destination_path"
}

configure_nginx() {
  log "Installing final nginx configs"
  require_file "$OPS_SRC/nginx/quickvpn.conf"
  require_file "$OPS_SRC/nginx/quickvpn-stream.conf"
  ensure_nginx_stream_include
  render_domain_config "$OPS_SRC/nginx/quickvpn.conf" /etc/nginx/conf.d/quickvpn.conf
  render_domain_config "$OPS_SRC/nginx/quickvpn-stream.conf" /etc/nginx/stream.d/quickvpn-stream.conf
  nginx -t
  systemctl reload nginx
}

configure_systemd_and_fail2ban() {
  log "Installing systemd units and fail2ban jail"
  cp "$OPS_SRC/systemd/quickvpn-api.service" /etc/systemd/system/quickvpn-api.service
  cp "$OPS_SRC/systemd/quickvpn-stats.service" /etc/systemd/system/quickvpn-stats.service
  cp "$OPS_SRC/systemd/quickvpn-stats.timer" /etc/systemd/system/quickvpn-stats.timer
  cp "$OPS_SRC/fail2ban/sshd.local" /etc/fail2ban/jail.d/sshd.local

  systemctl daemon-reload
  systemctl enable fail2ban
  systemctl restart fail2ban
}

configure_firewall_and_kernel() {
  log "Configuring firewall and IPv4 forwarding"
  cat >/etc/sysctl.d/99-quickvpn.conf <<'SYSCTL'
net.ipv4.ip_forward=1
SYSCTL
  sysctl --system >/dev/null

  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow 51820/udp
  ufw --force enable
}

run_app_command_with_env() {
  local command="${1}"
  runuser -u quickvpn -- /bin/bash -lc "set -a; . /etc/quickvpn/quickvpn.env; set +a; /opt/quickvpn/venv/bin/python /opt/quickvpn/app/app.py $command"
}

render_runtime_configs() {
  log "Rendering initial Xray and WireGuard configs"
  run_app_command_with_env render-xray
  run_app_command_with_env render-wireguard
  chown -R quickvpn:quickvpn /opt/quickvpn/data /usr/local/etc/xray
  chmod 600 /etc/wireguard/wg0.conf
}

start_services() {
  log "Starting services"
  systemctl enable xray
  systemctl restart xray
  systemctl enable wg-quick@wg0
  systemctl restart wg-quick@wg0
  systemctl enable quickvpn-api
  systemctl restart quickvpn-api
  systemctl enable quickvpn-stats.timer
  systemctl restart quickvpn-stats.timer
}

print_summary() {
  log "Provisioning complete"
  cat <<SUMMARY
Credentials are saved on the VPS:
  /root/quickvpn-app-credentials.txt

Primary checks:
  systemctl status xray quickvpn-api quickvpn-stats.timer nginx fail2ban --no-pager
  curl https://api.$QUICKVPN_DOMAIN/api/v1/mobile/servers -H 'X-NetlumaVPN-Client-Key: <MOBILE_API_KEY>'
  curl -I https://admin.$QUICKVPN_DOMAIN/login
SUMMARY
}

main() {
  require_root
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  OPS_SRC="${OPS_SRC:-$SCRIPT_DIR}"
  DEPLOY_ROOT="${QUICKVPN_DEPLOY_ROOT:-$(cd "$OPS_SRC/.." && pwd)}"
  APP_SRC="${APP_SRC:-$DEPLOY_ROOT/archive/server_mvp/quickvpn_admin}"

  require_file "$OPS_SRC/bootstrap-quickvpn-ssh.sh"
  require_file "$OPS_SRC/nginx/quickvpn.conf"
  require_file "$OPS_SRC/nginx/quickvpn-stream.conf"

  install_ssh_key_if_present
  install_packages
  install_xray
  create_users_and_dirs
  deploy_app_files
  prepare_secrets
  write_quickvpn_env
  write_credentials_file
  configure_sudoers
  write_pre_cert_nginx_config
  issue_letsencrypt_certificate
  configure_nginx
  configure_systemd_and_fail2ban
  configure_firewall_and_kernel
  render_runtime_configs
  start_services
  print_summary
}

main "$@"
