import tempfile
import unittest
from pathlib import Path
import sys

from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app as quickvpn_app

ORIGINAL_COLLECT_STATS = quickvpn_app.collect_stats


class QuickVPNMarketingAndFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        quickvpn_app.DB_PATH = Path(self.temp.name) / "quickvpn.sqlite3"
        quickvpn_app.SESSION_SECRET = "test-session-secret"
        quickvpn_app.ADMIN_USER = "admin"
        quickvpn_app.ADMIN_PASSWORD_HASH = quickvpn_app.password_hash("password")
        quickvpn_app.collect_stats = lambda: {"ok": True, "updated": 0}
        self.original_xray_bin = quickvpn_app.XRAY_BIN
        quickvpn_app.init_db()
        self.client = TestClient(quickvpn_app.app)

    def tearDown(self):
        quickvpn_app.collect_stats = ORIGINAL_COLLECT_STATS
        quickvpn_app.XRAY_BIN = self.original_xray_bin
        self.temp.cleanup()

    def _authenticate_admin(self):
        self.client.cookies.set("quickvpn_session", quickvpn_app.sign_session("admin"))

    def test_public_website_pages_render_from_root_routes(self):
        pages = [
            ("/", "NetlumaVPN", "Download on the App Store"),
            ("/setup", "Настройте VPN на любом устройстве", "Ошибка DNS"),
            ("/support", "Contact support", "Send request"),
            ("/terms", "Terms of Use", "Subscriptions via Apple"),
            ("/privacy", "Privacy Policy", "Local app data"),
        ]

        for path, heading, expected in pages:
            with self.subTest(path=path):
                response = self.client.get(path, follow_redirects=False)
                self.assertEqual(response.status_code, 200)
                self.assertIn(heading, response.text)
                self.assertIn(expected, response.text)

    def test_setup_page_covers_platforms_downloads_and_dns_recovery(self):
        response = self.client.get("/setup")

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

        home = self.client.get("/")
        self.assertIn('href="/setup"', home.text)

    def test_support_submission_is_stored_and_visible_in_admin_feedback(self):
        response = self.client.post(
            "/support",
            data={
                "name": "Alex",
                "email": "alex@example.com",
                "topic": "Connection issue",
                "message": "VPN connects but the public IP does not change.",
                "ios_version": "iOS 26.0",
                "app_version": "1.0",
                "contact_consent": "on",
            },
            follow_redirects=False,
        )

        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers["location"], "/support?sent=1")

        self._authenticate_admin()
        admin = self.client.get("/admin/feedback")
        self.assertEqual(admin.status_code, 200)
        self.assertIn("Alex", admin.text)
        self.assertIn("alex@example.com", admin.text)
        self.assertIn("Connection issue", admin.text)
        self.assertIn("VPN connects but the public IP does not change.", admin.text)

    def test_admin_feedback_requires_session_and_can_update_status(self):
        unauthenticated = self.client.get("/admin/feedback", follow_redirects=False)
        self.assertEqual(unauthenticated.status_code, 303)
        self.assertEqual(unauthenticated.headers["location"], "/login")

        self.client.post(
            "/support",
            data={
                "email": "billing@example.com",
                "topic": "Billing / Premium",
                "message": "Please check my subscription status.",
            },
        )
        with quickvpn_app.db() as conn:
            feedback_id = conn.execute("SELECT id FROM feedback_requests").fetchone()["id"]

        self._authenticate_admin()
        response = self.client.post(
            f"/admin/feedback/{feedback_id}/status",
            data={"status": "resolved"},
            follow_redirects=False,
        )

        self.assertEqual(response.status_code, 303)
        self.assertEqual(response.headers["location"], "/admin/feedback")
        admin = self.client.get("/admin/feedback")
        self.assertIn("resolved", admin.text)

    def test_dashboard_renders_warning_when_xray_stats_binary_is_missing(self):
        quickvpn_app.collect_stats = ORIGINAL_COLLECT_STATS
        quickvpn_app.XRAY_BIN = str(Path(self.temp.name) / "missing-xray")
        self._authenticate_admin()

        response = self.client.get("/admin")

        self.assertEqual(response.status_code, 200)
        self.assertIn("Stats collector:", response.text)


if __name__ == "__main__":
    unittest.main()
