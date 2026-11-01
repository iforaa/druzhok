"""Tests for ops/publish-existing-sites.py, run as production runs it: `python3 -I -c`
with the source as an argument, the cwd being the bot's workspace.

    python3 -m unittest discover -s apps/druzhok/test/publish_existing_sites
"""

import http.server
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import threading
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[4] / "ops" / "publish-existing-sites.py"


class Gateway(http.server.BaseHTTPRequestHandler):
    def do_PUT(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.server.calls.append((self.path, dict(self.headers), body))
        site = self.path.rsplit("/", 1)[-1]
        refused = self.server.refuse.get(site)
        status, reply = (refused, {"error": "site_disabled"}) if refused else (201, {"url": f"https://b.example/{site}/"})
        payload = json.dumps(reply).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class PublishTest(unittest.TestCase):
    def setUp(self):
        self.gateway = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Gateway)
        self.gateway.calls, self.gateway.refuse = [], {}
        threading.Thread(target=self.gateway.serve_forever, daemon=True).start()
        self.addCleanup(self.gateway.server_close)
        self.addCleanup(self.gateway.shutdown)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.workspace = Path(tmp.name) / "workspace"
        self.sites = self.workspace / "sites"
        self.sites.mkdir(parents=True)

    def site(self, name, files=None):
        root = self.sites / name
        for rel, text in (files if files is not None else {"index.html": "<h1>привет</h1>"}).items():
            path = root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        root.mkdir(exist_ok=True)
        return root

    def run_script(self, *args):
        env = {
            "PATH": os.environ["PATH"],
            "FIRECRAWL_API_URL": f"http://127.0.0.1:{self.gateway.server_address[1]}",
            "FIRECRAWL_API_KEY": "tenant-secret",
        }
        return subprocess.run(
            [sys.executable, "-I", "-c", SCRIPT.read_text(), *args],
            cwd=self.workspace, env=env, capture_output=True, text=True, timeout=60,
        )

    def archive_names(self, call):
        with tarfile.open(fileobj=io.BytesIO(call[2]), mode="r:gz") as tar:
            return sorted(tar.getnames()), tar

    def test_without_apply_only_reports(self):
        self.site("cv")
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cv: would publish", result.stdout)
        self.assertEqual(self.gateway.calls, [])

    def test_publishes_with_the_files_at_the_archive_root(self):
        self.site("cv", {"index.html": "<h1>привет</h1>", "css/a.css": "a{}"})
        result = self.run_script("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cv: published https://b.example/cv/", result.stdout)
        path, headers, body = self.gateway.calls[0]
        self.assertEqual(path, "/v2/sites/cv")
        self.assertEqual(headers["Authorization"], "Bearer tenant-secret")
        self.assertEqual(headers["Content-Type"], "application/gzip")
        with tarfile.open(fileobj=io.BytesIO(body), mode="r:gz") as tar:
            self.assertEqual(sorted(tar.getnames()), ["css/a.css", "index.html"])
            self.assertEqual(tar.extractfile("index.html").read().decode(), "<h1>привет</h1>")
            self.assertTrue(all(m.isreg() for m in tar.getmembers()))
        self.assertNotIn("tenant-secret", result.stdout + result.stderr)
        self.assertEqual(list(self.workspace.iterdir()), [self.sites])

    def test_what_botsite_kept_private_stays_out(self):
        root = self.site("cv", {"index.html": "x", ".env": "SECRET", "_draft.html": "x", ".git/config": "x", "_p/a": "x"})
        secret = self.workspace / "secret.txt"
        secret.write_text("SECRET")
        (root / "link.txt").symlink_to(secret)
        (root / "linkdir").symlink_to(self.workspace)
        result = self.run_script("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("6 left out", result.stdout)
        with tarfile.open(fileobj=io.BytesIO(self.gateway.calls[0][2]), mode="r:gz") as tar:
            self.assertEqual(tar.getnames(), ["index.html"])

    def test_unsendable_sites_are_reported_and_not_sent(self):
        self.site("noindex", {"page.html": "x"})
        self.site("Bad_Name")
        self.site("many", {"index.html": "x", **{f"f{i}.html": "x" for i in range(100)}})
        (self.sites / "link").symlink_to(self.site("target"))
        result = self.run_script("--apply")
        self.assertEqual(result.returncode, 1)
        self.assertIn("noindex: NOT SENDABLE no_index_html", result.stdout)
        self.assertIn("Bad_Name: NOT SENDABLE bad_name", result.stdout)
        self.assertIn("many: NOT SENDABLE too_large", result.stdout)
        self.assertIn("link: NOT SENDABLE not_a_directory", result.stdout)
        self.assertEqual([c[0] for c in self.gateway.calls], ["/v2/sites/target"])

    def test_a_refusal_is_reported_and_the_next_site_still_goes(self):
        self.site("a")
        self.site("b")
        self.gateway.refuse["a"] = 403
        result = self.run_script("--apply")
        self.assertEqual(result.returncode, 1)
        self.assertIn("a: FAILED site_disabled", result.stdout)
        self.assertIn("b: published", result.stdout)

    def test_a_linked_sites_dir_sends_nothing(self):
        elsewhere = self.workspace.parent / "elsewhere"
        (elsewhere / "private").mkdir(parents=True)
        (elsewhere / "private" / "index.html").write_text("x")
        self.sites.rmdir()
        self.sites.symlink_to(elsewhere)
        result = self.run_script("--apply")
        self.assertEqual(result.returncode, 1)
        self.assertIn("symlink", result.stdout)
        self.assertEqual(self.gateway.calls, [])

    def test_an_unreadable_file_fails_that_site_and_the_next_still_goes(self):
        self.site("a", {"index.html": "x", "b.html": "x"})
        self.site("b")
        (self.sites / "a" / "b.html").chmod(0)
        self.addCleanup((self.sites / "a" / "b.html").chmod, 0o644)
        result = self.run_script("--apply")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("a: FAILED PermissionError", result.stdout)
        self.assertIn("b: published", result.stdout)

    def test_no_sites_dir(self):
        self.sites.rmdir()
        result = self.run_script("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no sites", result.stdout)


if __name__ == "__main__":
    unittest.main()
