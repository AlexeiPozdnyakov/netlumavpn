import base64
import json
import os
import tempfile
import unittest
from pathlib import Path

import app as app_module
from fastapi.testclient import TestClient

from app import NetlumaVPNDatabase, SingBoxManager, issue_mobile_profile, mobile_config_payload


class NetlumaVPNSingBoxAdminTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.config_path = root / "config.json"
        self.client_dir = root / "clients"
        self.db_path = root / "netlumavpn.sqlite3"
        self.client_dir.mkdir()
        self.config_path.write_text(
            json.dumps(
                {
                    "inbounds": [
                        {"tag": "trojan-in", "type": "trojan", "users": [{"name": "old", "password": "old-pass"}]},
                        {"tag": "vless-in", "type": "vless", "users": [{"name": "old", "uuid": "11111111-1111-1111-1111-111111111111"}]},
                    ]
                }
            ),
            encoding="utf-8",
        )
        self._write_client_template("old-TRJ-CLIENT.json", "trojan", "password", "old-pass", "/trojan-path")
        self._write_client_template("old-VLESS-CLIENT.json", "vless", "uuid", "11111111-1111-1111-1111-111111111111", "/vless-path")
        self.manager = SingBoxManager(
            config_path=self.config_path,
            client_dir=self.client_dir,
            public_base_url="https://vpn.example.com/sub",
            check_config=lambda _path: None,
            reload_service=lambda: None,
        )
        self.database = NetlumaVPNDatabase(self.db_path)
        self.database.init()
        self.original_database = app_module.database
        self.original_manager = app_module.manager
        self.original_admin_user = os.environ.get("ADMIN_USER")
        self.original_admin_password = os.environ.get("ADMIN_PASSWORD")

    def tearDown(self):
        app_module.database = self.original_database
        app_module.manager = self.original_manager
        if self.original_admin_user is None:
            os.environ.pop("ADMIN_USER", None)
        else:
            os.environ["ADMIN_USER"] = self.original_admin_user
        if self.original_admin_password is None:
            os.environ.pop("ADMIN_PASSWORD", None)
        else:
            os.environ["ADMIN_PASSWORD"] = self.original_admin_password
        self.temp.cleanup()

    def _write_client_template(self, name, protocol, secret_key, secret, path):
        self.client_dir.joinpath(name).write_text(
            json.dumps(
                {
                    "outbounds": [
                        {"tag": "direct", "type": "direct"},
                        {
                            "tag": "proxy",
                            "type": protocol,
                            "server": "vpn.example.com",
                            "server_port": 443,
                            secret_key: secret,
                            "transport": {"type": "ws", "path": path},
                        },
                    ]
                }
            ),
            encoding="utf-8",
        )

    def _client(self):
        app_module.database = self.database
        app_module.manager = self.manager
        os.environ["ADMIN_USER"] = "admin"
        os.environ["ADMIN_PASSWORD"] = "secret"
        return TestClient(app_module.app)

    def _auth_headers(self):
        token = base64.b64encode(b"admin:secret").decode()
        return {"Authorization": f"Basic {token}"}

    def test_create_user_writes_singbox_and_two_client_json_urls(self):
        created = self.manager.create_user("phone_1")

        self.assertEqual(created.name, "phone_1")
        self.assertEqual(created.trojan_config_url, "https://vpn.example.com/sub/phone_1-TRJ-CLIENT.json")
        self.assertEqual(created.vless_config_url, "https://vpn.example.com/sub/phone_1-VLESS-CLIENT.json")
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertTrue(any(user["name"] == "phone_1" for user in config["inbounds"][0]["users"]))
        self.assertTrue(any(user["name"] == "phone_1" for user in config["inbounds"][1]["users"]))

    def test_issue_mobile_profile_reuses_existing_device_profile(self):
        first = issue_mobile_profile(
            database=self.database,
            manager=self.manager,
            server_id="netlumavpn-singbox-vless",
            device_id="device-12345678901234567890",
            device_name="iPhone",
        )
        second = issue_mobile_profile(
            database=self.database,
            manager=self.manager,
            server_id="netlumavpn-singbox-vless",
            device_id="device-12345678901234567890",
            device_name="iPhone",
        )

        self.assertEqual(first["profile_id"], second["profile_id"])
        self.assertEqual(first["config_format"], "sing-box-json")
        self.assertEqual(first["config_url"], f"https://vpn.example.com/api/v1/mobile/profiles/{first['profile_id']}/config")
        self.assertNotIn("vless_config_url", first)
        self.assertNotIn("trojan_config_url", first)
        self.assertEqual(len(self.database.list_profiles()), 1)

    def test_mobile_config_payload_returns_only_the_calling_devices_selected_config(self):
        issued = issue_mobile_profile(
            database=self.database,
            manager=self.manager,
            server_id="netlumavpn-singbox-vless",
            device_id="device-12345678901234567890",
            device_name="iPhone",
            api_base_url="https://vpn.example.com/api/v1",
        )

        payload = mobile_config_payload(
            database=self.database,
            manager=self.manager,
            profile_id=issued["profile_id"],
            device_id="device-12345678901234567890",
        )

        self.assertEqual(payload["outbounds"][1]["type"], "vless")
        self.assertEqual(payload["outbounds"][1]["tag"], "proxy")
        with self.assertRaises(PermissionError):
            mobile_config_payload(
                database=self.database,
                manager=self.manager,
                profile_id=issued["profile_id"],
                device_id="different-device-12345678901234567890",
            )

    def test_delete_profile_removes_singbox_user_and_marks_db_deleted(self):
        issued = issue_mobile_profile(
            database=self.database,
            manager=self.manager,
            server_id="netlumavpn-singbox-trojan",
            device_id="device-abcdef12345678901234",
            device_name="iPhone",
        )

        removed = self.database.delete_profile(issued["profile_id"], self.manager)

        self.assertTrue(removed)
        row = self.database.get_profile(issued["profile_id"])
        self.assertEqual(row["status"], "deleted")
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        self.assertFalse(any(user["name"] == issued["username"] for inbound in config["inbounds"] for user in inbound["users"]))

    def test_public_website_pages_render(self):
        with self._client() as client:
            for path, text in [
                ("/", "NetlumaVPN"),
                ("/setup", "Настройте VPN на любом устройстве"),
                ("/support", "Contact support"),
                ("/terms", "Terms of Use"),
                ("/privacy", "Privacy Policy"),
            ]:
                response = client.get(path)

                self.assertEqual(response.status_code, 200)
                self.assertIn(text, response.text)

    def test_setup_page_covers_platforms_downloads_and_dns_recovery(self):
        with self._client() as client:
            response = client.get("/setup")

            self.assertEqual(response.status_code, 200)
            self.assertIn('<html lang="ru">', response.text)
            for section_id in ["ios", "macos", "windows", "android", "appletv", "linux", "dns-help"]:
                with self.subTest(section_id=section_id):
                    self.assertIn(f'id="{section_id}"', response.text)
            for expected in [
                "Trojan / TRJ",
                "TUN mode",
                "8.8.8.8",
                "8.8.4.4",
                "https://karing.app/en/download/",
                "https://youtube.com/shorts/2XbnHMIMmwM",
                "https://github.com/hiddify/hiddify-app/releases/download/v2.5.7/Hiddify-Android-universal.apk",
            ]:
                with self.subTest(expected=expected):
                    self.assertIn(expected, response.text)

            home = client.get("/")
            self.assertIn('href="/setup"', home.text)

    def test_support_submit_stores_feedback_for_admin(self):
        with self._client() as client:
            response = client.post(
                "/support",
                data={
                    "name": "QA",
                    "email": "qa@example.com",
                    "topic": "Bug",
                    "message": "Connection button did not respond.",
                    "ios_version": "iOS 26",
                    "app_version": "1.0",
                    "contact_consent": "on",
                },
                follow_redirects=False,
            )

            self.assertEqual(response.status_code, 303)
            rows = self.database.feedback_rows()
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["email"], "qa@example.com")
            admin_response = client.get("/admin/feedback", headers=self._auth_headers())
            self.assertEqual(admin_response.status_code, 200)
            self.assertIn("Connection button did not respond.", admin_response.text)

    def test_admin_feedback_requires_auth_and_updates_status(self):
        feedback_id, error = self.database.create_feedback_request(
            {
                "email": "status@example.com",
                "topic": "Feature request",
                "message": "Please add faster server switching.",
            }
        )
        self.assertEqual(error, "")

        with self._client() as client:
            unauthorized = client.get("/admin/feedback")
            self.assertEqual(unauthorized.status_code, 401)
            response = client.post(
                f"/admin/feedback/{feedback_id}/status",
                data={"status": "resolved"},
                headers=self._auth_headers(),
                follow_redirects=False,
            )

            self.assertEqual(response.status_code, 303)
            rows = self.database.feedback_rows(status="resolved")
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["email"], "status@example.com")


if __name__ == "__main__":
    unittest.main()
