"""Tests for ops/soffice-shim, the soffice bots run (python3 -m unittest discover -s apps/druzhok/test/soffice_shim)."""

import contextlib
import email.parser
import email.policy
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

SHIM = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "ops", "soffice-shim"))


def load_shim():
    loader = importlib.machinery.SourceFileLoader("soffice_shim", SHIM)
    spec = importlib.util.spec_from_loader("soffice_shim", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


shim = load_shim()


class ParseTest(unittest.TestCase):
    def test_the_bundled_skills_call_shapes(self):
        # docx / powerpoint SKILL.md, pptx_render.py
        self.assertEqual(
            shim.parse(["--headless", "--convert-to", "pdf", "--outdir", "outdir/", "file.docx"]),
            {"to": "pdf", "filter": None, "outdir": "outdir/", "files": ["file.docx"]},
        )
        # xlsx_recalc.py: the filter after the colon, one argv element
        self.assertEqual(
            shim.parse(["--headless", "--calc", "--convert-to", "xlsx:Calc MS Excel 2007 XML", "--outdir", "/t", "/w/a.xlsx"]),
            {"to": "xlsx", "filter": "Calc MS Excel 2007 XML", "outdir": "/t", "files": ["/w/a.xlsx"]},
        )
        # excel-author recalc.py: --outdir after the file
        self.assertEqual(
            shim.parse(["--headless", "--calc", "--convert-to", "xlsx", "/w/m.xlsx", "--outdir", "/t"]),
            {"to": "xlsx", "filter": None, "outdir": "/t", "files": ["/w/m.xlsx"]},
        )
        # xlsx SKILL.md: no --outdir, legacy input
        self.assertEqual(
            shim.parse(["--headless", "--convert-to", "xlsx", "old.xls"]),
            {"to": "xlsx", "filter": None, "outdir": None, "files": ["old.xls"]},
        )

    def test_flags_that_change_nothing_are_skipped(self):
        opts = shim.parse([
            "-headless", "--invisible", "--norestore", "--writer", "--impress", "--nologo",
            "-env:UserInstallation=file:///tmp/p", "--infilter=CSV:44,34,UTF8",
            "--convert-to=PDF", "--outdir=/o", "a.docx", "b.pptx",
        ])
        self.assertEqual(opts, {"to": "pdf", "filter": None, "outdir": "/o", "files": ["a.docx", "b.pptx"]})

    def test_filter_options_are_dropped_with_a_note(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            opts = shim.parse(["--convert-to", "csv:Text - txt - csv (StarCalc):44,34,UTF8", "a.xlsx"])
        self.assertEqual((opts["to"], opts["filter"]), ("csv", "Text - txt - csv (StarCalc)"))
        self.assertIn("44,34,UTF8", err.getvalue())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(shim.parse(["--convert-to", "pdf::{}", "a.docx"])["filter"], None)

    def test_refusals(self):
        for argv in (["--headless", "a.docx"], ["--convert-to", "pdf"], ["--convert-to"],
                     ["--cat", "a.docx"], ["--print-to-file", "a.docx"]):
            with self.assertRaises(shim.ShimError, msg=argv):
                shim.parse(argv)

    def test_version_and_help(self):
        self.assertEqual(shim.parse(["--version"]), {"info": "version"})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(shim.main(["--version"]), 0)
        self.assertIn("LibreOffice", out.getvalue())


class Stub(BaseHTTPRequestHandler):
    """Druzhok's /v2/docs/convert: records each request, answers from `replies`."""

    requests = []
    replies = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
            b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body
        )
        fields, files = {}, {}
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            filename = part.get_filename()
            if filename is not None:
                files[name] = (filename, part.get_payload(decode=True))
            else:
                fields[name] = part.get_content().strip()
        Stub.requests.append({"path": self.path, "headers": dict(self.headers), "fields": fields, "files": files})
        status, payload = Stub.replies.pop(0) if Stub.replies else (200, b"PDF:" + files["file"][1])
        if isinstance(payload, dict):
            payload = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class ConvertTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), Stub)
        cls.url = f"http://127.0.0.1:{cls.server.server_port}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        Stub.requests.clear()
        Stub.replies.clear()
        self.dir = tempfile.mkdtemp()
        self.src = os.path.join(self.dir, "отчёт.docx")
        with open(self.src, "wb") as f:
            f.write(b"DOCX")
        os.environ["DRUZHOK_PROXY_URL"] = self.url

    def tearDown(self):
        os.environ.pop("DRUZHOK_PROXY_URL", None)

    def run_main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = shim.main(argv)
        return code, out.getvalue(), err.getvalue()

    def test_sends_the_file_and_writes_the_result_beside_it_in_outdir(self):
        outdir = os.path.join(self.dir, "out")
        code, out, err = self.run_main(["--headless", "--convert-to", "pdf", "--outdir", outdir, self.src])

        self.assertEqual(code, 0, err)
        result = os.path.join(outdir, "отчёт.pdf")
        with open(result, "rb") as f:
            self.assertEqual(f.read(), b"PDF:DOCX")
        self.assertEqual(out.strip(), f"convert {self.src} -> {result}")
        [req] = Stub.requests
        self.assertEqual(req["path"], "/v2/docs/convert")
        self.assertNotIn("Authorization", req["headers"])
        self.assertEqual(req["fields"], {"to": "pdf"})
        self.assertEqual(req["files"]["file"], ("отчёт.docx", b"DOCX"))
        self.assertEqual(sorted(os.listdir(outdir)), ["отчёт.pdf"])

    def test_sends_the_filter_and_overwrites_like_libreoffice(self):
        tmp = os.path.join(self.dir, "t")
        os.mkdir(tmp)
        with open(os.path.join(tmp, "отчёт.xlsx"), "wb") as f:
            f.write(b"old")
        src = os.path.join(self.dir, "отчёт.xlsx")
        os.rename(self.src, src)
        code, _, err = self.run_main(["--headless", "--calc", "--convert-to", "xlsx:Calc MS Excel 2007 XML", "--outdir", tmp, src])
        self.assertEqual(code, 0, err)
        self.assertEqual(Stub.requests[0]["fields"], {"to": "xlsx", "filter": "Calc MS Excel 2007 XML"})
        with open(os.path.join(tmp, "отчёт.xlsx"), "rb") as f:
            self.assertEqual(f.read(), b"PDF:DOCX")

    def test_without_outdir_writes_to_the_current_dir(self):
        cwd = os.getcwd()
        os.chdir(self.dir)
        try:
            code, _, _ = self.run_main(["--headless", "--convert-to", "pdf", "отчёт.docx"])
        finally:
            os.chdir(cwd)
        self.assertEqual(code, 0)
        self.assertTrue(os.path.isfile(os.path.join(self.dir, "отчёт.pdf")))

    def test_an_error_prints_druzhoks_message_and_writes_nothing(self):
        Stub.replies.append((429, {"error": "busy", "message": "Конвертер документов сейчас занят."}))
        code, out, err = self.run_main(["--headless", "--convert-to", "pdf", "--outdir", self.dir, self.src])
        self.assertEqual(code, 1)
        self.assertEqual(out, "")
        self.assertIn("Конвертер документов сейчас занят.", err)
        self.assertEqual(sorted(os.listdir(self.dir)), ["отчёт.docx"])

    def test_a_reply_without_json_still_fails_plainly(self):
        Stub.replies.append((502, b"<html>bad gateway</html>"))
        code, _, err = self.run_main(["--convert-to", "pdf", "--outdir", self.dir, self.src])
        self.assertEqual(code, 1)
        self.assertIn("502", err)

    def test_each_file_on_its_own_and_any_failure_fails_the_run(self):
        Stub.replies.append((415, {"error": "unsupported_type", "message": "Этот тип файла не конвертируется."}))
        good = os.path.join(self.dir, "b.pptx")
        with open(good, "wb") as f:
            f.write(b"PPTX")
        code, out, err = self.run_main(["--convert-to", "pdf", "--outdir", self.dir, self.src, good, "/nonexistent.doc"])
        self.assertEqual(code, 1)
        self.assertIn("Этот тип файла не конвертируется.", err)
        self.assertIn("нет такого файла", err)
        self.assertIn("b.pdf", out)
        self.assertEqual(len(Stub.requests), 2)

    def test_too_large_is_refused_before_sending(self):
        big = os.path.join(self.dir, "big.docx")
        with open(big, "wb") as f:
            f.truncate(shim.MAX_BYTES + 1)
        code, _, err = self.run_main(["--convert-to", "pdf", big])
        self.assertEqual(code, 1)
        self.assertIn("20 МБ", err)
        self.assertEqual(Stub.requests, [])

    def test_no_converter_is_a_plain_error(self):
        os.environ["DRUZHOK_PROXY_URL"] = "http://127.0.0.1:9"
        code, _, err = self.run_main(["--convert-to", "pdf", "--outdir", self.dir, self.src])
        self.assertEqual(code, 1)
        self.assertIn("недоступен", err)

    def test_runs_with_xlsx_recalcs_stripped_env(self):
        # xlsx_recalc.py passes HOME and PATH only; the URL is here just to reach the stub.
        env = {"HOME": self.dir, "PATH": "/usr/bin:/bin", "DRUZHOK_PROXY_URL": self.url}
        proc = subprocess.run([sys.executable, "-I", SHIM, "--headless", "--convert-to", "pdf", "--outdir", self.dir, self.src],
                              env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(os.path.isfile(os.path.join(self.dir, "отчёт.pdf")))

    def test_default_url_is_the_local_proxy(self):
        self.assertEqual(shim.DEFAULT_URL, "http://127.0.0.1:4000")


if __name__ == "__main__":
    unittest.main()
