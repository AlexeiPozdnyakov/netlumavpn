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
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse


UTC = timezone.utc
USERNAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
VLESS_SERVER_ID = "netlumavpn-singbox-vless"
TROJAN_SERVER_ID = "netlumavpn-singbox-trojan"


def env(name: str, default: str = "", legacy_name: str | None = None) -> str:
    if name in os.environ:
        return os.environ[name]
    if legacy_name and legacy_name in os.environ:
        return os.environ[legacy_name]
    return default


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


def page(title: str, body: str) -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <style>
    body {{ margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f7fb; color: #152033; }}
    header {{ padding: 18px 24px; background: #102a63; color: white; }}
    main {{ max-width: 1120px; margin: 24px auto; padding: 0 18px 40px; }}
    section {{ background: white; border: 1px solid #dde5f0; border-radius: 8px; padding: 18px; margin-bottom: 16px; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th, td {{ text-align: left; border-bottom: 1px solid #e4e9f2; padding: 10px 8px; vertical-align: top; }}
    th {{ color: #667085; font-weight: 650; }}
    input {{ border: 1px solid #cfd8e6; border-radius: 6px; padding: 10px 12px; min-width: 220px; }}
    button, a.button {{ border: 0; border-radius: 6px; padding: 9px 12px; background: #2457d6; color: white; font-weight: 700; text-decoration: none; cursor: pointer; display: inline-block; }}
    button.danger {{ background: #b42318; }}
    .muted {{ color: #667085; }}
    .actions {{ display: flex; gap: 8px; flex-wrap: wrap; }}
  </style>
</head>
<body>
  <header><strong>NetlumaVPN API/Admin</strong></header>
  <main>{body}</main>
</body>
</html>"""


@app.on_event("startup")
def startup() -> None:
    database.init()
    database.sync_existing_users(manager)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "time": now_iso()}


@app.get("/admin", response_class=HTMLResponse)
async def admin(request: Request):
    if not check_basic_auth(request):
        return unauthorized()
    database.sync_existing_users(manager)
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
    <section>
      <h1>Profiles</h1>
      <p class="muted">This admin manages the existing sing-box config and keeps a NetlumaVPN SQLite registry.</p>
      <form method="post" action="/admin/profiles">
        <input name="username" placeholder="username, SSB-safe">
        <button type="submit">Create Trojan + VLESS</button>
      </form>
    </section>
    <section>
      <table>
        <thead><tr><th>Username</th><th>Source</th><th>Status</th><th>Server</th><th>Configs</th><th>Actions</th></tr></thead>
        <tbody>{''.join(rows)}</tbody>
      </table>
    </section>
    """
    return page("NetlumaVPN Admin", body)


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
