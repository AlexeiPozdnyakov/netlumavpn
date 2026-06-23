from __future__ import annotations

import base64
import hmac
import html
import json
import os
import re
import secrets
import shutil
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse


UTC = timezone.utc
USERNAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def now_stamp() -> str:
    return datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")


def generated_username() -> str:
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    return "".join(secrets.choice(alphabet) for _ in range(10))


def validate_username(value: str) -> str:
    username = value.strip() or generated_username()
    if not USERNAME_RE.fullmatch(username):
        raise ValueError("username must contain only English letters, numbers, _ and -")
    return username


class SingBoxStore:
    def __init__(
        self,
        config_path: Path,
        client_dir: Path,
        backup_root: Path | None = None,
        check_config: Callable[[Path], None] | None = None,
    ):
        self.config_path = Path(config_path)
        self.client_dir = Path(client_dir)
        self.backup_root = Path(backup_root) if backup_root else None
        self.check_config = check_config

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
                        "name": name,
                        "trojan": False,
                        "vless": False,
                        "trojan_json": self.client_dir / f"{name}-TRJ-CLIENT.json",
                        "vless_json": self.client_dir / f"{name}-VLESS-CLIENT.json",
                    },
                )
                row[protocol] = True
        return sorted(users.values(), key=lambda row: row["name"])

    def create_user(self, requested_name: str) -> dict[str, str]:
        name = self._unique_name(validate_username(requested_name))
        config = self._load_config()
        trojan_password = secrets.token_urlsafe(24)
        vless_uuid = str(uuid.uuid4())

        self._inbound(config, "trojan")["users"].append({"name": name, "password": trojan_password})
        self._inbound(config, "vless")["users"].append({"name": name, "uuid": vless_uuid})

        self._backup(name)
        self._write_config(config)
        self._write_client_json(name, "trojan", "TRJ", "password", trojan_password)
        self._write_client_json(name, "vless", "VLESS", "uuid", vless_uuid)
        return {"name": name}

    def delete_user(self, name: str) -> bool:
        name = validate_username(name)
        config = self._load_config()
        removed = False
        for protocol in ("trojan", "vless"):
            inbound = self._inbound(config, protocol)
            before = len(inbound["users"])
            inbound["users"] = [user for user in inbound["users"] if user.get("name") != name]
            removed = removed or len(inbound["users"]) != before
        if not removed:
            return False

        self._backup(name)
        self._write_config(config)
        for suffix in ("TRJ", "VLESS"):
            path = self.client_dir / f"{name}-{suffix}-CLIENT.json"
            if path.exists():
                path.unlink()
        return True

    def _load_config(self) -> dict[str, Any]:
        return json.loads(self.config_path.read_text(encoding="utf-8"))

    def _write_config(self, config: dict[str, Any]) -> None:
        original_stat = self.config_path.stat()
        self.config_path.parent.mkdir(parents=True, exist_ok=True)
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
        existing = {row["name"] for row in self.list_users()}
        if base not in existing:
            return base
        for index in range(2, 1000):
            candidate = f"{base}-{index}"
            if candidate not in existing:
                return candidate
        raise ValueError("could not allocate unique user name")

    def _write_client_json(self, name: str, protocol: str, suffix: str, secret_key: str, secret_value: str) -> None:
        template = self._client_template(suffix)
        proxy = self._proxy_outbound(template)
        proxy["type"] = protocol
        proxy[secret_key] = secret_value
        other_secret = "uuid" if secret_key == "password" else "password"
        proxy.pop(other_secret, None)

        target = self.client_dir / f"{name}-{suffix}-CLIENT.json"
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=self.client_dir, delete=False) as handle:
            tmp_path = Path(handle.name)
            json.dump(template, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        tmp_path.replace(target)
        target.chmod(0o644)

    def _client_template(self, suffix: str) -> dict[str, Any]:
        pattern = f"*-{suffix}-CLIENT.json"
        for path in sorted(self.client_dir.glob(pattern)):
            return json.loads(path.read_text(encoding="utf-8"))
        raise ValueError(f"no {suffix} client template found in {self.client_dir}")

    def _proxy_outbound(self, data: dict[str, Any]) -> dict[str, Any]:
        for outbound in data.get("outbounds", []):
            if outbound.get("tag") == "proxy":
                return outbound
        raise ValueError("proxy outbound not found in client template")

    def _backup(self, name: str) -> None:
        if not self.backup_root:
            return
        backup_dir = self.backup_root / f"{now_stamp()}-{name}"
        backup_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.config_path, backup_dir / "config.json")
        for path in self.client_dir.glob(f"{name}-*-CLIENT.json"):
            shutil.copy2(path, backup_dir / path.name)


def run_command(args: list[str]) -> None:
    subprocess.run(args, check=True, capture_output=True, text=True, timeout=20)


def build_store() -> SingBoxStore:
    config_path = Path(os.environ.get("SINGBOX_CONFIG_PATH", "/etc/sing-box/config.json"))
    client_dir = Path(os.environ.get("SINGBOX_CLIENT_DIR", "/var/www/ho0aWfb3s3S2KtqYOIqUkHwrOSdXOA"))
    backup_root = Path(os.environ.get("SINGBOX_ADMIN_BACKUP_DIR", "/root/quickvpn-singbox-admin-backups"))
    sing_box_bin = os.environ.get("SINGBOX_BIN", "/usr/bin/sing-box")

    def check_config(path: Path) -> None:
        run_command([sing_box_bin, "check", "-c", str(path)])

    return SingBoxStore(config_path, client_dir, backup_root, check_config)


def reload_sing_box() -> None:
    run_command(["/bin/systemctl", "reload", "sing-box"])


def page(title: str, body: str) -> bytes:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    body {{ margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f5f7fb; color: #152033; }}
    header {{ padding: 18px 24px; background: #102a63; color: white; }}
    main {{ max-width: 1040px; margin: 24px auto; padding: 0 18px 40px; }}
    section {{ background: white; border: 1px solid #dde5f0; border-radius: 8px; padding: 18px; margin-bottom: 16px; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ text-align: left; border-bottom: 1px solid #e4e9f2; padding: 10px 8px; vertical-align: middle; }}
    th {{ color: #667085; font-weight: 650; }}
    input {{ border: 1px solid #cfd8e6; border-radius: 6px; padding: 10px 12px; min-width: 260px; }}
    button, a.button {{ border: 0; border-radius: 6px; padding: 9px 12px; background: #2457d6; color: white; font-weight: 700; text-decoration: none; cursor: pointer; display: inline-block; }}
    button.danger {{ background: #b42318; }}
    .muted {{ color: #667085; }}
    .actions {{ display: flex; gap: 8px; flex-wrap: wrap; }}
  </style>
</head>
<body>
  <header><strong>NetlumaVPN sing-box admin</strong></header>
  <main>{body}</main>
</body>
</html>""".encode()


class AdminHandler(BaseHTTPRequestHandler):
    store = build_store()
    admin_user = os.environ.get("SINGBOX_ADMIN_USER", "admin")
    admin_password = os.environ.get("SINGBOX_ADMIN_PASSWORD", "")

    def do_GET(self) -> None:
        if not self._authorized():
            return self._unauthorized()
        parsed = urlparse(self.path)
        if parsed.path == "/download":
            return self._download(parse_qs(parsed.query).get("file", [""])[0])
        if parsed.path != "/":
            return self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
        return self._dashboard()

    def do_POST(self) -> None:
        if not self._authorized():
            return self._unauthorized()
        length = int(self.headers.get("content-length", "0"))
        data = parse_qs(self.rfile.read(length).decode())
        parsed = urlparse(self.path)
        try:
            if parsed.path == "/users":
                self.store.create_user(data.get("name", [""])[0])
                reload_sing_box()
                return self._redirect("/")
            if parsed.path == "/users/delete":
                self.store.delete_user(data.get("name", [""])[0])
                reload_sing_box()
                return self._redirect("/")
        except Exception as exc:
            return self._send(HTTPStatus.INTERNAL_SERVER_ERROR, page("Error", f"<section><h1>Error</h1><p>{html.escape(str(exc))}</p><p><a class='button' href='/'>Back</a></p></section>"))
        return self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")

    def _dashboard(self) -> None:
        rows = []
        for user in self.store.list_users():
            name = html.escape(user["name"])
            trojan_link = self._download_link(user["trojan_json"])
            vless_link = self._download_link(user["vless_json"])
            rows.append(
                f"<tr><td>{name}</td><td>{'yes' if user['trojan'] else 'no'}</td><td>{'yes' if user['vless'] else 'no'}</td>"
                f"<td><div class='actions'>{trojan_link}{vless_link}"
                f"<form method='post' action='/users/delete' onsubmit=\"return confirm('Delete {name}?');\">"
                f"<input type='hidden' name='name' value='{name}'><button class='danger' type='submit'>Delete</button></form></div></td></tr>"
            )
        body = f"""
        <section>
          <h1>Users</h1>
          <p class="muted">Changes are written to sing-box JSON, validated with sing-box check, then sing-box is reloaded.</p>
          <form method="post" action="/users">
            <input name="name" placeholder="user label">
            <button type="submit">Create Trojan + VLESS</button>
          </form>
        </section>
        <section>
          <table>
            <thead><tr><th>Name</th><th>Trojan</th><th>VLESS</th><th>Actions</th></tr></thead>
            <tbody>{''.join(rows) or '<tr><td colspan="4" class="muted">No users.</td></tr>'}</tbody>
          </table>
        </section>
        """
        self._send(HTTPStatus.OK, page("NetlumaVPN sing-box admin", body))

    def _download_link(self, path: Path) -> str:
        if not path.exists():
            return ""
        name = html.escape(path.name)
        return f"<a class='button' href='/download?file={name}'>Download {name.split('-')[-2]}</a>"

    def _download(self, file_name: str) -> None:
        safe_name = Path(file_name).name
        if not safe_name.endswith("-CLIENT.json"):
            return self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
        path = self.store.client_dir / safe_name
        if not path.exists():
            return self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Disposition", f'attachment; filename="{safe_name}"')
        self.end_headers()
        self.wfile.write(path.read_bytes())

    def _authorized(self) -> bool:
        if not self.admin_password:
            return False
        header = self.headers.get("authorization", "")
        if not header.lower().startswith("basic "):
            return False
        try:
            decoded = base64.b64decode(header.split(" ", 1)[1]).decode()
            user, password = decoded.split(":", 1)
        except Exception:
            return False
        return hmac.compare_digest(user, self.admin_user) and hmac.compare_digest(password, self.admin_password)

    def _unauthorized(self) -> None:
        self.send_response(HTTPStatus.UNAUTHORIZED)
        self.send_header("WWW-Authenticate", 'Basic realm="NetlumaVPN sing-box admin"')
        self.end_headers()

    def _redirect(self, path: str) -> None:
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", path)
        self.end_headers()

    def _send(self, status: HTTPStatus, body: bytes, content_type: str = "text/html") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: Any) -> None:
        return


def main() -> None:
    host = os.environ.get("SINGBOX_ADMIN_HOST", "127.0.0.1")
    port = int(os.environ.get("SINGBOX_ADMIN_PORT", "8010"))
    server = ThreadingHTTPServer((host, port), AdminHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
