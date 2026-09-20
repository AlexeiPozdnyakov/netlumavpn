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
from fastapi.responses import HTMLResponse, JSONResponse, PlainTextResponse, RedirectResponse, Response


APP_NAME = "QuickVPN Admin"
UTC = timezone.utc


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


DB_PATH = Path(env("QUICKVPN_DB_PATH", "/opt/quickvpn/data/quickvpn.sqlite3"))
XRAY_CONFIG_PATH = Path(env("XRAY_CONFIG_PATH", "/usr/local/etc/xray/config.json"))
XRAY_BIN = env("XRAY_BIN", "/usr/local/bin/xray")
XRAY_API_SERVER = env("XRAY_API_SERVER", "127.0.0.1:10085")
XRAY_SERVICE = env("XRAY_SERVICE", "xray")
VPN_HOST = env("VPN_HOST", "vpn.netlumavpn.example")
VPN_PORT = int(env("VPN_PORT", "443"))
XRAY_LISTEN_HOST = env("XRAY_LISTEN_HOST", "127.0.0.1")
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
REALITY_SERVER_NAME = env("REALITY_SERVER_NAME", "www.microsoft.com")
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
APP_STORE_URL = env("APP_STORE_URL", "https://apps.apple.com/search?term=NetlumaVPN")
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
SUPPORT_TOPICS = {"Bug", "Connection issue", "Billing / Premium", "Feature request", "Other"}
FEEDBACK_STATUSES = {"new", "in_review", "resolved", "archived"}


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

            CREATE TABLE IF NOT EXISTS feedback_requests (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT,
                email TEXT NOT NULL,
                topic TEXT NOT NULL,
                message TEXT NOT NULL,
                ios_version TEXT,
                app_version TEXT,
                contact_consent INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL DEFAULT 'new',
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
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


def app_store_link(label: str = "Download on the App Store", class_name: str = "button primary") -> str:
    return f'<a class="{esc(class_name)}" href="{esc(APP_STORE_URL)}" rel="noopener">{esc(label)}</a>'


def brand_mark() -> str:
    return '<span class="brand-mark">N</span><span><strong>NetlumaVPN</strong><small>Secure iOS VPN client</small></span>'


def page(title: str, body: str, *, section: str = "public", language: str = "en") -> str:
    is_admin = section == "admin"
    nav = (
        """
        <a href="/admin">Dashboard</a>
        <a href="/admin/feedback">Feedback</a>
        <a href="/api/v1/status">API status</a>
        <a href="/logout">Logout</a>
        """
        if is_admin
        else """
        <a href="/#features">Features</a>
        <a href="/setup">Setup</a>
        <a href="/support">Support</a>
        <a href="/terms">Terms</a>
        <a href="/privacy">Privacy</a>
        """
    )
    cta = "" if is_admin else app_store_link("Download on the App Store", "button primary small")
    return f"""<!doctype html>
<html lang="{esc(language)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg:#0B0F1A;
      --hero-end:#102A30;
      --surface:#151B2B;
      --surface-elevated:#182033;
      --card:#1C2336;
      --card-hover:#222B42;
      --line:#2A3349;
      --line-soft:#1F2638;
      --text:#FFFFFF;
      --muted:#94A3B8;
      --quiet:#64748B;
      --accent:#34D399;
      --accent-soft:#10B981;
      --accent-glow:#34D39933;
      --blue:#60A5FA;
      --purple:#A78BFA;
      --warning:#FBBF24;
      --warning-bg:#3A2D12;
      --danger:#F87171;
      --danger-bg:#3A1D23;
      --max:1200px;
    }}
    * {{ box-sizing:border-box; }}
    html {{ scroll-behavior:smooth; }}
    body {{
      margin:0;
      font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      background:linear-gradient(135deg,var(--bg),var(--hero-end) 56%,var(--bg));
      color:var(--text);
    }}
    a {{ color:inherit; }}
    .site-header {{
      min-height:94px;
      border-bottom:1px solid var(--line-soft);
      background:rgba(11,15,26,.88);
      backdrop-filter:blur(18px);
      position:sticky;
      top:0;
      z-index:5;
    }}
    .nav-wrap {{
      max-width:var(--max);
      margin:0 auto;
      min-height:94px;
      padding:0 32px;
      display:flex;
      align-items:center;
      justify-content:space-between;
      gap:24px;
    }}
    .brand {{
      display:flex;
      align-items:center;
      gap:10px;
      color:var(--text);
      text-decoration:none;
      min-width:max-content;
    }}
    .brand-mark {{
      display:inline-flex;
      width:28px;
      height:28px;
      border-radius:9px;
      align-items:center;
      justify-content:center;
      color:#0B0F1A;
      background:var(--accent);
      font-weight:900;
      font-family:Geist,Inter,sans-serif;
    }}
    .brand strong {{ display:block; font-family:Geist,Inter,sans-serif; font-size:15px; line-height:1; }}
    .brand small {{ display:block; color:var(--quiet); font-size:11px; line-height:1.45; }}
    nav {{ display:flex; align-items:center; justify-content:center; gap:24px; color:var(--muted); font-size:13px; }}
    nav a {{ text-decoration:none; }}
    nav a:hover {{ color:var(--text); }}
    main {{ max-width:var(--max); margin:0 auto; padding:0 32px 64px; }}
    .admin main, .legal main, .support main {{ padding-top:42px; }}
    h1, h2, h3 {{ font-family:Geist,Inter,sans-serif; letter-spacing:0; }}
    h1 {{ font-size:58px; line-height:.98; margin:0; }}
    h2 {{ font-size:34px; line-height:1.08; margin:0 0 14px; }}
    h3 {{ font-size:17px; margin:0 0 10px; }}
    p {{ color:var(--muted); line-height:1.65; }}
    .eyebrow {{ color:var(--accent); font-family:"IBM Plex Mono",ui-monospace,monospace; font-size:12px; margin:0 0 12px; }}
    .hero {{
      min-height:878px;
      display:grid;
      grid-template-columns:minmax(0,1.05fr) 430px;
      align-items:center;
      gap:86px;
      position:relative;
    }}
    .hero-copy p {{ max-width:610px; font-size:18px; margin:22px 0 28px; }}
    .hero-actions {{ display:flex; gap:12px; flex-wrap:wrap; align-items:center; margin-bottom:26px; }}
    .button, button {{
      appearance:none;
      border:0;
      border-radius:999px;
      padding:12px 18px;
      font-size:13px;
      font-weight:800;
      line-height:1;
      text-decoration:none;
      cursor:pointer;
      display:inline-flex;
      align-items:center;
      justify-content:center;
      gap:8px;
      font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
    }}
    .button.small {{ padding:10px 15px; font-size:12px; }}
    .button.primary, button.primary {{ background:var(--accent); color:#0B0F1A; box-shadow:0 0 0 6px var(--accent-glow); }}
    .button.secondary, button.secondary {{ background:var(--surface); color:var(--text); border:1px solid var(--line-soft); }}
    button.danger, .button.danger {{ background:var(--danger-bg); color:var(--danger); border:1px solid rgba(248,113,113,.32); }}
    .proof-strip {{ display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); max-width:590px; gap:10px; }}
    .proof, .panel, .feature-card, .legal-card, .form-card, .metric-card {{
      background:rgba(28,35,54,.88);
      border:1px solid var(--line-soft);
      border-radius:18px;
      box-shadow:0 22px 70px rgba(0,0,0,.18);
    }}
    .proof {{ padding:14px; }}
    .proof strong {{ display:block; font-size:13px; }}
    .proof span {{ color:var(--quiet); font-size:12px; }}
    .phone {{
      width:310px;
      margin:0 auto;
      padding:16px;
      border-radius:34px;
      background:#12262C;
      border:1px solid rgba(52,211,153,.22);
      box-shadow:0 38px 120px rgba(16,185,129,.16);
    }}
    .phone-screen {{
      min-height:530px;
      border-radius:26px;
      background:#0E1422;
      border:1px solid #22304A;
      padding:20px;
    }}
    .phone-top {{ display:flex; justify-content:space-between; color:var(--quiet); font-size:11px; margin-bottom:28px; }}
    .status-pill {{ background:var(--success-bg); color:var(--accent); border-radius:999px; padding:5px 9px; font-size:10px; font-weight:800; }}
    .power {{
      width:96px;
      height:96px;
      margin:24px auto 20px;
      border-radius:999px;
      display:flex;
      align-items:center;
      justify-content:center;
      color:var(--accent);
      border:1px solid rgba(52,211,153,.45);
      background:radial-gradient(circle at 50% 40%, rgba(52,211,153,.18), rgba(21,27,43,.92));
      font-size:34px;
    }}
    .server-row {{ display:flex; align-items:center; justify-content:space-between; gap:10px; background:var(--card); border:1px solid var(--line-soft); border-radius:14px; padding:12px; margin-top:10px; }}
    .server-row span {{ color:var(--muted); font-size:12px; }}
    .section-band {{ margin:0 -32px; padding:72px 32px; border-top:1px solid var(--line-soft); background:rgba(11,15,26,.38); }}
    .section-inner {{ max-width:var(--max); margin:0 auto; }}
    .section-head {{ max-width:720px; margin-bottom:34px; }}
    .feature-grid {{ display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:14px; }}
    .feature-card {{ min-height:160px; padding:20px; }}
    .feature-card .icon {{ width:34px; height:34px; border-radius:11px; display:flex; align-items:center; justify-content:center; background:var(--surface); color:var(--accent); margin-bottom:18px; }}
    .feature-card p {{ margin:0; font-size:13px; }}
    .tech-grid {{ display:grid; grid-template-columns:1fr 1.2fr; gap:24px; align-items:start; }}
    .code-panel {{ background:var(--surface); border:1px solid var(--line-soft); border-radius:18px; padding:20px; font-family:"IBM Plex Mono",ui-monospace,monospace; color:var(--muted); font-size:13px; line-height:1.8; }}
    .code-panel b {{ color:var(--text); font-weight:700; }}
    .cta-band {{ margin-top:72px; padding:32px; border-radius:20px; background:linear-gradient(135deg,rgba(52,211,153,.18),rgba(96,165,250,.09)); border:1px solid rgba(52,211,153,.2); display:flex; justify-content:space-between; align-items:center; gap:20px; }}
    .grid {{ display:grid; gap:14px; grid-template-columns:repeat(4,minmax(0,1fr)); }}
    .panel {{ padding:20px; margin-bottom:16px; }}
    .metric {{ font-size:34px; line-height:1; font-weight:900; font-family:Geist,Inter,sans-serif; }}
    .muted {{ color:var(--muted); }}
    .quiet {{ color:var(--quiet); }}
    .row {{ display:grid; grid-template-columns:1fr 1fr 1fr auto; gap:12px; align-items:end; }}
    table {{ width:100%; border-collapse:separate; border-spacing:0; font-size:13px; }}
    th, td {{ text-align:left; border-bottom:1px solid var(--line-soft); padding:12px 10px; vertical-align:top; }}
    th {{ color:var(--quiet); font-weight:800; font-size:11px; text-transform:uppercase; }}
    tr:hover td {{ background:rgba(34,43,66,.35); }}
    input, select, textarea {{
      width:100%;
      border:1px solid var(--line-soft);
      border-radius:12px;
      padding:12px 14px;
      font-size:14px;
      background:#151B2B;
      color:var(--text);
      outline:none;
    }}
    input:focus, select:focus, textarea:focus {{ border-color:rgba(52,211,153,.65); box-shadow:0 0 0 4px var(--accent-glow); }}
    textarea {{ min-height:130px; font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; resize:vertical; }}
    label {{ display:block; font-size:12px; color:var(--muted); margin:0 0 7px; font-weight:700; }}
    .field {{ margin:0 0 14px; }}
    .badge {{ display:inline-flex; align-items:center; border-radius:999px; padding:4px 9px; font-size:11px; font-weight:800; background:var(--surface); color:var(--muted); border:1px solid var(--line-soft); }}
    .badge.good {{ background:var(--success-bg); color:var(--accent); border-color:rgba(52,211,153,.35); }}
    .badge.bad {{ background:var(--danger-bg); color:var(--danger); border-color:rgba(248,113,113,.35); }}
    .badge.warning {{ background:var(--warning-bg); color:var(--warning); border-color:rgba(251,191,36,.35); }}
    .actions {{ display:flex; gap:8px; flex-wrap:wrap; }}
    .support-layout {{ display:grid; grid-template-columns:300px minmax(0,1fr); gap:24px; align-items:start; }}
    .form-card {{ padding:24px; }}
    .info-card {{ background:var(--card); border:1px solid var(--line-soft); border-radius:16px; padding:18px; margin-bottom:14px; }}
    .legal-layout {{ display:grid; grid-template-columns:250px minmax(0,1fr); gap:24px; align-items:start; }}
    .legal-index {{ position:sticky; top:118px; }}
    .legal-card {{ padding:22px; margin-bottom:14px; }}
    .legal-card p {{ margin:0; font-size:14px; }}
    .success-box, .error-box {{ border-radius:16px; padding:16px; margin-bottom:16px; }}
    .success-box {{ background:var(--success-bg); color:var(--accent); border:1px solid rgba(52,211,153,.35); }}
    .error-box {{ background:var(--danger-bg); color:var(--danger); border:1px solid rgba(248,113,113,.35); }}
    .admin-title {{ display:flex; justify-content:space-between; gap:20px; align-items:flex-start; margin-bottom:22px; }}
    .feedback-layout {{ display:grid; grid-template-columns:340px minmax(0,1fr); gap:18px; align-items:start; }}
    .feedback-message {{ max-width:420px; white-space:pre-wrap; color:var(--muted); line-height:1.45; }}
    .filter-row {{ display:grid; grid-template-columns:1fr 160px 160px auto; gap:10px; align-items:end; margin:14px 0 18px; }}
    .setup-hero {{
      min-height:510px;
      display:grid;
      grid-template-columns:minmax(0,1.2fr) minmax(320px,.8fr);
      align-items:center;
      gap:64px;
      padding:72px 0 54px;
    }}
    .setup-hero h1 {{ max-width:720px; }}
    .setup-hero-copy > p:not(.eyebrow) {{ max-width:680px; font-size:18px; margin:22px 0 28px; }}
    .setup-hero-actions {{ display:flex; flex-wrap:wrap; gap:12px; }}
    .setup-highlight {{
      position:relative;
      overflow:hidden;
      padding:28px;
      border-radius:24px;
      background:linear-gradient(145deg,rgba(28,35,54,.96),rgba(18,38,44,.94));
      border:1px solid rgba(52,211,153,.24);
      box-shadow:0 34px 100px rgba(16,185,129,.12);
    }}
    .setup-highlight::after {{
      content:"TRJ";
      position:absolute;
      right:-10px;
      bottom:-24px;
      color:rgba(52,211,153,.07);
      font:900 96px/1 Geist,Inter,sans-serif;
    }}
    .setup-highlight p {{ position:relative; z-index:1; }}
    .setup-highlight .badge {{ margin-bottom:14px; }}
    .platform-nav {{
      display:flex;
      gap:10px;
      overflow-x:auto;
      padding:0 0 18px;
      margin-bottom:46px;
      scrollbar-width:thin;
    }}
    .platform-nav a {{
      flex:0 0 auto;
      padding:9px 13px;
      border:1px solid var(--line-soft);
      border-radius:999px;
      color:var(--muted);
      background:rgba(21,27,43,.72);
      text-decoration:none;
      font-size:12px;
      font-weight:800;
    }}
    .platform-nav a:hover {{ color:var(--text); border-color:rgba(52,211,153,.4); }}
    .setup-section {{ padding:62px 0; border-top:1px solid var(--line-soft); scroll-margin-top:112px; }}
    .setup-section-head {{ max-width:760px; margin-bottom:28px; }}
    .setup-section-head p {{ margin-bottom:0; }}
    .quick-steps {{ display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:14px; counter-reset:steps; }}
    .quick-step {{
      counter-increment:steps;
      min-height:190px;
      padding:20px;
      border:1px solid var(--line-soft);
      border-radius:18px;
      background:rgba(28,35,54,.84);
    }}
    .quick-step::before {{
      content:counter(steps,decimal-leading-zero);
      display:flex;
      width:34px;
      height:34px;
      align-items:center;
      justify-content:center;
      margin-bottom:26px;
      border-radius:11px;
      color:var(--accent);
      background:var(--surface);
      font:800 12px/1 "IBM Plex Mono",ui-monospace,monospace;
    }}
    .quick-step p {{ margin:0; font-size:13px; }}
    .platform-grid {{ display:grid; grid-template-columns:repeat(2,minmax(0,1fr)); gap:18px; }}
    .platform-card {{
      padding:24px;
      border:1px solid var(--line-soft);
      border-radius:20px;
      background:rgba(28,35,54,.86);
      box-shadow:0 22px 70px rgba(0,0,0,.14);
      scroll-margin-top:112px;
    }}
    .platform-card.wide {{ grid-column:1/-1; }}
    .platform-title {{ display:flex; justify-content:space-between; align-items:flex-start; gap:16px; margin-bottom:18px; }}
    .platform-title p {{ margin:4px 0 0; font-size:13px; }}
    .platform-code {{ color:var(--accent); font:800 11px/1 "IBM Plex Mono",ui-monospace,monospace; text-transform:uppercase; letter-spacing:.08em; }}
    .resource-list {{ display:grid; gap:10px; margin:18px 0 22px; }}
    .resource-link {{
      display:flex;
      align-items:center;
      justify-content:space-between;
      gap:16px;
      padding:13px 14px;
      border:1px solid var(--line-soft);
      border-radius:13px;
      background:rgba(21,27,43,.84);
      text-decoration:none;
    }}
    .resource-link:hover {{ border-color:rgba(52,211,153,.4); background:var(--card-hover); }}
    .resource-link strong {{ display:block; font-size:13px; }}
    .resource-link small {{ display:block; margin-top:3px; color:var(--quiet); font-size:11px; }}
    .resource-link span:last-child {{ color:var(--accent); font-size:18px; }}
    .instruction-list {{ margin:16px 0 0; padding:0; list-style:none; counter-reset:instruction; }}
    .instruction-list li {{
      counter-increment:instruction;
      position:relative;
      min-height:30px;
      padding:0 0 13px 36px;
      color:var(--muted);
      line-height:1.55;
      font-size:13px;
    }}
    .instruction-list li::before {{
      content:counter(instruction);
      position:absolute;
      left:0;
      top:0;
      display:flex;
      width:24px;
      height:24px;
      align-items:center;
      justify-content:center;
      border-radius:999px;
      background:rgba(52,211,153,.12);
      color:var(--accent);
      font-size:11px;
      font-weight:900;
    }}
    .video-row {{ display:flex; flex-wrap:wrap; gap:8px; margin-top:18px; }}
    .video-link {{
      padding:8px 11px;
      border-radius:999px;
      border:1px solid var(--line-soft);
      color:var(--muted);
      text-decoration:none;
      font-size:11px;
      font-weight:800;
    }}
    .video-link:hover {{ color:var(--text); border-color:rgba(96,165,250,.45); }}
    .tip-box {{
      padding:18px;
      margin-top:18px;
      border-radius:16px;
      border:1px solid rgba(96,165,250,.24);
      background:rgba(96,165,250,.08);
    }}
    .tip-box p {{ margin:5px 0 0; font-size:13px; }}
    .dns-layout {{ display:grid; grid-template-columns:minmax(0,.8fr) minmax(0,1.2fr); gap:18px; }}
    .dns-addresses {{
      display:grid;
      grid-template-columns:1fr 1fr;
      gap:10px;
      margin-top:18px;
    }}
    .dns-address {{
      padding:14px;
      border-radius:14px;
      background:#0E1422;
      border:1px solid var(--line-soft);
      color:var(--text);
      font:700 14px/1 "IBM Plex Mono",ui-monospace,monospace;
    }}
    .safety-note {{ margin-top:16px; color:var(--quiet); font-size:12px; }}
    footer {{ border-top:1px solid var(--line-soft); color:var(--quiet); padding:26px 32px 40px; max-width:var(--max); margin:0 auto; display:flex; justify-content:space-between; gap:16px; font-size:13px; }}
    footer a {{ color:var(--muted); text-decoration:none; margin-left:16px; }}
    @media (max-width: 980px) {{
      h1 {{ font-size:44px; }}
      .hero {{ grid-template-columns:1fr; padding:64px 0; gap:36px; min-height:auto; }}
      .feature-grid, .grid {{ grid-template-columns:repeat(2,minmax(0,1fr)); }}
      .tech-grid, .support-layout, .legal-layout, .feedback-layout, .setup-hero, .dns-layout {{ grid-template-columns:1fr; }}
      .quick-steps {{ grid-template-columns:repeat(2,minmax(0,1fr)); }}
      .legal-index {{ position:static; }}
      .row, .filter-row {{ grid-template-columns:1fr; }}
      .cta-band, .admin-title {{ align-items:flex-start; flex-direction:column; }}
    }}
    @media (max-width: 720px) {{
      .nav-wrap {{ padding:16px; min-height:auto; flex-wrap:wrap; }}
      nav {{ order:3; width:100%; justify-content:flex-start; overflow:auto; gap:18px; padding-bottom:2px; }}
      main {{ padding:0 18px 48px; }}
      .admin main, .legal main, .support main {{ padding-top:30px; }}
      .setup-hero {{ padding:48px 0 40px; gap:28px; }}
      .section-band {{ margin:0 -18px; padding:48px 18px; }}
      .proof-strip, .feature-grid, .grid, .quick-steps, .platform-grid {{ grid-template-columns:1fr; }}
      .platform-card.wide {{ grid-column:auto; }}
      .setup-section {{ padding:48px 0; }}
      .dns-addresses {{ grid-template-columns:1fr; }}
      .phone {{ width:min(310px,100%); }}
      footer {{ padding:22px 18px 34px; flex-direction:column; }}
      footer a {{ margin:0 14px 0 0; }}
      table {{ min-width:760px; }}
      .table-scroll {{ overflow-x:auto; }}
    }}
  </style>
</head>
<body class="{esc(section)}">
  <header class="site-header">
    <div class="nav-wrap">
      <a class="brand" href="/">{brand_mark()}</a>
      <nav>{nav}</nav>
      {cta}
    </div>
  </header>
  <main>{body}</main>
  <footer>
    <span>NetlumaVPN for iPhone. Use VPN profiles and managed servers responsibly.</span>
    <span><a href="/setup">Setup</a><a href="/support">Support</a><a href="/terms">Terms</a><a href="/privacy">Privacy</a></span>
  </footer>
</body>
</html>"""


def marketing_home_html() -> str:
    features = [
        ("Protocol coverage", "VLESS + Reality, VMess, Trojan TLS and WireGuard profile support."),
        ("QR and URL import", "Paste a config link or scan a QR code when a provider gives you one."),
        ("Global servers", "Use NetlumaVPN-managed profiles when Premium access is active."),
        ("DNS controls", "Choose resolver behavior and tunnel preferences from the app."),
        ("Session details", "Check public IP, approximate location, status and latency context."),
        ("Home Screen widget", "Connect or disconnect quickly without opening the app."),
        ("Keychain storage", "Sensitive profile values are kept in device-protected storage."),
        ("StoreKit Premium", "Subscriptions are handled by Apple through the App Store."),
    ]
    cards = "".join(
        f"""
        <article class="feature-card">
          <div class="icon">{"%02d" % (index + 1)}</div>
          <h3>{esc(title)}</h3>
          <p>{esc(text)}</p>
        </article>
        """
        for index, (title, text) in enumerate(features)
    )
    body = f"""
    <section class="hero">
      <div class="hero-copy">
        <p class="eyebrow">netlumavpn.example</p>
        <h1>NetlumaVPN</h1>
        <p>Multi-protocol VPN client for iPhone. Import your own profiles, use managed NetlumaVPN Global servers, and keep connection controls close at hand.</p>
        <div class="hero-actions">
          {app_store_link()}
          <a class="button secondary" href="/support">Get support</a>
        </div>
        <div class="proof-strip">
          <div class="proof"><strong>4 protocols</strong><span>VLESS, VMess, Trojan, WireGuard</span></div>
          <div class="proof"><strong>iOS-native</strong><span>Network Extension tunnel</span></div>
          <div class="proof"><strong>Widget ready</strong><span>Quick connect from Home Screen</span></div>
        </div>
      </div>
      <div class="phone" aria-label="NetlumaVPN app preview">
        <div class="phone-screen">
          <div class="phone-top"><span>9:41</span><span class="status-pill">CONNECTED</span></div>
          <h3>NetlumaVPN Global</h3>
          <p style="margin:6px 0 0;font-size:13px;">Nuremberg, Germany</p>
          <div class="power">ON</div>
          <div class="server-row"><span>VLESS Reality</span><span class="badge good">active</span></div>
          <div class="server-row"><span>Trojan TLS</span><span class="badge">ready</span></div>
          <div class="server-row"><span>WireGuard</span><span class="badge">ready</span></div>
          <div class="server-row"><span>Session</span><span>00:18:42</span></div>
        </div>
      </div>
    </section>
    <section class="section-band" id="features">
      <div class="section-inner">
        <div class="section-head">
          <p class="eyebrow">Features</p>
          <h2>Protocol coverage, profile control, and a clear iPhone-native workflow.</h2>
          <p>NetlumaVPN is built for users who already understand VPN profiles but still want a clean iOS experience for connecting, importing, and checking the current session.</p>
        </div>
        <div class="feature-grid">{cards}</div>
      </div>
    </section>
    <section class="section-band">
      <div class="section-inner tech-grid">
        <div>
          <p class="eyebrow">Security model</p>
          <h2>Built around iOS Network Extension, local storage, and transparent controls.</h2>
          <p>Profile metadata stays in local app-group storage, sensitive profile values are stored through protected device storage, and the tunnel extension receives only the start payload it needs to connect.</p>
          <p>When you use third-party profiles or DNS resolvers, those providers may process traffic according to their own policies.</p>
        </div>
        <div class="code-panel">
          <b>Supported inputs</b><br>
          vless:// + Reality<br>
          vmess:// profile links<br>
          trojan:// TLS profiles<br>
          wireguard:// profile links<br><br>
          <b>Controls</b><br>
          Persist tunnel, IP mode, DNS resolver, include-all-networks, on-demand behavior
        </div>
      </div>
      <div class="section-inner cta-band">
        <div>
          <h3>Ready to connect from your iPhone?</h3>
          <p style="margin:6px 0 0;">Download NetlumaVPN, import a profile, or use a managed Global server with Premium.</p>
        </div>
        <div class="actions">
          {app_store_link("Download for iPhone")}
          <a class="button secondary" href="/support">Contact support</a>
        </div>
      </div>
    </section>
    """
    return page("NetlumaVPN", body)


def setup_resource_link(title: str, note: str, url: str) -> str:
    return f"""
    <a class="resource-link" href="{esc(url)}" target="_blank" rel="noopener noreferrer">
      <span><strong>{esc(title)}</strong><small>{esc(note)}</small></span>
      <span aria-hidden="true">↗</span>
    </a>
    """


def setup_video_link(title: str, url: str) -> str:
    return f'<a class="video-link" href="{esc(url)}" target="_blank" rel="noopener noreferrer">{esc(title)} ↗</a>'


def setup_page_html() -> str:
    ios_resources = "".join(
        setup_resource_link(*resource)
        for resource in [
            ("Karing", "Рекомендуем · App Store", "https://apps.apple.com/ru/app/karing/id6472431552"),
            ("Hiddify", "App Store", "https://apps.apple.com/us/app/hiddify-proxy-vpn/id6596777532?platform=iphone"),
            ("Hiddify iOS", "IPA · версия 2.1.1", "https://github.com/hiddify/hiddify-next/releases/download/v2.1.1/Hiddify-iOS.ipa"),
            ("sing-box VT", "App Store", "https://apps.apple.com/ru/app/sing-box-vt/id6673731168?l=ru&platform=iphone"),
        ]
    )
    mac_resources = "".join(
        setup_resource_link(*resource)
        for resource in [
            ("Karing", "Рекомендуем · Mac App Store", "https://apps.apple.com/ru/app/karing/id6472431552"),
            ("sing-box VT", "Mac App Store", "https://apps.apple.com/ru/app/sing-box-vt/id6673731168?l=ru&platform=mac"),
            ("Hiddify для macOS", "DMG · версия 2.5.7", "https://github.com/hiddify/hiddify-next/releases/download/v2.5.7/Hiddify-MacOS.dmg"),
            ("Hiddify Installer", "PKG · версия 2.5.7", "https://github.com/hiddify/hiddify-next/releases/download/v2.5.7/Hiddify-MacOS-Installer.pkg"),
        ]
    )
    windows_resources = "".join(
        setup_resource_link(*resource)
        for resource in [
            ("Karing", "Официальная страница загрузки", "https://karing.app/en/download/"),
            ("Karing Stable", "Установщик для Windows", "https://dot.karing.app/client.html?tag=windows-installer-stable"),
            ("Karing 1.2.17.2006", "Прямая ссылка · Windows x64 EXE", "https://github.com/KaringX/karing/releases/download/v1.2.17.2006/karing_1.2.17.2006_windows_x64.exe"),
            ("Hiddify 2.5.7", "Прямая ссылка · Windows x64 EXE", "https://github.com/hiddify/hiddify-app/releases/download/v2.5.7/Hiddify-Windows-Setup-x64.exe"),
            ("Hiddify Next 2.5.7", "Альтернативная прямая ссылка · Windows x64 EXE", "https://github.com/hiddify/hiddify-next/releases/download/v2.5.7/Hiddify-Windows-Setup-x64.exe"),
            ("Hiddify Next", "Страница прямых загрузок на GitHub", "https://github.com/hiddify/hiddify-next?tab=readme-ov-file#-direct-download"),
        ]
    )
    android_resources = "".join(
        setup_resource_link(*resource)
        for resource in [
            ("Karing", "APK · ARM · версия 1.2.17.2006", "https://gh-proxy.org/https://github.com/KaringX/karing/releases/download/v1.2.17.2006/karing_1.2.17.2006_android_arm.apk"),
            ("Hiddify", "Google Play", "https://play.google.com/store/apps/details?id=app.hiddify.com&hl=ru"),
            ("Hiddify 2.5.7", "Универсальный APK", "https://github.com/hiddify/hiddify-app/releases/download/v2.5.7/Hiddify-Android-universal.apk"),
            ("sing-box", "Google Play", "https://play.google.com/store/apps/details?id=io.nekohasekai.sfa&hl=ru"),
        ]
    )
    apple_tv_resources = setup_resource_link(
        "sing-box VT",
        "App Store для Apple TV",
        "https://apps.apple.com/ru/app/sing-box-vt/id6673731168?l=ru&platform=appleTV",
    )
    linux_resources = setup_resource_link(
        "Hiddify 2.5.7",
        "Linux x64 AppImage",
        "https://github.com/hiddify/hiddify-app/releases/download/v2.5.7/Hiddify-Linux-x64.AppImage",
    )
    dns_resources = "".join(
        setup_resource_link(*resource)
        for resource in [
            ("DNS Optimizer: Server Changer", "App Store", "https://apps.apple.com/us/app/dns-optimizer-server-changer/id6741016224?l=ru"),
            ("DNS Secure", "App Store", "https://apps.apple.com/ru/app/dnsecure/id1533413232"),
            ("DNS Configurator", "App Store", "https://apps.apple.com/ru/app/dns-configurator/id1532682460"),
        ]
    )
    ios_videos = "".join(
        [
            setup_video_link("Karing на iPhone", "https://youtube.com/shorts/2XbnHMIMmwM"),
            setup_video_link("Hiddify на iPhone", "https://youtube.com/shorts/tFOt2aRkiIk"),
            setup_video_link("sing-box на iPhone", "https://youtube.com/shorts/2p6ZxNq39gM"),
        ]
    )
    body = f"""
    <section class="setup-hero">
      <div class="setup-hero-copy">
        <p class="eyebrow">Пошаговая инструкция</p>
        <h1>Настройте VPN на любом устройстве.</h1>
        <p>Выберите платформу, установите подходящее приложение и импортируйте выданный профиль одной строкой. Для самого простого сценария используйте Karing.</p>
        <div class="setup-hero-actions">
          <a class="button primary" href="#quick-start">Быстрый старт</a>
          <a class="button secondary" href="https://karing.app/en/download/" target="_blank" rel="noopener noreferrer">Скачать Karing ↗</a>
        </div>
      </div>
      <aside class="setup-highlight">
        <span class="badge good">Рекомендуемый профиль</span>
        <h2 style="font-size:28px;">Используйте Trojan / TRJ</h2>
        <p>Выбирайте конфиги с меткой <strong style="color:var(--text);">TRJ</strong> или <strong style="color:var(--text);">Trojan</strong>. Они поддерживают UDP-трафик; VLESS может быть недоступен в некоторых мобильных сетях.</p>
        <p class="safety-note">Используйте только доверенные профили и соблюдайте правила вашей сети и местное законодательство.</p>
      </aside>
    </section>

    <nav class="platform-nav" aria-label="Платформы">
      <a href="#ios">iPhone / iPad</a>
      <a href="#macos">macOS</a>
      <a href="#windows">Windows</a>
      <a href="#android">Android</a>
      <a href="#appletv">Apple TV</a>
      <a href="#linux">Linux</a>
      <a href="#dns-help">Ошибка DNS</a>
    </nav>

    <section class="setup-section" id="quick-start">
      <div class="setup-section-head">
        <p class="eyebrow">Быстрый старт</p>
        <h2>Подключение за четыре шага</h2>
        <p>Названия пунктов могут немного отличаться в разных версиях приложения.</p>
      </div>
      <div class="quick-steps">
        <article class="quick-step"><h3>Получите профиль</h3><p>Скопируйте выданную строку конфигурации. Для мобильных сетей выбирайте профиль Trojan / TRJ.</p></article>
        <article class="quick-step"><h3>Установите клиент</h3><p>Рекомендуем Karing. Ниже также есть Hiddify и sing-box для совместимых платформ.</p></article>
        <article class="quick-step"><h3>Импортируйте</h3><p>Добавьте профиль из буфера обмена. В sing-box используйте Remote → URL и вставьте одну строку.</p></article>
        <article class="quick-step"><h3>Проверьте маршрут</h3><p>В Karing откройте Правила → Страна / Регион и выберите РФ. На Windows включите TUN.</p></article>
      </div>
    </section>

    <section class="setup-section" id="platforms">
      <div class="setup-section-head">
        <p class="eyebrow">Приложения и инструкции</p>
        <h2>Выберите вашу платформу</h2>
        <p>Магазины приложений предпочтительнее прямых установочных файлов. Для IPA, APK, EXE, DMG, PKG и AppImage проверяйте источник и подпись файла.</p>
      </div>
      <div class="platform-grid">
        <article class="platform-card" id="ios">
          <div class="platform-title"><div><span class="platform-code">iOS</span><h2 style="font-size:26px;">iPhone / iPad</h2><p>Karing — основной рекомендуемый клиент.</p></div><span class="badge good">Karing</span></div>
          <div class="resource-list">{ios_resources}</div>
          <ol class="instruction-list">
            <li>Скопируйте строку профиля Trojan / TRJ.</li>
            <li>В Karing импортируйте профиль из буфера обмена и включите VPN.</li>
            <li>Откройте Правила → Страна / Регион и выберите РФ.</li>
            <li>В sing-box: Профили → Добавить профиль → Remote → URL, затем вставьте одну строку.</li>
          </ol>
          <div class="video-row">{ios_videos}</div>
        </article>

        <article class="platform-card" id="macos">
          <div class="platform-title"><div><span class="platform-code">macOS</span><h2 style="font-size:26px;">Mac</h2><p>Доступны Karing, sing-box VT и Hiddify.</p></div><span class="badge good">Karing</span></div>
          <div class="resource-list">{mac_resources}</div>
          <ol class="instruction-list">
            <li>Установите Karing из Mac App Store.</li>
            <li>Импортируйте профиль одной строкой из буфера обмена.</li>
            <li>В Правила → Страна / Регион выберите РФ и запустите VPN.</li>
          </ol>
          <div class="video-row">{setup_video_link("Karing на macOS", "https://youtu.be/M3gKOxOqN0k")}</div>
        </article>

        <article class="platform-card wide" id="windows">
          <div class="platform-title"><div><span class="platform-code">Windows</span><h2 style="font-size:26px;">Windows 10 / 11</h2><p>Для полноценного туннеля приложение нужно запускать с правами администратора.</p></div><span class="badge good">TUN mode</span></div>
          <div class="resource-list">{windows_resources}</div>
          <ol class="instruction-list">
            <li>Запустите Karing или Hiddify от имени администратора.</li>
            <li>В Karing включите TUN, импортируйте одну строку профиля из буфера обмена и запустите VPN.</li>
            <li>В Karing откройте Правила → Страна / Регион и выберите РФ.</li>
            <li>В Hiddify смените режим прокси на «VPN сервис (экспериментальный)».</li>
            <li>В Hiddify откройте Параметры конфигурации → Варианты маршрутизации → Регион и выберите «Другой».</li>
          </ol>
          <div class="video-row">
            {setup_video_link("Видео: Karing + Hiddify", "https://youtu.be/bqVj3vat6II")}
            {setup_video_link("Инструкция Hiddify Next", "https://checkvpn.net/wiki/Hiddify_Next_-_клиент_под_Windows_для_подключения_через_VLESS")}
            {setup_video_link("Где включить VPN-режим", "https://docs.netlumavpn.example/setup-image.png")}
          </div>
        </article>

        <article class="platform-card" id="android">
          <div class="platform-title"><div><span class="platform-code">Android</span><h2 style="font-size:26px;">Android</h2><p>Karing, Hiddify или официальный sing-box.</p></div><span class="badge good">Karing</span></div>
          <div class="resource-list">{android_resources}</div>
          <ol class="instruction-list">
            <li>Установите приложение из Google Play либо подходящий APK.</li>
            <li>Импортируйте профиль Trojan / TRJ из буфера обмена.</li>
            <li>В Karing выберите Правила → Страна / Регион → РФ и включите VPN.</li>
          </ol>
        </article>

        <article class="platform-card" id="appletv">
          <div class="platform-title"><div><span class="platform-code">tvOS</span><h2 style="font-size:26px;">Apple TV</h2><p>Используйте sing-box VT из App Store.</p></div><span class="badge">sing-box</span></div>
          <div class="resource-list">{apple_tv_resources}</div>
          <ol class="instruction-list">
            <li>Установите sing-box VT на Apple TV.</li>
            <li>Добавьте удалённый профиль по URL и вставьте выданную строку.</li>
            <li>Активируйте профиль и разрешите создание VPN-конфигурации.</li>
          </ol>
        </article>

        <article class="platform-card" id="linux">
          <div class="platform-title"><div><span class="platform-code">Linux</span><h2 style="font-size:26px;">Linux x64</h2><p>Готовая сборка Hiddify в формате AppImage.</p></div><span class="badge">AppImage</span></div>
          <div class="resource-list">{linux_resources}</div>
          <ol class="instruction-list">
            <li>Скачайте AppImage и разрешите выполнение файла.</li>
            <li>Импортируйте профиль одной строкой.</li>
            <li>Включите VPN-режим и проверьте доступность сайтов.</li>
          </ol>
        </article>

        <article class="platform-card">
          <div class="platform-title"><div><span class="platform-code">Материалы</span><h2 style="font-size:26px;">Полная памятка</h2><p>Дополнительная версия инструкции в Google Docs.</p></div></div>
          <div class="resource-list">
            {setup_resource_link("Открыть Google Docs", "Расширенная памятка по подключению", "https://docs.netlumavpn.example/setup")}
          </div>
          <p class="safety-note">Если ссылки или названия пунктов изменились, используйте последнюю стабильную версию клиента с официальной страницы проекта.</p>
        </article>
      </div>
    </section>

    <section class="setup-section" id="dns-help">
      <div class="setup-section-head">
        <p class="eyebrow">Диагностика iPhone</p>
        <h2>Профиль не импортируется: dial tcp / lookup / no such host</h2>
        <p>Такая ошибка обычно означает, что устройство не может разрешить имя сервера через текущий DNS.</p>
      </div>
      <div class="dns-layout">
        <article class="platform-card">
          <div class="platform-title"><div><span class="platform-code">Шаг 1</span><h3>Установите одно DNS-приложение</h3></div></div>
          <div class="resource-list">{dns_resources}</div>
          <div class="video-row">
            {setup_video_link("Пример ошибки", "https://docs.netlumavpn.example/setup-image.png")}
            {setup_video_link("DNS-параметры Hiddify", "https://docs.netlumavpn.example/setup-image.png")}
          </div>
        </article>
        <article class="platform-card">
          <div class="platform-title"><div><span class="platform-code">Шаг 2</span><h3>Выберите Google DNS</h3><p>Выберите провайдера Google или введите IPv4-адреса вручную.</p></div></div>
          <div class="dns-addresses">
            <div class="dns-address">8.8.8.8</div>
            <div class="dns-address">8.8.4.4</div>
          </div>
          <ol class="instruction-list">
            <li>Активируйте DNS-конфигурацию в выбранном приложении.</li>
            <li>Вернитесь в VPN-клиент и повторите импорт профиля.</li>
            <li>После успешного импорта подключитесь и проверьте работу сайтов.</li>
          </ol>
          <div class="video-row">
            {setup_video_link("Видео: DNS Optimizer", "https://youtube.com/shorts/7hx2MOuExEk")}
            {setup_video_link("Инструкция по DNS на iPhone", "https://wiki.iphoster.net/wiki/Как_изменить_ДНС_сервера_для_Вашего_интернет_подключения_на_ios_-_IPHONE")}
          </div>
        </article>
      </div>
      <div class="tip-box">
        <strong>Не помогло?</strong>
        <p>Переключитесь между Wi‑Fi и мобильной сетью, перезапустите VPN-клиент и убедитесь, что строка профиля скопирована полностью. Затем обратитесь в <a href="/support">поддержку NetlumaVPN</a>.</p>
      </div>
    </section>
    """
    return page("Настройка VPN — NetlumaVPN", body, section="setup", language="ru")


def support_form_html(*, sent: bool = False, error: str = "", values: dict[str, str] | None = None) -> str:
    values = values or {}
    topic_options = "".join(
        f'<option value="{esc(topic)}"{" selected" if values.get("topic") == topic else ""}>{esc(topic)}</option>'
        for topic in ["Bug", "Connection issue", "Billing / Premium", "Feature request", "Other"]
    )
    notice = ""
    if sent:
        notice = '<div class="success-box">Thanks, your feedback was sent.</div>'
    elif error:
        notice = f'<div class="error-box">{esc(error)}</div>'
    return f"""
    <div class="support-layout">
      <aside>
        <p class="eyebrow">Support</p>
        <h1 style="font-size:42px;">Get help with setup, connection quality, billing, or product feedback.</h1>
        <p>Use this form for bugs, connection issues, Premium questions, and feature ideas.</p>
        <div class="info-card">
          <h3>Before you submit</h3>
          <p>Include your iOS version, app version, profile type, and what you expected to happen.</p>
        </div>
        <div class="info-card">
          <h3>Request types</h3>
          <p>Bug, connection issue, billing, feature request, or general feedback.</p>
        </div>
      </aside>
      <section class="form-card">
        {notice}
        <h2 style="font-size:24px;">Contact support</h2>
        <form method="post" action="/support">
          <div class="field"><label>Name</label><input name="name" autocomplete="name" value="{esc(values.get("name", ""))}"></div>
          <div class="field"><label>Email</label><input name="email" type="email" required autocomplete="email" value="{esc(values.get("email", ""))}"></div>
          <div class="row" style="grid-template-columns:1fr 160px;">
            <div class="field"><label>Topic</label><select name="topic">{topic_options}</select></div>
            <div class="field"><label>iOS version</label><input name="ios_version" placeholder="iOS 26" value="{esc(values.get("ios_version", ""))}"></div>
          </div>
          <div class="field"><label>App version</label><input name="app_version" placeholder="1.0" value="{esc(values.get("app_version", ""))}"></div>
          <div class="field"><label>Message</label><textarea name="message" required>{esc(values.get("message", ""))}</textarea></div>
          <label style="display:flex;gap:10px;align-items:center;margin-bottom:16px;"><input style="width:auto;" type="checkbox" name="contact_consent" {"checked" if values.get("contact_consent") else ""}> I agree to be contacted about this request</label>
          <button class="primary" type="submit">Send request</button>
        </form>
      </section>
    </div>
    <section class="section-band" style="margin-top:54px;">
      <div class="section-inner">
        <h2 style="font-size:24px;">Form states</h2>
        <div class="grid" style="grid-template-columns:repeat(3,minmax(0,1fr));">
          <div class="info-card"><span class="badge">Loading</span><p>Sending your request.</p></div>
          <div class="info-card"><span class="badge good">Success</span><p>Your message was received.</p></div>
          <div class="info-card"><span class="badge bad">Error</span><p>Please check the required fields.</p></div>
        </div>
      </div>
    </section>
    """


def support_page_html(request: Request | None = None, *, error: str = "", values: dict[str, str] | None = None) -> str:
    sent = request is not None and request.query_params.get("sent") == "1"
    return page("Support", support_form_html(sent=sent, error=error, values=values), section="support")


def legal_page_html(kind: str) -> str:
    is_privacy = kind == "privacy"
    title = "Privacy Policy" if is_privacy else "Terms of Use"
    effective = "Effective date: June 24, 2026"
    sections = (
        [
            ("Local app data", "NetlumaVPN stores profile metadata, selected preferences, connection display state, and local diagnostics on your device or in app-group storage so the app, widget, and tunnel extension can work."),
            ("VPN profiles and secrets", "Sensitive VPN profile values are stored in protected device storage where available. You are responsible for importing profiles only from providers you trust."),
            ("App Store purchases", "Premium purchases and subscriptions are handled by Apple through StoreKit and the App Store. NetlumaVPN receives only the entitlement status needed to unlock app features."),
            ("Diagnostics / crash analytics", "The app may use Firebase services for network failure, crash, and purchase lifecycle diagnostics. These events should not include VPN credentials, full URLs, or generated configs."),
            ("IP / session lookup", "If you open session information features, NetlumaVPN may request public IP and approximate network metadata from an IP information service such as ipapi.co."),
            ("DNS providers", "If you choose an encrypted DNS resolver or another DNS option, DNS providers may process query data according to their own policies."),
            ("Third-party services", "VPN providers, DNS resolvers, Apple, and session information services are independent services with their own terms and privacy practices."),
            ("User controls", "You can delete imported profiles, change DNS and tunnel settings, disconnect the VPN, manage subscriptions in Apple settings, remove VPN configurations, or uninstall the app."),
            ("Contact / support", "For privacy questions or requests, use the official support page. Because most data is local to your device, remote deletion may not be possible for local app data."),
        ]
        if is_privacy
        else [
            ("Use of app", "NetlumaVPN is an iOS VPN client for importing profiles, configuring an iOS Network Extension tunnel, selecting managed Global servers, and viewing connection information."),
            ("VPN profiles", "You are responsible for every VPN profile, QR code, link, hostname, key, user identifier, password, certificate, or other credential that you import or use."),
            ("Subscriptions via Apple / App Store", "If Premium features are available, purchases are processed by Apple through the App Store. Pricing, trials, renewal, cancellation, refunds, taxes, and payment methods are handled by Apple."),
            ("Acceptable use", "You agree not to use NetlumaVPN to break the law, harm others, attack networks, send spam, distribute malware, infringe rights, or bypass rules you are required to follow."),
            ("Third-party services", "Imported VPN providers, DNS resolvers, Apple systems, and IP information services are not controlled by NetlumaVPN and may have separate terms and policies."),
            ("Availability", "Connection speed, availability, routing, latency, and compatibility depend on your device, local network, internet provider, selected profile, server provider, and iOS behavior."),
            ("Limitation of liability", "To the maximum extent allowed by law, NetlumaVPN is provided as is and the operator is not liable for indirect damages, lost data, service interruption, or third-party provider actions."),
            ("Contact / support", "For questions about these terms, use the support page or another official support channel provided for NetlumaVPN."),
        ]
    )
    index_items = "".join(f"<p><a href='#{esc(slugify(heading))}'>{esc(heading)}</a></p>" for heading, _ in sections)
    cards = "".join(
        f"""
        <section class="legal-card" id="{esc(slugify(heading))}">
          <h3>{esc(heading)}</h3>
          <p>{esc(text)}</p>
        </section>
        """
        for heading, text in sections
    )
    body = f"""
    <div class="legal-layout">
      <aside class="legal-index info-card">
        <h3>Sections</h3>
        {index_items}
      </aside>
      <article>
        <p class="eyebrow">Legal</p>
        <h1 style="font-size:44px;">{esc(title)}</h1>
        <p>{esc(effective)}</p>
        {cards}
      </article>
    </div>
    """
    return page(title, body, section="legal")


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "section"


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
    try:
        result = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=8)
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as exc:
        return {"ok": False, "error": f"stats command unavailable: {exc}"}
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


def create_feedback_request(data: dict[str, str]) -> tuple[int | None, str]:
    email = data.get("email", "").strip()
    message = data.get("message", "").strip()
    topic = data.get("topic", "Other").strip() or "Other"
    if topic not in SUPPORT_TOPICS:
        topic = "Other"
    if "@" not in email or "." not in email.rsplit("@", 1)[-1]:
        return None, "Please enter a valid email address."
    if len(message) < 8:
        return None, "Please include a short message."
    timestamp = now_iso()
    with db() as conn:
        cursor = conn.execute(
            """
            INSERT INTO feedback_requests(
                name,
                email,
                topic,
                message,
                ios_version,
                app_version,
                contact_consent,
                status,
                created_at,
                updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, 'new', ?, ?)
            """,
            (
                data.get("name", "").strip(),
                email,
                topic,
                message,
                data.get("ios_version", "").strip(),
                data.get("app_version", "").strip(),
                1 if data.get("contact_consent") else 0,
                timestamp,
                timestamp,
            ),
        )
        feedback_id = int(cursor.lastrowid)
    audit("support", "feedback.create", str(feedback_id), f"topic={topic}")
    return feedback_id, ""


def feedback_summary() -> dict[str, int]:
    with db() as conn:
        rows = conn.execute(
            """
            SELECT status, COUNT(*) AS count
            FROM feedback_requests
            GROUP BY status
            """
        ).fetchall()
    summary = {status: 0 for status in FEEDBACK_STATUSES}
    for row in rows:
        summary[str(row["status"])] = int(row["count"])
    return summary


def feedback_rows(status: str = "", topic: str = "", query: str = "") -> list[sqlite3.Row]:
    where: list[str] = []
    params: list[str] = []
    if status in FEEDBACK_STATUSES:
        where.append("status=?")
        params.append(status)
    if topic in SUPPORT_TOPICS:
        where.append("topic=?")
        params.append(topic)
    if query:
        where.append("(email LIKE ? OR message LIKE ? OR name LIKE ?)")
        term = f"%{query}%"
        params.extend([term, term, term])
    sql = "SELECT * FROM feedback_requests"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY created_at DESC, id DESC LIMIT 300"
    with db() as conn:
        return conn.execute(sql, params).fetchall()


def update_feedback_status(feedback_id: int, status: str) -> bool:
    if status not in FEEDBACK_STATUSES:
        return False
    with db() as conn:
        cursor = conn.execute(
            "UPDATE feedback_requests SET status=?, updated_at=? WHERE id=?",
            (status, now_iso(), feedback_id),
        )
    if cursor.rowcount:
        audit(ADMIN_USER, "feedback.status", str(feedback_id), f"status={status}")
        return True
    return False


def feedback_badge(status: str) -> str:
    classes = {
        "new": "warning",
        "in_review": "",
        "resolved": "good",
        "archived": "bad",
    }
    label = status.replace("_", " ")
    return f'<span class="badge {classes.get(status, "")}">{esc(label)}</span>'


def admin_feedback_html(status: str = "", topic: str = "", query: str = "") -> str:
    summary = feedback_summary()
    rows = feedback_rows(status=status, topic=topic, query=query)
    total = sum(summary.values())
    topic_options = '<option value="">All topics</option>' + "".join(
        f'<option value="{esc(item)}"{" selected" if topic == item else ""}>{esc(item)}</option>'
        for item in ["Bug", "Connection issue", "Billing / Premium", "Feature request", "Other"]
    )
    status_options = "".join(
        f'<option value="{esc(item)}"{" selected" if status == item else ""}>{esc(item.replace("_", " ") or "All statuses")}</option>'
        for item in ["", "new", "in_review", "resolved", "archived"]
    )
    table_rows = "".join(admin_feedback_row(row) for row in rows)
    newest = rows[0] if rows else None
    detail = (
        f"""
        <div class="panel">
          <h3>Latest feedback</h3>
          <p class="quiet">{esc(newest["created_at"])}</p>
          <p><strong>{esc(newest["topic"])}</strong><br>{esc(newest["email"])}</p>
          <div class="feedback-message">{esc(newest["message"])}</div>
        </div>
        """
        if newest
        else """
        <div class="panel">
          <h3>No matching feedback</h3>
          <p class="muted">New support submissions will appear here after users send the support form.</p>
        </div>
        """
    )
    body = f"""
    <div class="admin-title">
      <div>
        <p class="eyebrow">Admin operations</p>
        <h1 style="font-size:40px;">Feedback and VPN profile operations</h1>
        <p>Review support requests separately from generated VPN profiles.</p>
      </div>
      <a class="button secondary" href="/admin">Back to dashboard</a>
    </div>
    <div class="grid">
      <div class="metric-card panel"><div class="quiet">Total</div><div class="metric">{total}</div></div>
      <div class="metric-card panel"><div class="quiet">New</div><div class="metric">{summary["new"]}</div></div>
      <div class="metric-card panel"><div class="quiet">In review</div><div class="metric">{summary["in_review"]}</div></div>
      <div class="metric-card panel"><div class="quiet">Resolved</div><div class="metric">{summary["resolved"]}</div></div>
    </div>
    <div class="feedback-layout">
      <aside>
        {detail}
        <div class="panel">
          <h3>Status guide</h3>
          <p>{feedback_badge("new")} Waiting for first read</p>
          <p>{feedback_badge("in_review")} Being investigated</p>
          <p>{feedback_badge("resolved")} Answered or handled</p>
        </div>
      </aside>
      <section class="panel">
        <h2 style="font-size:24px;">Admin feedback</h2>
        <form class="filter-row" method="get" action="/admin/feedback">
          <p class="field"><label>Search</label><input name="q" value="{esc(query)}" placeholder="Search by email, name, or message"></p>
          <p class="field"><label>Topic</label><select name="topic">{topic_options}</select></p>
          <p class="field"><label>Status</label><select name="status">{status_options}</select></p>
          <p><button class="secondary" type="submit">Filter</button></p>
        </form>
        <div class="table-scroll">
          <table>
            <thead><tr><th>Date</th><th>Contact</th><th>Topic</th><th>Message</th><th>Status</th><th>Actions</th></tr></thead>
            <tbody>{table_rows or '<tr><td colspan="6" class="muted">No feedback yet.</td></tr>'}</tbody>
          </table>
        </div>
      </section>
    </div>
    """
    return page("Admin Feedback", body, section="admin")


def admin_feedback_row(row: sqlite3.Row) -> str:
    status_forms = "".join(
        f"""
        <form method="post" action="/admin/feedback/{row['id']}/status">
          <input type="hidden" name="status" value="{esc(status)}">
          <button class="secondary" type="submit">{esc(label)}</button>
        </form>
        """
        for status, label in [("in_review", "Review"), ("resolved", "Resolve"), ("archived", "Archive")]
        if row["status"] != status
    )
    meta = []
    if row["ios_version"]:
        meta.append(f"iOS {row['ios_version']}")
    if row["app_version"]:
        meta.append(f"App {row['app_version']}")
    return f"""
    <tr>
      <td>{esc(row["created_at"])}</td>
      <td><strong>{esc(row["name"] or "Anonymous")}</strong><br><span class="muted">{esc(row["email"])}</span></td>
      <td>{esc(row["topic"])}<br><span class="quiet">{esc(" / ".join(meta))}</span></td>
      <td><div class="feedback-message">{esc(row["message"])}</div></td>
      <td>{feedback_badge(row["status"])}</td>
      <td><div class="actions">{status_forms}</div></td>
    </tr>
    """


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
        feedback_counts = conn.execute(
            """
            SELECT
              COUNT(*) AS total_feedback,
              SUM(CASE WHEN status='new' THEN 1 ELSE 0 END) AS new_feedback
            FROM feedback_requests
            """
        ).fetchone()
    online_count = sum(1 for row in profiles if is_online(row["last_seen_at"]) and row["status"] == "active")
    stat_note = "" if stats.get("ok") else f"<p class='muted'>Stats collector: {esc(stats.get('error'))}</p>"
    rows = "".join(profile_row(row) for row in profiles)
    body = f"""
    <div class="admin-title">
      <div>
        <p class="eyebrow">Admin operations</p>
        <h1 style="font-size:40px;">VPN profiles and support feedback</h1>
        <p>Manage generated VPN profiles and review support requests from the public website.</p>
      </div>
      <a class="button primary" href="/admin/feedback">Open feedback</a>
    </div>
    <div class="grid">
      <div class="panel"><div class="muted">Active profiles</div><div class="metric">{totals["active_profiles"] or 0}</div></div>
      <div class="panel"><div class="muted">Online now</div><div class="metric">{online_count}</div></div>
      <div class="panel"><div class="muted">Uploaded</div><div class="metric">{fmt_bytes(totals["upload_bytes"])}</div></div>
      <div class="panel"><div class="muted">Downloaded</div><div class="metric">{fmt_bytes(totals["download_bytes"])}</div></div>
    </div>
    <div class="grid" style="grid-template-columns:repeat(2,minmax(0,1fr));">
      <div class="panel"><div class="muted">Feedback requests</div><div class="metric">{feedback_counts["total_feedback"] or 0}</div></div>
      <div class="panel"><div class="muted">New feedback</div><div class="metric">{feedback_counts["new_feedback"] or 0}</div></div>
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
      <div class="table-scroll">
        <table>
          <thead><tr><th>User</th><th>Device</th><th>Protocol</th><th>Status</th><th>Session</th><th>Traffic</th><th>Created</th><th>Actions</th></tr></thead>
          <tbody>{rows or '<tr><td colspan="8" class="muted">No profiles yet.</td></tr>'}</tbody>
        </table>
      </div>
    </div>
    """
    return page("Dashboard", body, section="admin")


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
      <p class="muted">Use this configuration URL in NetlumaVPN import.</p>
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
    return page("Profile", body, section="admin")


@app.on_event("startup")
def startup() -> None:
    init_db()
    sync_profile_urls()


@app.get("/", response_class=HTMLResponse)
async def root():
    return marketing_home_html()


@app.get("/favicon.ico")
async def favicon():
    return Response(status_code=204)


@app.get("/setup", response_class=HTMLResponse)
async def setup_get() -> str:
    return setup_page_html()


@app.get("/support", response_class=HTMLResponse)
async def support_get(request: Request) -> str:
    return support_page_html(request)


@app.post("/support", response_class=HTMLResponse)
async def support_post(request: Request):
    data = await form_data(request)
    _feedback_id, error = create_feedback_request(data)
    if error:
        return HTMLResponse(support_page_html(error=error, values=data), status_code=400)
    return RedirectResponse("/support?sent=1", status_code=303)


@app.get("/terms", response_class=HTMLResponse)
async def terms_get() -> str:
    return legal_page_html("terms")


@app.get("/privacy", response_class=HTMLResponse)
async def privacy_get() -> str:
    return legal_page_html("privacy")


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


@app.get("/admin/feedback", response_class=HTMLResponse)
async def admin_feedback(request: Request):
    redirect = require_admin(request)
    if redirect:
        return redirect
    return admin_feedback_html(
        status=request.query_params.get("status", ""),
        topic=request.query_params.get("topic", ""),
        query=request.query_params.get("q", "").strip(),
    )


@app.post("/admin/feedback/{feedback_id}/status")
async def admin_feedback_status(request: Request, feedback_id: int):
    redirect = require_admin(request)
    if redirect:
        return redirect
    data = await form_data(request)
    update_feedback_status(feedback_id, data.get("status", ""))
    return RedirectResponse("/admin/feedback", status_code=303)


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
