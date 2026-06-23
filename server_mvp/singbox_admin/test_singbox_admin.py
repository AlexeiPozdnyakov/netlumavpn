import json
import tempfile
import unittest
from pathlib import Path

from singbox_admin import SingBoxStore


class SingBoxStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.config_path = root / "config.json"
        self.client_dir = root / "clients"
        self.client_dir.mkdir()
        self.config_path.write_text(
            json.dumps(
                {
                    "inbounds": [
                        {
                            "tag": "trojan-in",
                            "type": "trojan",
                            "listen": "127.0.0.1",
                            "listen_port": 10443,
                            "users": [{"name": "existing", "password": "old-password"}],
                        },
                        {
                            "tag": "vless-in",
                            "type": "vless",
                            "listen": "127.0.0.1",
                            "listen_port": 11443,
                            "users": [{"name": "existing", "uuid": "11111111-1111-1111-1111-111111111111"}],
                        },
                    ]
                }
            ),
            encoding="utf-8",
        )
        self._write_client_template("existing-VLESS-CLIENT.json", "vless", "uuid", "11111111-1111-1111-1111-111111111111")
        self._write_client_template("existing-TRJ-CLIENT.json", "trojan", "password", "old-password")

    def tearDown(self):
        self.temp.cleanup()

    def _write_client_template(self, name, protocol, secret_key, secret):
        self.client_dir.joinpath(name).write_text(
            json.dumps(
                {
                    "outbounds": [
                        {"tag": "direct", "type": "direct"},
                        {
                            "tag": "proxy",
                            "type": protocol,
                            "server": "example.com",
                            "server_port": 443,
                            secret_key: secret,
                            "transport": {"type": "ws", "path": "/path"},
                        },
                    ]
                }
            ),
            encoding="utf-8",
        )

    def test_create_user_adds_both_inbounds_and_client_json_files(self):
        store = SingBoxStore(self.config_path, self.client_dir)

        created = store.create_user("Alice_Phone")

        self.assertEqual(created["name"], "Alice_Phone")
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        trojan_users = config["inbounds"][0]["users"]
        vless_users = config["inbounds"][1]["users"]
        self.assertTrue(any(user["name"] == "Alice_Phone" and "password" in user for user in trojan_users))
        self.assertTrue(any(user["name"] == "Alice_Phone" and "uuid" in user for user in vless_users))
        self.assertTrue(self.client_dir.joinpath("Alice_Phone-TRJ-CLIENT.json").exists())
        self.assertTrue(self.client_dir.joinpath("Alice_Phone-VLESS-CLIENT.json").exists())

    def test_delete_user_removes_both_inbounds_and_client_json_files(self):
        store = SingBoxStore(self.config_path, self.client_dir)
        store.create_user("Alice_Phone")

        removed = store.delete_user("Alice_Phone")

        self.assertTrue(removed)
        config = json.loads(self.config_path.read_text(encoding="utf-8"))
        for inbound in config["inbounds"]:
            self.assertFalse(any(user["name"] == "Alice_Phone" for user in inbound["users"]))
        self.assertFalse(self.client_dir.joinpath("Alice_Phone-TRJ-CLIENT.json").exists())
        self.assertFalse(self.client_dir.joinpath("Alice_Phone-VLESS-CLIENT.json").exists())

    def test_create_user_rejects_names_that_ssb_would_reject(self):
        store = SingBoxStore(self.config_path, self.client_dir)

        with self.assertRaises(ValueError):
            store.create_user("Alice Phone")


if __name__ == "__main__":
    unittest.main()
