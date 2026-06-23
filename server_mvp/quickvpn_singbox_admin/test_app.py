import json
import tempfile
import unittest
from pathlib import Path

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

    def tearDown(self):
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


if __name__ == "__main__":
    unittest.main()
