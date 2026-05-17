#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${PUBKEY_BASE64:-}" ]]; then
  echo "PUBKEY_BASE64 is required" >&2
  exit 1
fi

PUBKEY="$(printf '%s' "$PUBKEY_BASE64" | base64 -d)"

install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
grep -qxF "$PUBKEY" /root/.ssh/authorized_keys || echo "$PUBKEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

if ! id quickadmin >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo quickadmin
fi

install -d -m 700 -o quickadmin -g quickadmin /home/quickadmin/.ssh
touch /home/quickadmin/.ssh/authorized_keys
grep -qxF "$PUBKEY" /home/quickadmin/.ssh/authorized_keys || echo "$PUBKEY" >> /home/quickadmin/.ssh/authorized_keys
chown quickadmin:quickadmin /home/quickadmin/.ssh/authorized_keys
chmod 600 /home/quickadmin/.ssh/authorized_keys

ROOT_PASS="$(openssl rand -base64 24)"
QUICKADMIN_PASS="$(openssl rand -base64 24)"

echo "root:$ROOT_PASS" | chpasswd
echo "quickadmin:$QUICKADMIN_PASS" | chpasswd

cat >/etc/sudoers.d/quickadmin-xray <<'SUDOERS'
quickadmin ALL=(ALL) NOPASSWD:/bin/systemctl restart xray,/bin/systemctl reload xray,/bin/systemctl status xray,/usr/bin/journalctl
SUDOERS
chmod 440 /etc/sudoers.d/quickadmin-xray

cat >/root/quickvpn-ssh-credentials.txt <<CREDS
ROOT_PASSWORD=$ROOT_PASS
QUICKADMIN_PASSWORD=$QUICKADMIN_PASS
SSH_KEY_USER_LOCAL_PATH=/Users/alexeipozdnyakov/.ssh/quickvpn_vps_ed25519
CREDS
chmod 600 /root/quickvpn-ssh-credentials.txt

cat /root/quickvpn-ssh-credentials.txt
