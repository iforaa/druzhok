#!/usr/bin/python3 -I
"""sqlite-copy: a consistent copy of one SQLite file, made as the file's owner.

Installed root-owned at /usr/local/lib/druzhok/sqlite-copy and run by
ops/druzhok-backup as root, with an empty environment:

    sqlite-copy <uid> <gid> <src> <dest>

It drops to <uid>/<gid> for good, checks that it did, makes itself
non-dumpable, and only then opens <src> and copies it to <dest> with SQLite's
backup API (the same consistent snapshot as the CLI's `.backup`).

Why not `setpriv sqlite3`: a process that execs after the uid change is
dumpable again, and a bot may then open /proc/<pid>/root of a process running
as its uid, which is the host's whole filesystem. This process never execs,
so it stays non-dumpable and the bot fails the ptrace check. As the owner it
still leaves no root-owned -wal/-shm behind, and a *.db that is a link to a
root file is opened with the bot's rights, not root's.

CPython's backup() retries a locked database without end, so an alarm ends
the copy (the caller's `timeout` is the second bound). Exit 0 means <dest>
holds the copy; anything else means it does not.

Not run as root (dev, tests), <uid>/<gid> must be the caller's own and there
is nothing to drop. Standard library only.
"""

import ctypes
import os
import signal
import sqlite3
import stat
import sys

ALARM_S = 45
BUSY_TIMEOUT_S = 15
PR_SET_DUMPABLE = 4
PR_GET_DUMPABLE = 3


class Refused(Exception):
    pass


def set_nondumpable():
    """PR_SET_DUMPABLE 0 and read it back; Linux only."""
    if not sys.platform.startswith("linux"):
        return
    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.restype = ctypes.c_int
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_ulong]
    if libc.prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0:
        raise Refused("prctl(PR_SET_DUMPABLE) failed")
    if libc.prctl(PR_GET_DUMPABLE, 0, 0, 0, 0) != 0:
        raise Refused("still dumpable")


def drop(uid, gid):
    """Become uid/gid for good: real, effective and saved; no group, no capability."""
    as_root = os.geteuid() == 0
    if as_root:
        if uid == 0 or gid == 0:
            raise Refused("will not copy as root")
        os.setgroups([])
        os.setresgid(gid, gid, gid)
        os.setresuid(uid, uid, uid)
    elif (uid, gid) != (os.getuid(), os.getgid()):
        raise Refused("not root: can only copy as the caller")
    # getresuid is Linux's; elsewhere (dev) only real and effective exist.
    if hasattr(os, "getresuid"):
        uids, gids = os.getresuid(), os.getresgid()
    else:
        uids = (os.getuid(), os.geteuid(), os.geteuid())
        gids = (os.getgid(), os.getegid(), os.getegid())
    if uids != (uid, uid, uid) or gids != (gid, gid, gid):
        raise Refused("did not become the owner")
    if as_root and os.getgroups() not in ([], [gid]):
        raise Refused("supplementary groups left")
    if sys.platform.startswith("linux"):
        with open("/proc/self/status") as status:
            caps = [line.split()[1] for line in status if line.startswith("CapEff:")]
        if len(caps) != 1 or int(caps[0], 16) != 0:
            raise Refused("capabilities still in effect")
    set_nondumpable()


def copy(src, dest):
    # Refuse a link or anything but a plain file at <src> itself. SQLite then
    # opens it by name: as the owner, so a swap after this check reaches only
    # what the owner could read anyway.
    fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused("not a plain file")
    finally:
        os.close(fd)
    if os.path.lexists(dest):
        os.unlink(dest)
    source = sqlite3.connect(src, timeout=BUSY_TIMEOUT_S)
    try:
        target = sqlite3.connect(dest)
        try:
            source.backup(target)
        finally:
            target.close()
    finally:
        source.close()


def main(argv):
    args = argv[1:]
    alarm_s = ALARM_S
    # Tests only: a shorter alarm, never a longer one.
    if len(args) == 6 and args[0] == "--alarm":
        alarm_s = min(int(args[1]), ALARM_S)
        args = args[2:]
    if len(args) != 4:
        print("usage: sqlite-copy <uid> <gid> <src> <dest>", file=sys.stderr)
        return 2
    try:
        uid, gid = int(args[0]), int(args[1])
    except ValueError:
        print("sqlite-copy: uid and gid must be numbers", file=sys.stderr)
        return 2
    src, dest = args[2], args[3]
    # The default action of SIGALRM ends the process: no handler that a
    # stuck C call could keep from running.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(alarm_s)
    try:
        drop(uid, gid)
        copy(src, dest)
    except Exception as e:  # any failure: no copy, non-zero exit
        print(f"sqlite-copy: {src}: {e}", file=sys.stderr)
        try:
            if os.path.lexists(dest):
                os.unlink(dest)
        except OSError:
            pass
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
