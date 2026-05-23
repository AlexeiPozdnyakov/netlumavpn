from __future__ import annotations

import base64
import hashlib
import hmac
import html
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import time
import urllib.parse
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse


APP_NAME = "QuickVPN Admin"
UTC = timezone.utc


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


DB_PATH = Path(env("QUICKVPN_DB_PATH", "/opt/quickvpn/data/quickvpn.sqlite3"))
XRAY_CONFIG_PATH = Path(env("XRAY_CONFIG_PATH", "/usr/local/etc/xray/config.json"))
XRAY_BIN = env("XRAY_BIN", "/usr/local/bin/xray")
XRAY_API_SERVER = env("XRAY_API_SERVER", "127.0.0.1:10085")
XRAY_SERVICE = env("XRAY_SERVICE", "xray")
VPN_HOST = env("VPN_HOST", "192.0.2.10")
VPN_PORT = int(env("VPN_PORT", "443"))
XRAY_LISTEN_HOST = env("XRAY_LISTEN_HOST", "0.0.0.0")
XRAY_LISTEN_PORT = int(env("XRAY_LISTEN_PORT", str(VPN_PORT)))
TROJAN_HOST = env("TROJAN_HOST", "trojan.netlumavpn.example")
TROJAN_LISTEN_HOST = env("TROJAN_LISTEN_HOST", "127.0.0.1")
TROJAN_LISTEN_PORT = int(env("TROJAN_LISTEN_PORT", "2443"))
TROJAN_CERT_FILE = env("TROJAN_CERT_FILE", "/etc/xray/certs/api.netlumavpn.example.fullchain.pem")
TROJAN_KEY_FILE = env("TROJAN_KEY_FILE", "/etc/xray/certs/api.netlumavpn.example.privkey.pem")
TROJAN_FINGERPRINT = env("TROJAN_FINGERPRINT", "chrome")
REALITY_PRIVATE_KEY = env("REALITY_PRIVATE_KEY")
REALITY_PUBLIC_KEY = env("REALITY_PUBLIC_KEY")
REALITY_SHORT_ID = env("REALITY_SHORT_ID")
REALITY_SERVER_NAME = env("REALITY_SERVER_NAME", "www.apple.com")
REALITY_DEST = env("REALITY_DEST", f"{REALITY_SERVER_NAME}:443")
REALITY_FINGERPRINT = env("REALITY_FINGERPRINT", "chrome")
REALITY_SPIDER_X = env("REALITY_SPIDER_X", "/")
VLESS_FLOW = env("VLESS_FLOW").strip()
VLESS_COMPATIBILITY_FLOW = env("VLESS_COMPATIBILITY_FLOW").strip()
ADMIN_USER = env("ADMIN_USER", "admin")
ADMIN_PASSWORD_HASH = env("ADMIN_PASSWORD_HASH")
SESSION_SECRET = env("SESSION_SECRET")
API_KEY = env("API_KEY")
MOBILE_API_KEY = env("MOBILE_API_KEY")
WG_BIN = env("WG_BIN", "/usr/bin/wg")
WIREGUARD_CONFIG_PATH = Path(env("WIREGUARD_CONFIG_PATH", "/etc/wireguard/wg0.conf"))
WIREGUARD_SERVICE = env("WIREGUARD_SERVICE", "wg-quick@wg0")
WIREGUARD_INTERFACE = env("WIREGUARD_INTERFACE", "wg0")
WIREGUARD_PORT = int(env("WIREGUARD_PORT", "51820"))
WIREGUARD_NETWORK = env("WIREGUARD_NETWORK", "10.8.0.0/24")
WIREGUARD_SERVER_ADDRESS = env("WIREGUARD_SERVER_ADDRESS", "10.8.0.1/24")
WIREGUARD_SERVER_PRIVATE_KEY = env("WIREGUARD_SERVER_PRIVATE_KEY")
WIREGUARD_SERVER_PUBLIC_KEY = env("WIREGUARD_SERVER_PUBLIC_KEY")
WIREGUARD_ALLOWED_IPS = env("WIREGUARD_ALLOWED_IPS", "0.0.0.0/0")
WIREGUARD_PERSISTENT_KEEPALIVE = int(env("WIREGUARD_PERSISTENT_KEEPALIVE", "25"))
WIREGUARD_MTU = int(env("WIREGUARD_MTU", "1280"))
WIREGUARD_NAT_INTERFACE = env("WIREGUARD_NAT_INTERFACE", "eth0")

VLESS_SERVER_ID = "quickvpn-mvp-eu-1"
TROJAN_SERVER_ID = "quickvpn-mvp-eu-1-trojan"
WIREGUARD_SERVER_ID = "quickvpn-mvp-eu-1-wireguard"
SUPPORTED_PROTOCOLS = {"vless", "trojan", "wireguard"}


app = FastAPI(title=APP_NAME)


def now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def db() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'active',
                created_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS profiles (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL REFERENCES users(id),
                device_name TEXT NOT NULL,
                protocol TEXT NOT NULL DEFAULT 'vless',
                credential_uuid TEXT NOT NULL UNIQUE,
                email TEXT NOT NULL UNIQUE,
                status TEXT NOT NULL DEFAULT 'active',
                vless_url TEXT NOT NULL,
                wireguard_private_key TEXT,
                wireguard_public_key TEXT,
                wireguard_preshared_key TEXT,
                wireguard_address TEXT,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                last_seen_at TEXT,
                created_at TEXT NOT NULL,
                revoked_at TEXT
            );

            CREATE TABLE IF NOT EXISTS traffic_samples (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id TEXT NOT NULL REFERENCES profiles(id),
                upload_delta INTEGER NOT NULL DEFAULT 0,
                download_delta INTEGER NOT NULL DEFAULT 0,
                upload_total INTEGER NOT NULL DEFAULT 0,
                download_total INTEGER NOT NULL DEFAULT 0,
                sampled_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS audit_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                actor TEXT NOT NULL,
                action TEXT NOT NULL,
                target TEXT,
                details TEXT,
                created_at TEXT NOT NULL
            );
            """
        )
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(profiles)").fetchall()}
        migrations = {
            "protocol": "ALTER TABLE profiles ADD COLUMN protocol TEXT NOT NULL DEFAULT 'vless'",
            "wireguard_private_key": "ALTER TABLE profiles ADD COLUMN wireguard_private_key TEXT",
            "wireguard_public_key": "ALTER TABLE profiles ADD COLUMN wireguard_public_key TEXT",
            "wireguard_preshared_key": "ALTER TABLE profiles ADD COLUMN wireguard_preshared_key TEXT",
            "wireguard_address": "ALTER TABLE profiles ADD COLUMN wireguard_address TEXT",
        }
        for column, statement in migrations.items():
            if column not in columns:
                conn.execute(statement)
        conn.execute("UPDATE profiles SET protocol='vless' WHERE protocol IS NULL OR protocol=''")


def audit(actor: str, action: str, target: str = "", details: str = "") -> None:
    with db() as conn:
        conn.execute(
            "INSERT INTO audit_logs(actor, action, target, details, created_at) VALUES (?, ?, ?, ?, ?)",
            (actor, action, target, details, now_iso()),
        )


def password_hash(password: str, salt: str | None = None, iterations: int = 260_000) -> str:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), iterations)
    encoded = base64.urlsafe_b64encode(digest).decode().rstrip("=")
    return f"pbkdf2_sha256${iterations}${salt}${encoded}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        algo, iterations, salt, expected = encoded.split("$", 3)
        if algo != "pbkdf2_sha256":
            return False
        actual = password_hash(password, salt=salt, iterations=int(iterations))
        return hmac.compare_digest(actual, encoded)
    except Exception:
        return False


def sign_session(username: str) -> str:
    expiry = int(time.time()) + 60 * 60 * 12
    payload = f"{username}:{expiry}"
    mac = hmac.new(SESSION_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}:{mac}"


def verify_session(token: str | None) -> bool:
    if not token or not SESSION_SECRET:
        return False
    try:
        username, expiry, mac = token.rsplit(":", 2)
        payload = f"{username}:{expiry}"
        expected = hmac.new(SESSION_SECRET.encode(), payload.encode(), hashlib.sha256).hexdigest()
        return username == ADMIN_USER and int(expiry) > int(time.time()) and hmac.compare_digest(mac, expected)
    except Exception:
        return False


def require_admin(request: Request) -> RedirectResponse | None:
    if verify_session(request.cookies.get("quickvpn_session")):
        return None
    return RedirectResponse("/login", status_code=303)


async def form_data(request: Request) -> dict[str, str]:
    raw = (await request.body()).decode()
    parsed = urllib.parse.parse_qs(raw, keep_blank_values=True)
    return {key: values[-1] for key, values in parsed.items()}


def esc(value: Any) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def fmt_bytes(value: int | None) -> str:
    size = float(value or 0)
    units = ["B", "KB", "MB", "GB", "TB"]
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} TB"


def is_online(last_seen_at: str | None) -> bool:
    if not last_seen_at:
        return False
    try:
        last_seen = datetime.fromisoformat(last_seen_at)
        return (datetime.now(UTC) - last_seen).total_seconds() < 180
    except Exception:
        return False


def page(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <style>
    :root {{ color-scheme: light; --bg:#f6f8fb; --panel:#fff; --line:#dfe6f0; --text:#152033; --muted:#667085; --accent:#2457d6; --bad:#b42318; --good:#067647; }}
    * {{ box-sizing:border-box; }}
    body {{ margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); }}
    header {{ background:#102a63; color:white; padding:18px 28px; display:flex; align-items:center; justify-content:space-between; }}
    header a {{ color:white; text-decoration:none; opacity:.9; margin-left:16px; }}
    main {{ max-width:1180px; margin:26px auto; padding:0 18px 40px; }}
    h1 {{ font-size:26px; margin:0 0 18px; }}
    h2 {{ font-size:18px; margin:0 0 14px; }}
    .grid {{ display:grid; gap:14px; grid-template-columns:repeat(4,minmax(0,1fr)); }}
    .panel {{ background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:18px; margin-bottom:16px; box-shadow:0 8px 18px rgba(16,42,99,.05); }}
    .metric {{ font-size:28px; font-weight:700; }}
    .muted {{ color:var(--muted); }}
    table {{ width:100%; border-collapse:collapse; font-size:14px; }}
    th, td {{ text-align:left; border-bottom:1px solid var(--line); padding:10px 8px; vertical-align:top; }}
    th {{ color:var(--muted); font-weight:600; }}
    input, select {{ width:100%; border:1px solid var(--line); border-radius:6px; padding:10px 12px; font-size:14px; background:white; }}
    textarea {{ width:100%; min-height:120px; border:1px solid var(--line); border-radius:6px; padding:10px 12px; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; }}
    label {{ display:block; font-size:13px; color:var(--muted); margin:0 0 6px; }}
    button, .button {{ border:0; border-radius:6px; padding:10px 14px; background:var(--accent); color:white; font-weight:700; cursor:pointer; text-decoration:none; display:inline-block; }}
    button.danger {{ background:var(--bad); }}
    button.secondary, .button.secondary {{ background:#eef2f7; color:var(--text); }}
    .row {{ display:grid; grid-template-columns:1fr 1fr 1fr auto; gap:12px; align-items:end; }}
    .badge {{ display:inline-flex; align-items:center; border-radius:999px; padding:3px 9px; font-size:12px; font-weight:700; background:#eef2f7; color:var(--muted); }}
    .badge.good {{ background:#dcfae6; color:var(--good); }}
    .badge.bad {{ background:#fee4e2; color:var(--bad); }}
    .actions {{ display:flex; gap:8px; flex-wrap:wrap; }}
    @media (max-width: 860px) {{ .grid, .row {{ grid-template-columns:1fr; }} header {{ display:block; }} header nav {{ margin-top:10px; }} }}
  </style>
</head>
<body>
  <header>
    <strong>QuickVPN Admin</strong>
    <nav><a href="/admin">Dashboard</a><a href="/api/v1/status">API status</a><a href="/logout">Logout</a></nav>
  </header>
  <main>{body}</main>
</body>
</html>"""


def login_page(error: str = "") -> str:
    message = f"<p class='muted'>{esc(error)}</p>" if error else ""
    body = f"""
    <div class="panel" style="max-width:420px;margin:70px auto;">
      <h1>QuickVPN Admin</h1>
      {message}
      <form method="post" action="/login">
        <p><label>Username</label><input name="username" autocomplete="username"></p>
        <p><label>Password</label><input name="password" type="password" autocomplete="current-password"></p>
        <button type="submit">Sign in</button>
      </form>
    </div>
    """
    return page("Login", body)


def build_vless_url(profile_uuid: str, label: str) -> str:
    query = {
        "security": "reality",
        "encryption": "none",
        "pbk": REALITY_PUBLIC_KEY,
        "fp": REALITY_FINGERPRINT,
        "type": "tcp",
        "sni": REALITY_SERVER_NAME,
        "sid": REALITY_SHORT_ID,
        "spx": REALITY_SPIDER_X,
    }
    if VLESS_FLOW:
        query["flow"] = VLESS_FLOW
    return (
        f"vless://{profile_uuid}@{VPN_HOST}:{VPN_PORT}/?"
        + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
        + "#"
        + urllib.parse.quote(label)
    )


def build_trojan_url(password: str, label: str) -> str:
    query = {
        "security": "tls",
        "type": "tcp",
        "sni": TROJAN_HOST,
        "fp": TROJAN_FINGERPRINT,
    }
    return (
        f"trojan://{urllib.parse.quote(password, safe='')}@{TROJAN_HOST}:443/?"
        + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
        + "#"
        + urllib.parse.quote(label)
    )


def build_wireguard_url(private_key: str, preshared_key: str | None, address: str, label: str) -> str:
    if not WIREGUARD_SERVER_PUBLIC_KEY:
        raise RuntimeError("WIREGUARD_SERVER_PUBLIC_KEY is not configured")
    query = {
        "privatekey": private_key,
        "publickey": WIREGUARD_SERVER_PUBLIC_KEY,
        "address": address,
        "allowedips": WIREGUARD_ALLOWED_IPS,
        "persistentkeepalive": str(WIREGUARD_PERSISTENT_KEEPALIVE),
        "mtu": str(WIREGUARD_MTU),
    }
    if preshared_key:
        query["presharedkey"] = preshared_key
    return (
        f"wireguard://{VPN_HOST}:{WIREGUARD_PORT}/?"
        + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
        + "#"
        + urllib.parse.quote(label)
    )


def build_profile_url(row: sqlite3.Row, label: str) -> str:
    protocol = str(row["protocol"] or "vless").lower()
    if protocol == "vless":
        return build_vless_url(row["credential_uuid"], label)
    if protocol == "trojan":
        return build_trojan_url(row["credential_uuid"], label)
    if protocol == "wireguard":
        return build_wireguard_url(
            row["wireguard_private_key"],
            row["wireguard_preshared_key"],
            row["wireguard_address"],
            label,
        )
    raise ValueError(f"unsupported protocol: {protocol}")


def protocol_for_server_id(server_id: str) -> str | None:
    return {
        VLESS_SERVER_ID: "vless",
        TROJAN_SERVER_ID: "trojan",
        WIREGUARD_SERVER_ID: "wireguard",
    }.get(server_id)


def sync_profile_urls() -> int:
    updated = 0
    with db() as conn:
        rows = conn.execute(
            """
            SELECT profiles.*, users.name AS user_name
            FROM profiles
            JOIN users ON users.id = profiles.user_id
            """
        ).fetchall()
        for row in rows:
            try:
                expected_url = build_profile_url(row, f"{row['user_name']} - {row['device_name']}")
            except RuntimeError:
                continue
            if row["vless_url"] == expected_url:
                continue
            conn.execute("UPDATE profiles SET vless_url=? WHERE id=?", (expected_url, row["id"]))
            updated += 1
    if updated:
        audit("system", "profile.urls.sync", details=f"updated={updated}")
    return updated


def render_xray_config() -> dict[str, Any]:
    with db() as conn:
        rows = conn.execute("SELECT * FROM profiles WHERE status='active' ORDER BY created_at").fetchall()
    vless_clients = []
    trojan_clients = []
    for row in rows:
        protocol = str(row["protocol"] or "vless").lower()
        if protocol == "trojan":
            trojan_clients.append(
                {
                    "password": row["credential_uuid"],
                    "email": row["email"],
                    "level": 0,
                }
            )
            continue
        if protocol != "vless":
            continue
        client = {
            "id": row["credential_uuid"],
            "email": row["email"],
            "level": 0,
        }
        if VLESS_FLOW:
            client["flow"] = VLESS_FLOW
        vless_clients.append(client)
        if VLESS_COMPATIBILITY_FLOW and VLESS_COMPATIBILITY_FLOW != VLESS_FLOW:
            vless_clients.append(
                {
                    "id": row["credential_uuid"],
                    "flow": VLESS_COMPATIBILITY_FLOW,
                    "email": f"vision-{row['email']}",
                    "level": 0,
                }
            )
    return {
        "log": {
            "access": "/var/log/xray/access.log",
            "error": "/var/log/xray/error.log",
            "loglevel": "warning",
        },
        "api": {"tag": "api", "services": ["StatsService"]},
        "stats": {},
        "policy": {
            "levels": {"0": {"statsUserUplink": True, "statsUserDownlink": True}},
            "system": {"statsInboundUplink": True, "statsInboundDownlink": True},
        },
        "inbounds": [
            {
                "tag": "api",
                "listen": "127.0.0.1",
                "port": 10085,
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"},
            },
            {
                "tag": "vless-reality",
                "listen": XRAY_LISTEN_HOST,
                "port": XRAY_LISTEN_PORT,
                "protocol": "vless",
                "settings": {"clients": vless_clients, "decryption": "none"},
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "show": False,
                        "dest": REALITY_DEST,
                        "xver": 0,
                        "serverNames": [REALITY_SERVER_NAME],
                        "privateKey": REALITY_PRIVATE_KEY,
                        "shortIds": [REALITY_SHORT_ID],
                    },
                },
            },
            {
                "tag": "trojan-tls",
                "listen": TROJAN_LISTEN_HOST,
                "port": TROJAN_LISTEN_PORT,
                "protocol": "trojan",
                "settings": {"clients": trojan_clients},
                "streamSettings": {
                    "network": "tcp",
                    "security": "tls",
                    "tlsSettings": {
                        "certificates": [
                            {
                                "certificateFile": TROJAN_CERT_FILE,
                                "keyFile": TROJAN_KEY_FILE,
                            }
                        ]
                    },
                },
            },
        ],
        "outbounds": [
            {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}},
            {"protocol": "blackhole", "tag": "blocked"},
        ],
        "routing": {
            "rules": [{"type": "field", "inboundTag": ["api"], "outboundTag": "api"}]
        },
    }


def wg_run(args: list[str], input_text: str | None = None) -> str:
    result = subprocess.run(
        [WG_BIN, *args],
        input=input_text,
        check=True,
        capture_output=True,
        text=True,
        timeout=8,
    )
    return result.stdout.strip()


def generate_wireguard_key_pair() -> tuple[str, str]:
    private_key = wg_run(["genkey"])
    public_key = wg_run(["pubkey"], f"{private_key}\n")
    return private_key, public_key


def generate_wireguard_preshared_key() -> str:
    return wg_run(["genpsk"])


def next_wireguard_address(conn: sqlite3.Connection) -> str:
    network = ipaddress.ip_network(WIREGUARD_NETWORK, strict=False)
    server_ip = ipaddress.ip_interface(WIREGUARD_SERVER_ADDRESS).ip
    used_ips = {server_ip}
    rows = conn.execute(
        """
        SELECT wireguard_address
        FROM profiles
        WHERE protocol='wireguard' AND wireguard_address IS NOT NULL
        """
    ).fetchall()
    for row in rows:
        try:
            used_ips.add(ipaddress.ip_interface(row["wireguard_address"]).ip)
        except ValueError:
            continue
    for candidate in network.hosts():
        if candidate not in used_ips:
            return f"{candidate}/32"
    raise RuntimeError(f"WireGuard network {WIREGUARD_NETWORK} has no free addresses")


def render_wireguard_config() -> str:
    if not WIREGUARD_SERVER_PRIVATE_KEY:
        raise RuntimeError("WIREGUARD_SERVER_PRIVATE_KEY is not configured")
    with db() as conn:
        rows = conn.execute(
            """
            SELECT *
            FROM profiles
            WHERE protocol='wireguard' AND status='active'
            ORDER BY created_at
            """
        ).fetchall()

    lines = [
        "[Interface]",
        f"PrivateKey = {WIREGUARD_SERVER_PRIVATE_KEY}",
        f"Address = {WIREGUARD_SERVER_ADDRESS}",
        f"ListenPort = {WIREGUARD_PORT}",
        f"MTU = {WIREGUARD_MTU}",
        (
            "PostUp = iptables -A FORWARD -i %i -j ACCEPT; "
            "iptables -A FORWARD -o %i -j ACCEPT; "
            f"iptables -t nat -A POSTROUTING -s {WIREGUARD_NETWORK} -o {WIREGUARD_NAT_INTERFACE} -j MASQUERADE"
        ),
        (
            "PostDown = iptables -D FORWARD -i %i -j ACCEPT; "
            "iptables -D FORWARD -o %i -j ACCEPT; "
            f"iptables -t nat -D POSTROUTING -s {WIREGUARD_NETWORK} -o {WIREGUARD_NAT_INTERFACE} -j MASQUERADE || true"
        ),
        "",
    ]
    for row in rows:
        lines.extend(
            [
                "[Peer]",
                f"# {row['email']}",
                f"PublicKey = {row['wireguard_public_key']}",
                f"PresharedKey = {row['wireguard_preshared_key']}",
                f"AllowedIPs = {row['wireguard_address']}",
                "",
            ]
        )
    return "\n".join(lines).rstrip() + "\n"


def write_wireguard_config() -> bool:
    if not WIREGUARD_SERVER_PRIVATE_KEY or not WIREGUARD_SERVER_PUBLIC_KEY:
        return False
    WIREGUARD_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = WIREGUARD_CONFIG_PATH.with_name(f"{WIREGUARD_CONFIG_PATH.name}.tmp")
    tmp_path.write_text(render_wireguard_config(), encoding="utf-8")
    os.chmod(tmp_path, 0o600)
    tmp_path.replace(WIREGUARD_CONFIG_PATH)
    return True


def write_xray_config() -> None:
    XRAY_CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = XRAY_CONFIG_PATH.with_name(f"{XRAY_CONFIG_PATH.name}.tmp.json")
    tmp_path.write_text(json.dumps(render_xray_config(), indent=2, sort_keys=True), encoding="utf-8")
    result = subprocess.run(
        [XRAY_BIN, "run", "-test", "-format", "json", "-config", str(tmp_path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 23):
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    tmp_path.replace(XRAY_CONFIG_PATH)


def restart_xray() -> None:
    write_xray_config()
    subprocess.run(["sudo", "/bin/systemctl", "restart", XRAY_SERVICE], check=True, capture_output=True, text=True)
    if write_wireguard_config():
        subprocess.run(
            ["sudo", "/bin/systemctl", "restart", WIREGUARD_SERVICE],
            check=True,
            capture_output=True,
            text=True,
        )


def create_profile(user_name: str, device_name: str, actor: str, protocol: str = "vless") -> sqlite3.Row:
    user_name = user_name.strip() or "MVP User"
    device_name = device_name.strip() or "iPhone"
    protocol = (protocol or "vless").strip().lower()
    if protocol not in SUPPORTED_PROTOCOLS:
        raise ValueError("unsupported protocol")
    profile_id = str(uuid.uuid4())
    user_id = str(uuid.uuid4())
    credential = secrets.token_urlsafe(24) if protocol == "trojan" else str(uuid.uuid4())
    email = f"{profile_id}@quickvpn"
    label = f"{user_name} - {device_name}"
    wireguard_private_key: str | None = None
    wireguard_public_key: str | None = None
    wireguard_preshared_key: str | None = None
    wireguard_address: str | None = None
    if protocol == "vless":
        config_url = build_vless_url(credential, label)
    elif protocol == "trojan":
        config_url = build_trojan_url(credential, label)
    else:
        wireguard_private_key, wireguard_public_key = generate_wireguard_key_pair()
        wireguard_preshared_key = generate_wireguard_preshared_key()
        config_url = ""
    created_at = now_iso()
    with db() as conn:
        if protocol == "wireguard":
            wireguard_address = next_wireguard_address(conn)
            config_url = build_wireguard_url(
                wireguard_private_key or "",
                wireguard_preshared_key,
                wireguard_address,
                label,
            )
        conn.execute(
            "INSERT INTO users(id, name, status, created_at) VALUES (?, ?, 'active', ?)",
            (user_id, user_name, created_at),
        )
        conn.execute(
            """
            INSERT INTO profiles(
                id,
                user_id,
                device_name,
                protocol,
                credential_uuid,
                email,
                status,
                vless_url,
                wireguard_private_key,
                wireguard_public_key,
                wireguard_preshared_key,
                wireguard_address,
                created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
            """,
            (
                profile_id,
                user_id,
                device_name,
                protocol,
                credential,
                email,
                config_url,
                wireguard_private_key,
                wireguard_public_key,
                wireguard_preshared_key,
                wireguard_address,
                created_at,
            ),
        )
        row = conn.execute("SELECT * FROM profiles WHERE id=?", (profile_id,)).fetchone()
    restart_xray()
    audit(actor, "profile.create", profile_id, f"user={user_name}; device={device_name}; protocol={protocol}")
    return row


def available_mobile_servers() -> list[dict[str, Any]]:
    base = {
        "name": "QuickVPN Global",
        "country": "Germany",
        "city": "Nuremberg",
        "region": "Europe",
        "is_available": True,
        "ip_mode": "ipv4_only",
    }
    return [
        {**base, "id": VLESS_SERVER_ID, "protocol": "VLESS Reality"},
        {**base, "id": TROJAN_SERVER_ID, "protocol": "Trojan TLS"},
        {**base, "id": WIREGUARD_SERVER_ID, "protocol": "WireGuard"},
    ]


def normalized_device_key(server_id: str, device_id: str) -> str:
    digest = hashlib.sha256(f"{server_id}:{device_id}".encode()).hexdigest()
    return f"mobile:{server_id}:{digest[:24]}"


def issue_mobile_profile(server_id: str, device_id: str, device_name: str) -> sqlite3.Row:
    protocol = protocol_for_server_id(server_id)
    if protocol is None:
        raise ValueError("unknown server")

    device_key = normalized_device_key(server_id, device_id)
    with db() as conn:
        existing = conn.execute(
            "SELECT * FROM profiles WHERE device_name=? AND status='active' ORDER BY created_at DESC LIMIT 1",
            (device_key,),
        ).fetchone()
        if existing:
            audit("mobile", "profile.reuse", existing["id"], f"server={server_id}")
            return existing

    return create_profile(
        user_name=f"Mobile {hashlib.sha256(device_id.encode()).hexdigest()[:8]}",
        device_name=device_key,
        actor="mobile",
        protocol=protocol,
    )


def set_profile_status(profile_id: str, status: str, actor: str) -> None:
    revoked_at = now_iso() if status == "revoked" else None
    with db() as conn:
        conn.execute(
            "UPDATE profiles SET status=?, revoked_at=? WHERE id=?",
            (status, revoked_at, profile_id),
        )
    restart_xray()
    audit(actor, f"profile.{status}", profile_id)


def delete_profile(profile_id: str, actor: str) -> bool:
    with db() as conn:
        row = conn.execute("SELECT * FROM profiles WHERE id=?", (profile_id,)).fetchone()
        if not row:
            return False
        user_id = row["user_id"]
        conn.execute("DELETE FROM traffic_samples WHERE profile_id=?", (profile_id,))
        conn.execute("DELETE FROM profiles WHERE id=?", (profile_id,))
        remaining = conn.execute("SELECT COUNT(*) FROM profiles WHERE user_id=?", (user_id,)).fetchone()[0]
        if remaining == 0:
            conn.execute("DELETE FROM users WHERE id=?", (user_id,))
    restart_xray()
    audit(actor, "profile.delete", profile_id)
    return True


def collect_stats() -> dict[str, Any]:
    cmd = [
        XRAY_BIN,
        "api",
        "statsquery",
        f"--server={XRAY_API_SERVER}",
        "-pattern",
        "user>>>",
        "-reset",
    ]
    result = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=8)
    if result.returncode != 0:
        return {"ok": False, "error": result.stderr.strip() or result.stdout.strip()}

    stats: dict[str, dict[str, int]] = {}
    matches = re.findall(r'name:\\s*"([^"]+)".*?value:\\s*(\\d+)', result.stdout, flags=re.S)
    for name, value in matches:
        parts = name.split(">>>")
        if len(parts) < 4 or parts[0] != "user":
            continue
        email = parts[1]
        direction = parts[-1]
        stats.setdefault(email, {"uplink": 0, "downlink": 0})
        stats[email][direction] = int(value)

    sampled_at = now_iso()
    updated = 0
    with db() as conn:
        for email, values in stats.items():
            up = values.get("uplink", 0)
            down = values.get("downlink", 0)
            row = conn.execute("SELECT * FROM profiles WHERE email=?", (email,)).fetchone()
            if not row and email.startswith("vision-"):
                row = conn.execute("SELECT * FROM profiles WHERE email=?", (email.removeprefix("vision-"),)).fetchone()
            if not row:
                continue
            last_seen = sampled_at if up > 0 or down > 0 else row["last_seen_at"]
            upload_total = int(row["upload_bytes"]) + up
            download_total = int(row["download_bytes"]) + down
            conn.execute(
                """
                UPDATE profiles
                SET upload_bytes=?, download_bytes=?, last_seen_at=?
                WHERE id=?
                """,
                (upload_total, download_total, last_seen, row["id"]),
            )
            conn.execute(
                """
                INSERT INTO traffic_samples(profile_id, upload_delta, download_delta, upload_total, download_total, sampled_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (row["id"], up, down, upload_total, download_total, sampled_at),
            )
            updated += 1
    return {"ok": True, "updated": updated, "raw": result.stdout}


def dashboard_html() -> str:
    stats = collect_stats()
    with db() as conn:
        profiles = conn.execute(
            """
            SELECT profiles.*, users.name AS user_name
            FROM profiles
            JOIN users ON users.id = profiles.user_id
            ORDER BY profiles.created_at DESC
            """
        ).fetchall()
        totals = conn.execute(
            """
            SELECT
              COUNT(*) AS total_profiles,
              SUM(CASE WHEN status='active' THEN 1 ELSE 0 END) AS active_profiles,
              COALESCE(SUM(upload_bytes), 0) AS upload_bytes,
              COALESCE(SUM(download_bytes), 0) AS download_bytes
            FROM profiles
            """
        ).fetchone()
    online_count = sum(1 for row in profiles if is_online(row["last_seen_at"]) and row["status"] == "active")
    stat_note = "" if stats.get("ok") else f"<p class='muted'>Stats collector: {esc(stats.get('error'))}</p>"
    rows = "".join(profile_row(row) for row in profiles)
    body = f"""
    <h1>Dashboard</h1>
    <div class="grid">
      <div class="panel"><div class="muted">Active profiles</div><div class="metric">{totals["active_profiles"] or 0}</div></div>
      <div class="panel"><div class="muted">Online now</div><div class="metric">{online_count}</div></div>
      <div class="panel"><div class="muted">Uploaded</div><div class="metric">{fmt_bytes(totals["upload_bytes"])}</div></div>
      <div class="panel"><div class="muted">Downloaded</div><div class="metric">{fmt_bytes(totals["download_bytes"])}</div></div>
    </div>
    <div class="panel">
      <h2>Create one-time profile</h2>
      <form class="row" method="post" action="/admin/profiles">
        <p><label>User label</label><input name="user_name" placeholder="Alex"></p>
        <p><label>Device</label><input name="device_name" placeholder="iPhone 15"></p>
        <p>
          <label>Protocol</label>
          <select name="protocol">
            <option value="vless">VLESS Reality</option>
            <option value="trojan">Trojan TLS</option>
            <option value="wireguard">WireGuard</option>
          </select>
        </p>
        <p><button type="submit">Create profile</button></p>
      </form>
      <p class="muted">The profile is generated once and can be revoked later. Keep one profile per user device and protocol.</p>
      {stat_note}
    </div>
    <div class="panel">
      <h2>Profiles</h2>
      <table>
        <thead><tr><th>User</th><th>Device</th><th>Protocol</th><th>Status</th><th>Session</th><th>Traffic</th><th>Created</th><th>Actions</th></tr></thead>
        <tbody>{rows or '<tr><td colspan="8" class="muted">No profiles yet.</td></tr>'}</tbody>
      </table>
    </div>
    """
    return page("Dashboard", body)


def profile_row(row: sqlite3.Row) -> str:
    status_class = "good" if row["status"] == "active" else "bad"
    online = row["status"] == "active" and is_online(row["last_seen_at"])
    session_badge = "<span class='badge good'>online</span>" if online else "<span class='badge'>offline</span>"
    traffic = f"up {fmt_bytes(row['upload_bytes'])}<br>down {fmt_bytes(row['download_bytes'])}"
    if row["status"] == "active":
        status_action = f"""
        <form method="post" action="/admin/profiles/{esc(row['id'])}/revoke">
          <button class="danger" type="submit">Revoke</button>
        </form>
        """
    else:
        status_action = f"""
        <form method="post" action="/admin/profiles/{esc(row['id'])}/enable">
          <button type="submit">Enable</button>
        </form>
        """
    delete_action = f"""
        <form method="post" action="/admin/profiles/{esc(row['id'])}/delete" onsubmit="return confirm('Delete this profile permanently?');">
          <button class="danger" type="submit">Delete</button>
        </form>
        """
    return f"""
    <tr>
      <td>{esc(row["user_name"])}</td>
      <td>{esc(row["device_name"])}</td>
      <td>{esc(row["protocol"])}</td>
      <td><span class="badge {status_class}">{esc(row["status"])}</span></td>
      <td>{session_badge}<br><span class="muted">{esc(row["last_seen_at"] or "never seen")}</span></td>
      <td>{traffic}</td>
      <td>{esc(row["created_at"])}</td>
      <td><div class="actions"><a class="button secondary" href="/admin/profiles/{esc(row["id"])}">Open</a>{status_action}{delete_action}</div></td>
    </tr>
    """


def profile_detail_html(profile_id: str) -> str:
    with db() as conn:
        row = conn.execute(
            """
            SELECT profiles.*, users.name AS user_name
            FROM profiles JOIN users ON users.id = profiles.user_id
            WHERE profiles.id=?
            """,
            (profile_id,),
        ).fetchone()
    if not row:
        return page("Not found", "<div class='panel'>Profile not found.</div>")
    if row["status"] == "active":
        status_action = f"""
        <form method="post" action="/admin/profiles/{esc(row['id'])}/revoke">
          <button class="danger" type="submit">Revoke</button>
        </form>
        """
    else:
        status_action = f"""
        <form method="post" action="/admin/profiles/{esc(row['id'])}/enable">
          <button type="submit">Enable</button>
        </form>
        """
    body = f"""
    <h1>{esc(row["user_name"])} / {esc(row["device_name"])}</h1>
    <div class="panel">
      <p><span class="badge">{esc(row["protocol"])}</span> <span class="badge">{esc(row["status"])}</span></p>
      <p class="muted">Use this configuration URL in QuickVPN import.</p>
      <textarea readonly>{esc(row["vless_url"])}</textarea>
      <p class="muted">Credential: {esc(row["credential_uuid"])}</p>
      <div class="actions">
        <a class="button secondary" href="/admin">Back</a>
        {status_action}
        <form method="post" action="/admin/profiles/{esc(row['id'])}/delete" onsubmit="return confirm('Delete this profile permanently?');">
          <button class="danger" type="submit">Delete</button>
        </form>
      </div>
    </div>
    """
    return page("Profile", body)


@app.on_event("startup")
def startup() -> None:
    init_db()
    sync_profile_urls()


@app.get("/", response_class=HTMLResponse)
async def root():
    return RedirectResponse("/admin", status_code=303)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "time": now_iso()}


@app.get("/login", response_class=HTMLResponse)
async def login_get() -> str:
    return login_page()


@app.post("/login")
async def login_post(request: Request):
    data = await form_data(request)
    if data.get("username") == ADMIN_USER and ADMIN_PASSWORD_HASH and verify_password(data.get("password", ""), ADMIN_PASSWORD_HASH):
        response = RedirectResponse("/admin", status_code=303)
        response.set_cookie("quickvpn_session", sign_session(ADMIN_USER), httponly=True, samesite="lax", max_age=60 * 60 * 12)
        audit(ADMIN_USER, "admin.login")
        return response
    return HTMLResponse(login_page("Wrong username or password."), status_code=401)


@app.get("/logout")
async def logout():
    response = RedirectResponse("/login", status_code=303)
    response.delete_cookie("quickvpn_session")
    return response


@app.get("/admin", response_class=HTMLResponse)
async def admin(request: Request):
    redirect = require_admin(request)
    if redirect:
        return redirect
    return dashboard_html()


@app.post("/admin/profiles")
async def admin_create_profile(request: Request):
    redirect = require_admin(request)
    if redirect:
        return redirect
    data = await form_data(request)
    row = create_profile(data.get("user_name", ""), data.get("device_name", ""), ADMIN_USER, data.get("protocol", "vless"))
    return RedirectResponse(f"/admin/profiles/{row['id']}", status_code=303)


@app.get("/admin/profiles/{profile_id}", response_class=HTMLResponse)
async def admin_profile(request: Request, profile_id: str):
    redirect = require_admin(request)
    if redirect:
        return redirect
    collect_stats()
    return profile_detail_html(profile_id)


@app.post("/admin/profiles/{profile_id}/revoke")
async def admin_revoke(request: Request, profile_id: str):
    redirect = require_admin(request)
    if redirect:
        return redirect
    set_profile_status(profile_id, "revoked", ADMIN_USER)
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/profiles/{profile_id}/enable")
async def admin_enable(request: Request, profile_id: str):
    redirect = require_admin(request)
    if redirect:
        return redirect
    set_profile_status(profile_id, "active", ADMIN_USER)
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/profiles/{profile_id}/delete")
async def admin_delete(request: Request, profile_id: str):
    redirect = require_admin(request)
    if redirect:
        return redirect
    delete_profile(profile_id, ADMIN_USER)
    return RedirectResponse("/admin", status_code=303)


def check_api_key(request: Request) -> bool:
    return bool(API_KEY) and hmac.compare_digest(request.headers.get("x-quickvpn-api-key", ""), API_KEY)


def check_mobile_api_key(request: Request) -> bool:
    return bool(MOBILE_API_KEY) and hmac.compare_digest(request.headers.get("x-quickvpn-client-key", ""), MOBILE_API_KEY)


@app.get("/api/v1/status")
async def api_status() -> dict[str, Any]:
    return {"ok": True, "vpn_host": VPN_HOST, "vpn_port": VPN_PORT, "time": now_iso()}


@app.post("/api/v1/profiles")
async def api_create_profile(request: Request):
    if not check_api_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    payload = await request.json()
    try:
        row = create_profile(
            str(payload.get("user_name", "")),
            str(payload.get("device_name", "")),
            "api",
            str(payload.get("protocol", "vless")),
        )
    except ValueError:
        return JSONResponse({"ok": False, "error": "unsupported_protocol"}, status_code=400)
    return JSONResponse(
        {
            "ok": True,
            "profile_id": row["id"],
            "protocol": row["protocol"],
            "config_url": row["vless_url"],
        }
    )


@app.post("/api/v1/profiles/{profile_id}/revoke")
async def api_revoke_profile(request: Request, profile_id: str):
    if not check_api_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    set_profile_status(profile_id, "revoked", "api")
    return JSONResponse({"ok": True})


@app.get("/api/v1/mobile/servers")
async def mobile_servers(request: Request):
    if not check_mobile_api_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    return JSONResponse({"ok": True, "servers": available_mobile_servers()})


@app.post("/api/v1/mobile/servers/{server_id}/profile")
async def mobile_profile(request: Request, server_id: str):
    if not check_mobile_api_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)

    device_id = request.headers.get("x-quickvpn-device-id", "").strip()
    if len(device_id) < 20 or len(device_id) > 128:
        return JSONResponse({"ok": False, "error": "invalid_device"}, status_code=400)

    payload = await request.json()
    try:
        row = issue_mobile_profile(server_id, device_id, str(payload.get("device_name", "")))
    except ValueError:
        return JSONResponse({"ok": False, "error": "unknown_server"}, status_code=404)

    return JSONResponse(
        {
            "ok": True,
            "profile_id": row["id"],
            "server_id": server_id,
            "protocol": row["protocol"],
            "config_url": row["vless_url"],
        }
    )


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "hash-password":
        print(password_hash(sys.argv[2]))
    elif len(sys.argv) >= 2 and sys.argv[1] == "collect-stats":
        init_db()
        print(json.dumps(collect_stats(), indent=2))
    elif len(sys.argv) >= 2 and sys.argv[1] == "render-xray":
        init_db()
        write_xray_config()
        print(str(XRAY_CONFIG_PATH))
    elif len(sys.argv) >= 2 and sys.argv[1] == "render-wireguard":
        init_db()
        if write_wireguard_config():
            print(str(WIREGUARD_CONFIG_PATH))
        else:
            print("WireGuard server keys are not configured")
            sys.exit(1)
    else:
        print("Usage: app.py hash-password <password> | collect-stats | render-xray | render-wireguard")
