"""The sqlite-copy helper, run as the caller (no privilege drop off the box).

Dropping to a bot needs root and a bot; ops/smoke.sh does one real copy on
the host and checks the copy is owned by the bot.
"""

import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "..", "priv", "sqlite-copy", "sqlite_copy.py")


def run(*args, alarm=None):
    pre = ["--alarm", str(alarm)] if alarm else []
    return subprocess.run(
        [sys.executable, "-I", SCRIPT, *pre, str(os.getuid()), str(os.getgid()), *args],
        capture_output=True, text=True, timeout=60, env={},
    )


class SqliteCopy(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def path(self, name):
        return os.path.join(self.dir, name)

    def test_copies_a_wal_database_while_it_is_written(self):
        src = self.path("state.db")
        db = sqlite3.connect(src)
        db.execute("pragma journal_mode=wal")
        db.execute("create table t (i integer, pad text)")
        db.commit()
        stop = threading.Event()

        def write():
            w = sqlite3.connect(src, timeout=10)
            i = 0
            while not stop.is_set():
                w.execute("insert into t values (?, ?)", (i, "x" * 200))
                w.commit()
                i += 1
            w.close()

        t = threading.Thread(target=write)
        t.start()
        time.sleep(0.3)
        try:
            r = run(src, self.path("copy"))
        finally:
            stop.set()
            t.join()
        self.assertEqual(r.returncode, 0, r.stderr)
        c = sqlite3.connect(self.path("copy"))
        self.assertEqual(c.execute("pragma integrity_check").fetchone()[0], "ok")
        self.assertGreater(c.execute("select count(*) from t").fetchone()[0], 0)

    def test_refuses_a_symlink(self):
        real = self.path("real.db")
        sqlite3.connect(real).execute("create table t (i)").connection.commit()
        os.symlink(real, self.path("link.db"))
        r = run(self.path("link.db"), self.path("copy"))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.lexists(self.path("copy")))

    def test_a_missing_source_fails(self):
        r = run(self.path("nope.db"), self.path("copy"))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(os.path.lexists(self.path("copy")))

    def test_a_locked_database_ends_at_the_alarm(self):
        src = self.path("locked.db")
        db = sqlite3.connect(src, isolation_level=None)
        db.execute("create table t (i)")
        db.execute("begin exclusive")
        db.execute("insert into t values (1)")
        start = time.monotonic()
        r = run(src, self.path("copy"), alarm=2)
        took = time.monotonic() - start
        db.execute("rollback")
        self.assertNotEqual(r.returncode, 0)
        self.assertLess(took, 10)

    def test_will_not_act_as_someone_else_unless_root(self):
        if os.geteuid() == 0:
            self.skipTest("as root it drops instead")
        src = self.path("a.db")
        sqlite3.connect(src).execute("create table t (i)").connection.commit()
        r = subprocess.run([sys.executable, "-I", SCRIPT, str(os.getuid() + 1), str(os.getgid()), src, self.path("copy")],
                           capture_output=True, text=True, timeout=30, env={})
        self.assertNotEqual(r.returncode, 0)

    def test_usage(self):
        r = subprocess.run([sys.executable, "-I", SCRIPT, "1"], capture_output=True, text=True, timeout=30, env={})
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
