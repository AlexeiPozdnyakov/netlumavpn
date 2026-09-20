from __future__ import annotations

import base64
import hashlib
import hmac
import html
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import tempfile
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlsplit

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response


UTC = timezone.utc
USERNAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
VLESS_SERVER_ID = "netlumavpn-singbox-vless"
TROJAN_SERVER_ID = "netlumavpn-singbox-trojan"
SUPPORT_TOPICS = {"Bug", "Connection issue", "Billing / Premium", "Feature request", "Other"}
FEEDBACK_STATUSES = {"new", "in_review", "resolved", "archived"}


def env(name: str, default: str = "", legacy_name: str | None = None) -> str:
    if name in os.environ:
        return os.environ[name]
    if legacy_name and legacy_name in os.environ:
        return os.environ[legacy_name]
    return default


APP_STORE_URL = env("APP_STORE_URL", "https://apps.apple.com/search?term=NetlumaVPN")


def header_value(request: Request, name: str, legacy_name: str = "") -> str:
    value = request.headers.get(name, "")
    if value or not legacy_name:
        return value
    return request.headers.get(legacy_name, "")


def now_iso() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat()


def now_stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def validate_username(value: str) -> str:
    username = value.strip()
    if not username:
        alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        username = "".join(secrets.choice(alphabet) for _ in range(10))
    if not USERNAME_RE.fullmatch(username):
        raise ValueError("username must contain only English letters, numbers, _ and -")
    return username


def normalized_device_key(server_id: str, device_id: str) -> str:
    return hashlib.sha256(f"{server_id}:{device_id}".encode()).hexdigest()


def resolved_public_api_base_url(default_public_config_base_url: str = "") -> str:
    configured = env(
        "NETLUMAVPN_PUBLIC_API_BASE_URL",
        "",
        legacy_name="QUICKVPN_PUBLIC_API_BASE_URL",
    ).strip().rstrip("/")
    if configured:
        return configured
    parsed = urlsplit(default_public_config_base_url)
    if parsed.scheme and parsed.netloc:
        return f"{parsed.scheme}://{parsed.netloc}/api/v1"
    return "https://netlumavpn.example/api/v1"


def resolved_public_vpn_host(default_public_config_base_url: str = "") -> str:
    configured = env(
        "NETLUMAVPN_PUBLIC_VPN_HOST",
        "",
        legacy_name="QUICKVPN_PUBLIC_VPN_HOST",
    ).strip()
    if configured:
        return configured
    parsed = urlsplit(default_public_config_base_url)
    if parsed.hostname:
        return parsed.hostname
    return "netlumavpn.example"


@dataclass(frozen=True)
class CreatedSingBoxUser:
    name: str
    trojan_config_url: str
    vless_config_url: str


class SingBoxManager:
    def __init__(
        self,
        config_path: Path,
        client_dir: Path,
        public_base_url: str,
        backup_root: Path | None = None,
        check_config: Callable[[Path], None] | None = None,
        reload_service: Callable[[], None] | None = None,
    ):
        self.config_path = Path(config_path)
        self.client_dir = Path(client_dir)
        self.public_base_url = public_base_url.rstrip("/")
        self.backup_root = Path(backup_root) if backup_root else None
        self.check_config = check_config
        self.reload_service = reload_service

    def list_users(self) -> list[dict[str, Any]]:
        config = self._load_config()
        users: dict[str, dict[str, Any]] = {}
        for inbound in config.get("inbounds", []):
            protocol = inbound.get("type")
            if protocol not in {"trojan", "vless"}:
                continue
            for user in inbound.get("users", []):
                name = user.get("name")
                if not name:
                    continue
                row = users.setdefault(
                    name,
                    {
                        "username": name,
                        "trojan": False,
                        "vless": False,
                        "trojan_config_url": self._client_url(name, "TRJ"),
                        "vless_config_url": self._client_url(name, "VLESS"),
                    },
                )
                row[protocol] = True
        return sorted(users.values(), key=lambda row: row["username"])

    def create_user(self, requested_name: str) -> CreatedSingBoxUser:
        name = self._unique_name(validate_username(requested_name))
        config = self._load_config()
        trojan_password = self._unique_trojan_password(config)
        vless_uuid = self._unique_vless_uuid(config)

        self._inbound(config, "trojan")["users"].append({"name": name, "password": trojan_password})
        self._inbound(config, "vless")["users"].append({"name": name, "uuid": vless_uuid})

        self._backup(name)
        self._write_config(config)
        self._write_client_json(name, "trojan", "TRJ", "password", trojan_password)
        self._write_client_json(name, "vless", "VLESS", "uuid", vless_uuid)
        if self.reload_service:
            self.reload_service()
        return CreatedSingBoxUser(
            name=name,
            trojan_config_url=self._client_url(name, "TRJ"),
            vless_config_url=self._client_url(name, "VLESS"),
        )

    def delete_user(self, username: str) -> bool:
        username = validate_username(username)
        config = self._load_config()
        removed = False
        for protocol in ("trojan", "vless"):
            inbound = self._inbound(config, protocol)
            before = len(inbound["users"])
            inbound["users"] = [user for user in inbound["users"] if user.get("name") != username]
            removed = removed or len(inbound["users"]) != before
        if not removed:
            return False

        self._backup(username)
        self._write_config(config)
        for suffix in ("TRJ", "VLESS"):
            path = self.client_dir / f"{username}-{suffix}-CLIENT.json"
            if path.exists():
                path.unlink()
        if self.reload_service:
            self.reload_service()
        return True

    def read_client_json(self, username: str, server_id: str) -> dict[str, Any]:
        username = validate_username(username)
        suffix = "VLESS" if server_id == VLESS_SERVER_ID else "TRJ"
        path = self.client_dir / f"{username}-{suffix}-CLIENT.json"
        if not path.exists():
            raise FileNotFoundError(path)
        data = json.loads(path.read_text(encoding="utf-8"))
        self._rewrite_client_host(data)
        return data

    def _load_config(self) -> dict[str, Any]:
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    def _write_config(self, config: dict[str, Any]) -> None:
        original_stat = self.config_path.stat()
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=self.config_path.parent, delete=False) as handle:
            tmp_path = Path(handle.name)
            json.dump(config, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        try:
            if self.check_config:
                self.check_config(tmp_path)
            tmp_path.replace(self.config_path)
            os.chown(self.config_path, original_stat.st_uid, original_stat.st_gid)
            os.chmod(self.config_path, original_stat.st_mode & 0o777)
        finally:
            if tmp_path.exists():
                tmp_path.unlink()

    def _inbound(self, config: dict[str, Any], protocol: str) -> dict[str, Any]:
        for inbound in config.get("inbounds", []):
            if inbound.get("type") == protocol:
                inbound.setdefault("users", [])
                return inbound
        raise ValueError(f"{protocol} inbound not found")

    def _unique_name(self, base: str) -> str:
        existing = {row["username"] for row in self.list_users()}
        if base not in existing:
            return base
        for index in range(2, 1000):
            candidate = f"{base}_{index}"
            if candidate not in existing:
                return candidate
        raise ValueError("could not allocate unique user name")

    def _unique_trojan_password(self, config: dict[str, Any]) -> str:
        existing = {user.get("password") for inbound in config.get("inbounds", []) for user in inbound.get("users", [])}
        while True:
            password = "".join(secrets.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") for _ in range(30))
            if password not in existing:
                return password

    def _unique_vless_uuid(self, config: dict[str, Any]) -> str:
        existing = {user.get("uuid") for inbound in config.get("inbounds", []) for user in inbound.get("users", [])}
        while True:
            value = str(uuid.uuid4())
            if value not in existing:
                return value

    def _write_client_json(self, username: str, protocol: str, suffix: str, secret_key: str, secret_value: str) -> None:
        data = self._client_template(suffix)
        proxy = self._proxy_outbound(data)
        proxy["type"] = protocol
        proxy[secret_key] = secret_value
        proxy.pop("uuid" if secret_key == "password" else "password", None)
        self._rewrite_client_host(data)

        target = self.client_dir / f"{username}-{suffix}-CLIENT.json"
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=self.client_dir, delete=False) as handle:
            tmp_path = Path(handle.name)
            json.dump(data, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        tmp_path.replace(target)
        target.chmod(0o644)

    def _client_template(self, suffix: str) -> dict[str, Any]:
        for path in sorted(self.client_dir.glob(f"*-{suffix}-CLIENT.json")):
            return json.loads(path.read_text(encoding="utf-8"))
        raise ValueError(f"no {suffix} client template found in {self.client_dir}")

    def _proxy_outbound(self, data: dict[str, Any]) -> dict[str, Any]:
        for outbound in data.get("outbounds", []):
            if outbound.get("tag") == "proxy":
                return outbound
        raise ValueError("proxy outbound not found in client template")

    def _rewrite_client_host(self, data: dict[str, Any]) -> None:
        host = resolved_public_vpn_host(self.public_base_url)
        proxy = self._proxy_outbound(data)
        proxy["server"] = host

        tls = proxy.get("tls")
        if isinstance(tls, dict):
            tls["server_name"] = host

        transport = proxy.get("transport")
        if isinstance(transport, dict) and transport.get("type") in {"ws", "httpupgrade", "http_upgrade"}:
            headers = transport.setdefault("headers", {})
            if isinstance(headers, dict):
                headers["Host"] = host

    def _client_url(self, username: str, suffix: str) -> str:
        return f"{self.public_base_url}/{username}-{suffix}-CLIENT.json"

    def _backup(self, username: str) -> None:
        if not self.backup_root:
            return
        backup_dir = self.backup_root / f"{now_stamp()}-{username}"
        backup_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.config_path, backup_dir / "config.json")
        for path in self.client_dir.glob(f"{username}-*-CLIENT.json"):
            shutil.copy2(path, backup_dir / path.name)


class NetlumaVPNDatabase:
    def __init__(self, path: Path):
        self.path = Path(path)

    def connect(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.path)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA foreign_keys=ON")
        return conn

    def init(self) -> None:
        with self.connect() as conn:
            conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS profiles (
                    id TEXT PRIMARY KEY,
                    username TEXT NOT NULL UNIQUE,
                    user_name TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    server_id TEXT NOT NULL,
                    device_key TEXT,
                    status TEXT NOT NULL DEFAULT 'active',
                    source TEXT NOT NULL DEFAULT 'netlumavpn',
                    trojan_config_url TEXT NOT NULL,
                    vless_config_url TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    deleted_at TEXT
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

    def sync_existing_users(self, manager: SingBoxManager) -> None:
        with self.connect() as conn:
            for user in manager.list_users():
                exists = conn.execute("SELECT 1 FROM profiles WHERE username=?", (user["username"],)).fetchone()
                if exists:
                    continue
                conn.execute(
                    """
                    INSERT INTO profiles(
                      id, username, user_name, device_name, server_id, status, source,
                      trojan_config_url, vless_config_url, created_at
                    )
                    VALUES (?, ?, ?, ?, 'legacy', 'active', 'legacy', ?, ?, ?)
                    """,
                    (
                        str(uuid.uuid4()),
                        user["username"],
                        user["username"],
                        "Imported",
                        user["trojan_config_url"],
                        user["vless_config_url"],
                        now_iso(),
                    ),
                )

    def list_profiles(self) -> list[sqlite3.Row]:
        with self.connect() as conn:
            return conn.execute("SELECT * FROM profiles ORDER BY created_at DESC").fetchall()

    def get_profile(self, profile_id: str) -> sqlite3.Row | None:
        with self.connect() as conn:
            return conn.execute("SELECT * FROM profiles WHERE id=?", (profile_id,)).fetchone()

    def active_device_profile(self, server_id: str, device_key: str) -> sqlite3.Row | None:
        with self.connect() as conn:
            return conn.execute(
                """
                SELECT * FROM profiles
                WHERE server_id=? AND device_key=? AND status='active'
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (server_id, device_key),
            ).fetchone()

    def insert_profile(
        self,
        *,
        username: str,
        user_name: str,
        device_name: str,
        server_id: str,
        device_key: str | None,
        trojan_config_url: str,
        vless_config_url: str,
        source: str,
    ) -> sqlite3.Row:
        profile_id = str(uuid.uuid4())
        with self.connect() as conn:
            conn.execute(
                """
                INSERT INTO profiles(
                  id, username, user_name, device_name, server_id, device_key,
                  status, source, trojan_config_url, vless_config_url, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)
                """,
                (
                    profile_id,
                    username,
                    user_name,
                    device_name,
                    server_id,
                    device_key,
                    source,
                    trojan_config_url,
                    vless_config_url,
                    now_iso(),
                ),
            )
            return conn.execute("SELECT * FROM profiles WHERE id=?", (profile_id,)).fetchone()

    def delete_profile(self, profile_id: str, manager: SingBoxManager) -> bool:
        row = self.get_profile(profile_id)
        if not row or row["status"] == "deleted":
            return False
        manager.delete_user(row["username"])
        with self.connect() as conn:
            conn.execute("UPDATE profiles SET status='deleted', deleted_at=? WHERE id=?", (now_iso(), profile_id))
        return True

    def create_feedback_request(self, data: dict[str, str]) -> tuple[int | None, str]:
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
        with self.connect() as conn:
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
                    data.get("name", "").strip() or None,
                    email,
                    topic,
                    message,
                    data.get("ios_version", "").strip() or None,
                    data.get("app_version", "").strip() or None,
                    1 if data.get("contact_consent") else 0,
                    timestamp,
                    timestamp,
                ),
            )
            return int(cursor.lastrowid), ""

    def feedback_summary(self) -> dict[str, int]:
        with self.connect() as conn:
            rows = conn.execute(
                """
                SELECT status, COUNT(*) AS count
                FROM feedback_requests
                GROUP BY status
                """
            ).fetchall()
        summary = {status: 0 for status in FEEDBACK_STATUSES}
        summary["total"] = 0
        for row in rows:
            status = row["status"] if row["status"] in FEEDBACK_STATUSES else "new"
            summary[status] = int(row["count"])
            summary["total"] += int(row["count"])
        return summary

    def feedback_rows(self, status: str = "", topic: str = "", query: str = "") -> list[sqlite3.Row]:
        clauses: list[str] = []
        params: list[str] = []
        if status in FEEDBACK_STATUSES:
            clauses.append("status=?")
            params.append(status)
        if topic in SUPPORT_TOPICS:
            clauses.append("topic=?")
            params.append(topic)
        if query:
            clauses.append("(email LIKE ? OR name LIKE ? OR message LIKE ?)")
            term = f"%{query}%"
            params.extend([term, term, term])
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        with self.connect() as conn:
            return conn.execute(
                f"""
                SELECT *
                FROM feedback_requests
                {where}
                ORDER BY created_at DESC
                LIMIT 200
                """,
                params,
            ).fetchall()

    def update_feedback_status(self, feedback_id: int, status: str) -> bool:
        if status not in FEEDBACK_STATUSES:
            return False
        with self.connect() as conn:
            cursor = conn.execute(
                """
                UPDATE feedback_requests
                SET status=?, updated_at=?
                WHERE id=?
                """,
                (status, now_iso(), feedback_id),
            )
            return cursor.rowcount > 0


def issue_mobile_profile(
    *,
    database: NetlumaVPNDatabase,
    manager: SingBoxManager,
    server_id: str,
    device_id: str,
    device_name: str,
    api_base_url: str | None = None,
) -> dict[str, Any]:
    if server_id not in {VLESS_SERVER_ID, TROJAN_SERVER_ID}:
        raise ValueError("unknown server")
    device_key = normalized_device_key(server_id, device_id)
    existing = database.active_device_profile(server_id, device_key)
    if existing:
        return mobile_profile_payload(existing, api_base_url or resolved_public_api_base_url(manager.public_base_url))

    username = f"qv_{device_key[:16]}"
    created = manager.create_user(username)
    row = database.insert_profile(
        username=created.name,
        user_name=f"Mobile {device_key[:8]}",
        device_name=device_name.strip() or "iPhone",
        server_id=server_id,
        device_key=device_key,
        trojan_config_url=created.trojan_config_url,
        vless_config_url=created.vless_config_url,
        source="mobile",
    )
    return mobile_profile_payload(row, api_base_url or resolved_public_api_base_url(manager.public_base_url))


def profile_payload(row: sqlite3.Row) -> dict[str, Any]:
    config_url = row["vless_config_url"] if row["server_id"] == VLESS_SERVER_ID else row["trojan_config_url"]
    return {
        "ok": True,
        "profile_id": row["id"],
        "username": row["username"],
        "server_id": row["server_id"],
        "protocol": "VLESS JSON" if row["server_id"] == VLESS_SERVER_ID else "Trojan JSON",
        "config_format": "sing-box-json",
        "config_url": config_url,
        "vless_config_url": row["vless_config_url"],
        "trojan_config_url": row["trojan_config_url"],
    }


def mobile_profile_payload(row: sqlite3.Row, api_base_url: str) -> dict[str, Any]:
    return {
        "ok": True,
        "profile_id": row["id"],
        "username": row["username"],
        "server_id": row["server_id"],
        "protocol": "vless" if row["server_id"] == VLESS_SERVER_ID else "trojan",
        "config_format": "sing-box-json",
        "config_url": f"{api_base_url.rstrip('/')}/mobile/profiles/{row['id']}/config",
    }


def mobile_config_payload(
    *,
    database: NetlumaVPNDatabase,
    manager: SingBoxManager,
    profile_id: str,
    device_id: str,
) -> dict[str, Any]:
    row = database.get_profile(profile_id)
    if not row or row["status"] != "active" or row["source"] != "mobile":
        raise FileNotFoundError(profile_id)
    expected_device_key = normalized_device_key(row["server_id"], device_id)
    if not row["device_key"] or not hmac.compare_digest(row["device_key"], expected_device_key):
        raise PermissionError("device does not own this profile")
    return manager.read_client_json(row["username"], row["server_id"])


def run_command(args: list[str]) -> None:
    subprocess.run(args, check=True, capture_output=True, text=True, timeout=20)


def build_manager() -> SingBoxManager:
    config_path = Path(env("SINGBOX_CONFIG_PATH", "/etc/sing-box/config.json"))
    client_dir = Path(env("SINGBOX_CLIENT_DIR", "/var/www/ho0aWfb3s3S2KtqYOIqUkHwrOSdXOA"))
    public_base_url = env(
        "NETLUMAVPN_PUBLIC_CONFIG_BASE_URL",
        "https://netlumavpn.example/ho0aWfb3s3S2KtqYOIqUkHwrOSdXOA",
        legacy_name="QUICKVPN_PUBLIC_CONFIG_BASE_URL",
    )
    backup_root = Path(env("SINGBOX_ADMIN_BACKUP_DIR", "/root/quickvpn-singbox-api-backups"))
    sing_box_bin = env("SINGBOX_BIN", "/usr/bin/sing-box")

    def check_config(path: Path) -> None:
        run_command([sing_box_bin, "check", "-c", str(path)])

    def reload_service() -> None:
        run_command(["/bin/systemctl", "reload", "sing-box.service"])

    return SingBoxManager(config_path, client_dir, public_base_url, backup_root, check_config, reload_service)


def build_database() -> NetlumaVPNDatabase:
    return NetlumaVPNDatabase(
        Path(
            env(
                "NETLUMAVPN_DB_PATH",
                "/opt/quickvpn-singbox-api/data/quickvpn.sqlite3",
                legacy_name="QUICKVPN_DB_PATH",
            )
        )
    )


manager = build_manager()
database = build_database()
app = FastAPI(title="NetlumaVPN sing-box API")


def check_basic_auth(request: Request) -> bool:
    expected_user = env("ADMIN_USER", "admin")
    expected_password = env("ADMIN_PASSWORD", "")
    header = request.headers.get("authorization", "")
    if not expected_password or not header.lower().startswith("basic "):
        return False
    try:
        user, password = base64.b64decode(header.split(" ", 1)[1]).decode().split(":", 1)
    except Exception:
        return False
    return hmac.compare_digest(user, expected_user) and hmac.compare_digest(password, expected_password)


def unauthorized() -> JSONResponse:
    return JSONResponse(
        {"ok": False, "error": "unauthorized"},
        status_code=401,
        headers={"WWW-Authenticate": 'Basic realm="NetlumaVPN Admin"'},
    )


def check_admin_api_key(request: Request) -> bool:
    api_key = env("API_KEY")
    return bool(api_key) and hmac.compare_digest(
        header_value(request, "x-netlumavpn-api-key", legacy_name="x-quickvpn-api-key"),
        api_key,
    )


def check_mobile_key(request: Request) -> bool:
    mobile_key = env("MOBILE_API_KEY")
    return bool(mobile_key) and hmac.compare_digest(
        header_value(request, "x-netlumavpn-client-key", legacy_name="x-quickvpn-client-key"),
        mobile_key,
    )


async def form_data(request: Request) -> dict[str, str]:
    parsed = parse_qs((await request.body()).decode(), keep_blank_values=True)
    return {key: values[-1] for key, values in parsed.items()}


def esc(value: Any) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def app_store_link(label: str = "Download on the App Store", class_name: str = "button primary") -> str:
    return f'<a class="{esc(class_name)}" href="{esc(APP_STORE_URL)}" rel="noopener">{esc(label)}</a>'


def brand_mark() -> str:
    return '<span class="brand-mark">N</span><span><strong>NetlumaVPN</strong><small>Secure iOS VPN client</small></span>'


def page(title: str, body: str, *, section: str = "public", language: str = "en") -> str:
    is_admin = section == "admin"
    nav = (
        """
        <a href="/admin">Profiles</a>
        <a href="/admin/feedback">Feedback</a>
        <a href="/api/v1/status">API status</a>
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
      --line:#2A3349;
      --line-soft:#1F2638;
      --text:#FFFFFF;
      --muted:#94A3B8;
      --quiet:#64748B;
      --accent:#34D399;
      --accent-glow:#34D39933;
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
    .status-pill {{ background:rgba(52,211,153,.12); color:var(--accent); border-radius:999px; padding:5px 9px; font-size:10px; font-weight:800; }}
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
    .badge.good {{ background:rgba(52,211,153,.12); color:var(--accent); border-color:rgba(52,211,153,.35); }}
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
    .success-box {{ background:rgba(52,211,153,.12); color:var(--accent); border:1px solid rgba(52,211,153,.35); }}
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


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "section"


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


def feedback_badge(status: str) -> str:
    label = {
        "new": "New",
        "in_review": "In review",
        "resolved": "Resolved",
        "archived": "Archived",
    }.get(status, "New")
    badge_class = "good" if status == "resolved" else "warning" if status == "in_review" else ""
    return f'<span class="badge {badge_class}">{esc(label)}</span>'


def admin_feedback_row(row: sqlite3.Row) -> str:
    actions = "".join(
        f"""
        <form method="post" action="/admin/feedback/{int(row["id"])}/status">
          <input type="hidden" name="status" value="{esc(status)}">
          <button class="secondary" type="submit">{esc(label)}</button>
        </form>
        """
        for status, label in [("in_review", "Review"), ("resolved", "Resolve"), ("archived", "Archive")]
        if row["status"] != status
    )
    return f"""
    <tr>
      <td>{feedback_badge(str(row["status"]))}<br><span class="quiet">#{int(row["id"])}</span></td>
      <td><strong>{esc(row["topic"])}</strong><br><span class="quiet">{esc(row["created_at"])}</span></td>
      <td>{esc(row["email"])}<br><span class="quiet">{esc(row["name"] or "No name")}</span></td>
      <td><div class="feedback-message">{esc(row["message"])}</div><span class="quiet">iOS: {esc(row["ios_version"] or "-")} · App: {esc(row["app_version"] or "-")}</span></td>
      <td><div class="actions">{actions}</div></td>
    </tr>
    """


def admin_feedback_html(status: str = "", topic: str = "", query: str = "") -> str:
    summary = database.feedback_summary()
    rows = database.feedback_rows(status=status, topic=topic, query=query.strip())
    status_options = "".join(
        f'<option value="{esc(option)}"{" selected" if status == option else ""}>{esc(option.replace("_", " ").title() or "All statuses")}</option>'
        for option in ["", "new", "in_review", "resolved", "archived"]
    )
    topic_options = "".join(
        f'<option value="{esc(option)}"{" selected" if topic == option else ""}>{esc(option or "All topics")}</option>'
        for option in ["", "Bug", "Connection issue", "Billing / Premium", "Feature request", "Other"]
    )
    table_rows = "".join(admin_feedback_row(row) for row in rows) or """
    <tr><td colspan="5"><p class="muted">No feedback matches this filter.</p></td></tr>
    """
    body = f"""
    <div class="admin-title">
      <div>
        <p class="eyebrow">Admin Feedback</p>
        <h1 style="font-size:42px;">Support feedback</h1>
        <p>Review messages submitted from the public support page.</p>
      </div>
      <a class="button secondary" href="/admin">Back to profiles</a>
    </div>
    <div class="grid">
      <section class="metric-card panel"><p class="muted">Total</p><div class="metric">{summary["total"]}</div></section>
      <section class="metric-card panel"><p class="muted">New</p><div class="metric">{summary["new"]}</div></section>
      <section class="metric-card panel"><p class="muted">In review</p><div class="metric">{summary["in_review"]}</div></section>
      <section class="metric-card panel"><p class="muted">Resolved</p><div class="metric">{summary["resolved"]}</div></section>
    </div>
    <section class="panel">
      <form class="filter-row" method="get" action="/admin/feedback">
        <div><label>Search</label><input name="q" value="{esc(query)}" placeholder="Email, name, message"></div>
        <div><label>Status</label><select name="status">{status_options}</select></div>
        <div><label>Topic</label><select name="topic">{topic_options}</select></div>
        <button class="primary" type="submit">Filter</button>
      </form>
      <div class="table-scroll">
        <table>
          <thead><tr><th>Status</th><th>Topic</th><th>Sender</th><th>Message</th><th>Actions</th></tr></thead>
          <tbody>{table_rows}</tbody>
        </table>
      </div>
    </section>
    """
    return page("Admin Feedback", body, section="admin")


@app.on_event("startup")
def startup() -> None:
    database.init()
    database.sync_existing_users(manager)


@app.get("/", response_class=HTMLResponse)
async def marketing_home():
    return marketing_home_html()


@app.get("/favicon.ico")
async def favicon():
    return Response(status_code=204)


@app.get("/setup", response_class=HTMLResponse)
async def setup() -> str:
    return setup_page_html()


@app.get("/support", response_class=HTMLResponse)
async def support(request: Request):
    return support_page_html(request)


@app.post("/support", response_class=HTMLResponse)
async def support_submit(request: Request):
    data = await form_data(request)
    _, error = database.create_feedback_request(data)
    if error:
        return HTMLResponse(support_page_html(request, error=error, values=data), status_code=400)
    return RedirectResponse("/support?sent=1", status_code=303)


@app.get("/terms", response_class=HTMLResponse)
async def terms():
    return legal_page_html("terms")


@app.get("/privacy", response_class=HTMLResponse)
async def privacy():
    return legal_page_html("privacy")


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "time": now_iso()}


@app.get("/admin", response_class=HTMLResponse)
async def admin(request: Request):
    if not check_basic_auth(request):
        return unauthorized()
    database.sync_existing_users(manager)
    summary = database.feedback_summary()
    rows = []
    for row in database.list_profiles():
        delete_form = ""
        if row["status"] == "active":
            delete_form = (
                f"<form method='post' action='/admin/profiles/{esc(row['id'])}/delete' "
                f"onsubmit=\"return confirm('Delete {esc(row['username'])}?');\">"
                "<button class='danger' type='submit'>Delete</button></form>"
            )
        rows.append(
            f"<tr><td>{esc(row['username'])}</td><td>{esc(row['source'])}</td><td>{esc(row['status'])}</td>"
            f"<td>{esc(row['server_id'])}</td><td><a href='{esc(row['vless_config_url'])}'>VLESS JSON</a><br>"
            f"<a href='{esc(row['trojan_config_url'])}'>Trojan JSON</a></td><td>{delete_form}</td></tr>"
        )
    body = f"""
    <div class="admin-title">
      <div>
        <p class="eyebrow">Admin</p>
        <h1 style="font-size:42px;">Profiles</h1>
        <p>This admin manages the existing sing-box config and keeps a NetlumaVPN SQLite registry.</p>
      </div>
      <a class="button secondary" href="/admin/feedback">Open feedback · {summary["new"]} new</a>
    </div>
    <div class="grid" style="grid-template-columns:repeat(3,minmax(0,1fr));">
      <section class="metric-card panel"><p class="muted">Profiles</p><div class="metric">{len(database.list_profiles())}</div></section>
      <section class="metric-card panel"><p class="muted">Feedback</p><div class="metric">{summary["total"]}</div></section>
      <section class="metric-card panel"><p class="muted">New feedback</p><div class="metric">{summary["new"]}</div></section>
    </div>
    <section class="panel">
      <h2 style="font-size:24px;">Create profile</h2>
      <p class="muted">This admin manages the existing sing-box config and keeps a NetlumaVPN SQLite registry.</p>
      <form method="post" action="/admin/profiles">
        <input name="username" placeholder="username, SSB-safe">
        <button type="submit">Create Trojan + VLESS</button>
      </form>
    </section>
    <section class="panel">
      <div class="table-scroll">
        <table>
          <thead><tr><th>Username</th><th>Source</th><th>Status</th><th>Server</th><th>Configs</th><th>Actions</th></tr></thead>
          <tbody>{''.join(rows)}</tbody>
        </table>
      </div>
    </section>
    """
    return page("NetlumaVPN Admin", body, section="admin")


@app.get("/admin/feedback", response_class=HTMLResponse)
async def admin_feedback(request: Request, status: str = "", topic: str = "", q: str = ""):
    if not check_basic_auth(request):
        return unauthorized()
    return admin_feedback_html(status=status, topic=topic, query=q)


@app.post("/admin/feedback/{feedback_id}/status")
async def admin_feedback_status(request: Request, feedback_id: int):
    if not check_basic_auth(request):
        return unauthorized()
    data = await form_data(request)
    database.update_feedback_status(feedback_id, data.get("status", ""))
    return RedirectResponse("/admin/feedback", status_code=303)


@app.post("/admin/profiles")
async def admin_create_profile(request: Request):
    if not check_basic_auth(request):
        return unauthorized()
    data = await form_data(request)
    created = manager.create_user(data.get("username", ""))
    database.insert_profile(
        username=created.name,
        user_name=created.name,
        device_name="Admin",
        server_id="admin",
        device_key=None,
        trojan_config_url=created.trojan_config_url,
        vless_config_url=created.vless_config_url,
        source="admin",
    )
    return RedirectResponse("/admin", status_code=303)


@app.post("/admin/profiles/{profile_id}/delete")
async def admin_delete_profile(request: Request, profile_id: str):
    if not check_basic_auth(request):
        return unauthorized()
    database.delete_profile(profile_id, manager)
    return RedirectResponse("/admin", status_code=303)


@app.get("/api/v1/status")
async def api_status() -> dict[str, Any]:
    return {"ok": True, "backend": "netlumavpn-singbox", "time": now_iso()}


@app.post("/api/v1/profiles")
async def api_create_profile(request: Request):
    if not check_admin_api_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    payload = await request.json()
    created = manager.create_user(str(payload.get("username") or payload.get("user_name") or ""))
    row = database.insert_profile(
        username=created.name,
        user_name=str(payload.get("user_name") or created.name),
        device_name=str(payload.get("device_name") or "API"),
        server_id="api",
        device_key=None,
        trojan_config_url=created.trojan_config_url,
        vless_config_url=created.vless_config_url,
        source="api",
    )
    return JSONResponse(profile_payload(row))


@app.delete("/api/v1/profiles/{profile_id}")
async def api_delete_profile(request: Request, profile_id: str):
    if not check_admin_api_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    return JSONResponse({"ok": database.delete_profile(profile_id, manager)})


@app.get("/api/v1/mobile/servers")
async def mobile_servers(request: Request):
    if not check_mobile_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    return JSONResponse(
        {
            "ok": True,
            "servers": [
                {
                    "id": VLESS_SERVER_ID,
                    "name": "NetlumaVPN VLESS",
                    "country": "Germany",
                    "city": "Nuremberg",
                    "region": "Europe",
                    "protocol": "VLESS JSON",
                    "config_format": "sing-box-json",
                    "is_available": True,
                    "ip_mode": "ipv4_only",
                },
                {
                    "id": TROJAN_SERVER_ID,
                    "name": "NetlumaVPN Trojan",
                    "country": "Germany",
                    "city": "Nuremberg",
                    "region": "Europe",
                    "protocol": "Trojan JSON",
                    "config_format": "sing-box-json",
                    "is_available": True,
                    "ip_mode": "ipv4_only",
                },
            ],
        }
    )


@app.post("/api/v1/mobile/servers/{server_id}/profile")
async def mobile_profile(request: Request, server_id: str):
    if not check_mobile_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    device_id = header_value(
        request,
        "x-netlumavpn-device-id",
        legacy_name="x-quickvpn-device-id",
    ).strip()
    if len(device_id) < 20 or len(device_id) > 128:
        return JSONResponse({"ok": False, "error": "invalid_device"}, status_code=400)
    payload = await request.json()
    try:
        result = issue_mobile_profile(
            database=database,
            manager=manager,
            server_id=server_id,
            device_id=device_id,
            device_name=str(payload.get("device_name") or "iPhone"),
            api_base_url=resolved_public_api_base_url(manager.public_base_url),
        )
    except ValueError:
        return JSONResponse({"ok": False, "error": "unknown_server"}, status_code=404)
    return JSONResponse(result)


@app.get("/api/v1/mobile/profiles/{profile_id}/config")
async def mobile_profile_config(request: Request, profile_id: str):
    if not check_mobile_key(request):
        return JSONResponse({"ok": False, "error": "unauthorized"}, status_code=401)
    device_id = header_value(
        request,
        "x-netlumavpn-device-id",
        legacy_name="x-quickvpn-device-id",
    ).strip()
    if len(device_id) < 20 or len(device_id) > 128:
        return JSONResponse({"ok": False, "error": "invalid_device"}, status_code=400)
    try:
        payload = mobile_config_payload(
            database=database,
            manager=manager,
            profile_id=profile_id,
            device_id=device_id,
        )
    except PermissionError:
        return JSONResponse({"ok": False, "error": "forbidden"}, status_code=403)
    except FileNotFoundError:
        return JSONResponse({"ok": False, "error": "not_found"}, status_code=404)
    return JSONResponse(payload, headers={"Cache-Control": "no-store"})


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=env("NETLUMAVPN_HOST", "127.0.0.1", legacy_name="QUICKVPN_HOST"),
        port=int(env("NETLUMAVPN_PORT", "8020", legacy_name="QUICKVPN_PORT")),
    )
