"""What tenant-fs refuses when it runs as root, checked without being root.

`run_job(job, True)` is the root branch. Everything here is refused before
any privileged call, so these run anywhere; becoming the bot itself needs
root and a bot, and ops/smoke.sh does one real job on the box.
"""

import importlib.util
import os
import pwd
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "priv", "tenant-fs", "tenant_fs.py")
spec = importlib.util.spec_from_file_location("tenant_fs", SCRIPT)
tenant_fs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tenant_fs)

BAD_JOB = {"ok": False, "error": "bad_job"}


class RootBranch(unittest.TestCase):
    def test_a_dir_is_refused(self):
        self.assertEqual(tenant_fs.run_job({"dir": "/etc", "ops": []}, True), BAD_JOB)
        # Even next to a good name.
        self.assertEqual(tenant_fs.run_job({"name": "kot", "dir": "/etc", "ops": []}, True), BAD_JOB)

    def test_names_that_are_not_a_bot_name(self):
        for name in ["", "../x", "a/b", "A", "-a", "a" * 32, "a\n", "a b", None, 1, ["kot"]]:
            with self.subTest(name=name):
                self.assertEqual(tenant_fs.run_job({"name": name, "ops": []}, True), BAD_JOB)

    def test_ops_must_be_a_list(self):
        self.assertEqual(tenant_fs.run_job({"name": "kot", "ops": None}, True), BAD_JOB)
        self.assertEqual(tenant_fs.run_job(["kot"], True), BAD_JOB)

    def test_no_such_bot_and_a_bot_that_is_root(self):
        with mock.patch.object(tenant_fs.pwd, "getpwnam", side_effect=KeyError):
            self.assertEqual(tenant_fs.run_job({"name": "kot", "ops": []}, True), {"ok": False, "error": "no_bot"})
        root = pwd.struct_passwd(("bot-kot", "x", 0, 0, "", "/", "/bin/sh"))
        with mock.patch.object(tenant_fs.pwd, "getpwnam", return_value=root) as getpwnam:
            self.assertEqual(tenant_fs.run_job({"name": "kot", "ops": []}, True), {"ok": False, "error": "no_bot"})
            # Only ever a `bot-` user: the name `druzhok` asks for `bot-druzhok`.
            getpwnam.assert_called_once_with("bot-kot")

    def test_a_child_that_never_answers_is_ended(self):
        r, w = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(r)
            os.kill(os.getpid(), tenant_fs.signal.SIGSTOP)
            os._exit(0)
        os.close(w)
        with mock.patch.object(tenant_fs, "JOB_TIMEOUT_S", -4):
            self.assertIsNone(tenant_fs.read_answer(r, pid))
        with self.assertRaises(ChildProcessError):
            os.waitpid(pid, 0)


class Paths(unittest.TestCase):
    def test_segments(self):
        for path in [None, "a", [".."], ["."], [""], ["a/b"], ["a\0"], [1]]:
            with self.subTest(path=path):
                with self.assertRaises(tenant_fs.Refused):
                    tenant_fs.segments({"path": path})
        self.assertEqual(tenant_fs.segments({"path": ["a", "b.txt"]}), ["a", "b.txt"])


if __name__ == "__main__":
    unittest.main()
