#!/usr/bin/env python3
import http.server
import json
import os
import ssl
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = Path(os.environ.get("CATALOG_HELPER_UNDER_TEST", ROOT / "host" / "catalog-publish-count.py"))
TOKEN = "vp_test-token-must-not-appear"
TOKEN_OTHER = "vp_other-token-must-not-appear"


class Handler(http.server.BaseHTTPRequestHandler):
    status = 200
    document = {"orgs": []}
    raw_body = None
    headers_extra = {}
    redirect_url = ""
    seen_authorization = []

    def do_GET(self):
        type(self).seen_authorization.append(self.headers.get("Authorization"))
        if self.headers.get("Authorization") not in {
            f"Bearer {TOKEN}", f"Bearer {TOKEN_OTHER}"
        }:
            self.send_response(401)
            self.end_headers()
            return
        if self.redirect_url:
            self.send_response(302)
            self.send_header("Location", self.redirect_url)
            self.end_headers()
            return
        self.send_response(self.status)
        self.send_header("Content-Type", "application/json")
        for name, value in self.headers_extra.items():
            self.send_header(name, value)
        self.end_headers()
        body = self.raw_body
        if body is None:
            body = json.dumps(self.document).encode()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


class Sink(http.server.BaseHTTPRequestHandler):
    seen_authorization = []

    def do_GET(self):
        type(self).seen_authorization.append(self.headers.get("Authorization"))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_args):
        pass


class CatalogCountTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        cert = Path(self.tmp.name) / "server-cert.pem"
        key = Path(self.tmp.name) / "server-key.pem"
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-keyout", str(key), "-out", str(cert), "-days", "1",
                "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
            ],
            check=True,
            capture_output=True,
        )
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.load_cert_chain(cert, key)
        self.server.socket = tls.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.cert = cert
        context = Path(self.tmp.name) / "contexts" / "pod"
        context.mkdir(parents=True)
        (context / "profile.toml").write_text(
            f'portal_endpoint = "https://127.0.0.1:{self.server.server_port}"\n'
        )
        (context / "portal.token").write_text(TOKEN + "\n")
        other = Path(self.tmp.name) / "contexts" / "other"
        other.mkdir(parents=True)
        (other / "profile.toml").write_text(
            f'portal_endpoint = "https://127.0.0.1:{self.server.server_port}"\n'
        )
        (other / "portal.token").write_text(TOKEN_OTHER + "\n")
        Handler.status = 200
        Handler.document = {"orgs": []}
        Handler.raw_body = None
        Handler.headers_extra = {}
        Handler.redirect_url = ""
        Handler.seen_authorization = []
        Sink.seen_authorization = []

    def tearDown(self):
        self.server.shutdown()
        self.thread.join()
        self.server.server_close()
        self.tmp.cleanup()

    def run_helper(self, slot="slot-a", context="pod"):
        environment = os.environ.copy()
        command = [
            str(HELPER), "--profile-dir", self.tmp.name, "--context", context
        ]
        command.extend(["--slot", slot])
        environment["SSL_CERT_FILE"] = str(self.cert)
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
            check=False,
            env=environment,
        )
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertNotIn(TOKEN_OTHER, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return result

    def test_reads_the_named_context(self):
        Handler.document = {
            "orgs": [{"prefix": "slot-a", "publish_count": 1, "last_publish_at": 1}]
        }
        result = self.run_helper(context="other")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(Handler.seen_authorization[-1], f"Bearer {TOKEN_OTHER}")

    def test_reads_exact_slot_rollup_and_unix_seconds(self):
        Handler.document = {
            "orgs": [
                {"prefix": "slot-ab", "publish_count": 99, "last_publish_at": 1700000001},
                {"prefix": "slot-a", "publish_count": 12, "last_publish_at": 1700000002},
            ]
        }
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "12\t1700000002")

    def test_accepts_never_published_slot_without_timestamp(self):
        Handler.document = {"orgs": [{"prefix": "slot-a", "publish_count": 0}]}
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0\t0")

    def test_missing_or_invalid_fields_are_not_confirmed(self):
        for row in (
            None,
            {"prefix": "slot-a", "publish_count": 12},
            {"prefix": "slot-a", "publish_count": True, "last_publish_at": 1700000002},
            {"prefix": "slot-a", "publish_count": 12, "last_publish_at": "seconds"},
        ):
            with self.subTest(row=row):
                Handler.document = {"orgs": [] if row is None else [row]}
                result = self.run_helper()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not confirmed:", result.stderr)

    def test_auth_refusal_and_rate_limit_have_distinct_exit_codes(self):
        Handler.status = 403
        result = self.run_helper()
        self.assertEqual(result.returncode, 2)
        self.assertIn("HTTP 403", result.stderr)
        Handler.status = 429
        Handler.headers_extra = {"Retry-After": "17"}
        result = self.run_helper()
        self.assertEqual(result.returncode, 3)
        self.assertIn("retry-after-seconds=17", result.stderr)

    def test_malformed_and_incomplete_json_are_safe_failures(self):
        for body in (b"{bad", b'{"orgs": [{"prefix": "slot-a"'):
            with self.subTest(body=body):
                Handler.raw_body = body
                result = self.run_helper()
                self.assertEqual(result.returncode, 1)
                self.assertIn("malformed JSON", result.stderr)

    def test_redirect_is_refused_and_authorization_is_not_forwarded(self):
        sink = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Sink)
        thread = threading.Thread(target=sink.serve_forever, daemon=True)
        thread.start()
        try:
            Handler.redirect_url = f"http://127.0.0.1:{sink.server_port}/capture"
            result = self.run_helper()
            self.assertEqual(result.returncode, 1)
            self.assertIn("redirect", result.stderr)
            self.assertEqual(Sink.seen_authorization, [])
        finally:
            sink.shutdown()
            thread.join()
            sink.server_close()

    def test_plaintext_endpoint_is_refused_before_sending_authorization(self):
        profile = Path(self.tmp.name) / "contexts" / "pod" / "profile.toml"
        profile.write_text(
            f'portal_endpoint = "http://127.0.0.1:{self.server.server_port}"\n'
        )
        result = self.run_helper()
        self.assertEqual(result.returncode, 1)
        self.assertIn("must be an HTTPS URL", result.stderr)
        self.assertEqual(Handler.seen_authorization, [])


if __name__ == "__main__":
    unittest.main()
