#!/usr/bin/python3 -I
"""tenant-fs: druzhok's file work inside bot tenant dirs, done as the bot.

Installed root-owned at /usr/local/lib/druzhok/tenant-fs and run through sudo
(ops/sudoers-druzhok) by Druzhok.TenantFiles. Druzhok itself has no file
capabilities: it cannot open a bot's 0700 dir, and it must not, because a bot
owns everything below its dir and can put a symlink anywhere in it.

A request is JSON on stdin, the answer JSON on stdout. With `--serve` the
process stays and takes request after request, each framed by a 4-byte length,
so druzhok does not pay for sudo and a Python start on every call:

    {"jobs": [{"name": "<bot>", "ops": [{"op": "read", "path": ["config.yaml"], "limit": 4096}, ...]}]}
    {"jobs": [{"ok": true, "results": [{"ok": true, "data": "<base64>", ...}, ...]}]}

As root, each job runs in a child that acts as `bot-<name>` (its effective
uid and gid, no group, no capability in effect) before it touches
/data/tenants/<name>, so nothing here can reach what the bot could not reach
itself. The child's real uid stays root's only so that the bot cannot signal
it: a bot that could stop the child would hold up druzhok. Not as root (dev, tests) a job names its dir instead,
`{"dir": "/abs/path"}`, and runs as the caller; root refuses "dir".

No path component is ever followed as a symlink: every step is an openat with
O_NOFOLLOW from the descriptor of the directory before it, so a bot swapping a
directory for a link mid-walk gets a refusal, not a redirect.

Ops (`path` is a list of components below the tenant dir):
  read    limit, index?   -> data (base64, at most limit bytes), size, mtime, truncated;
                             "enoent" when nothing is there, "not_found" for the rest
  stat                    -> type (regular|directory|symlink|other), size, mtime, mode
  ls                      -> names
  is_dir                  -> ok when every component is a real directory
  mkdir                   -> missing directories made 0700
  write   data, create?, mode?
                          -> missing directories made; the file keeps an existing
                             mode; create never replaces ("exists": true)
  delete                  -> a regular file only
  rmtree                  -> the tree at path, links unlinked and never followed
"""

import base64
import errno
import json
import os
import pwd
import re
import select
import signal
import stat
import sys

TENANTS = "/data/tenants"
NAME_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,30}")
MAX_READ = 16 * 1024 * 1024
JOB_TIMEOUT_S = 60
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
NOFOLLOW_LINK = {"follow_symlinks": False} if os.link in os.supports_follow_symlinks else {}


class Refused(Exception):
    """An op's answer that is not ok: `{"ok": false, "error": <code>}`."""


def segments(op):
    path = op.get("path")
    if not isinstance(path, list):
        raise Refused("bad_path")
    for seg in path:
        if not isinstance(seg, str) or seg in ("", ".", "..") or "/" in seg or "\0" in seg:
            raise Refused("bad_path")
    return path


def code(e):
    return errno.errorcode.get(e.errno, "EIO").lower()


def open_dir(name, dir_fd):
    """A real directory below dir_fd, or Refused: not_a_directory, enoent, ..."""
    try:
        return os.open(name, DIR_FLAGS, dir_fd=dir_fd)
    except OSError as e:
        # O_NOFOLLOW on a link: ELOOP (Linux), EMLINK (FreeBSD); a file: ENOTDIR.
        if e.errno in (errno.ELOOP, errno.EMLINK, errno.ENOTDIR):
            raise Refused("not_a_directory")
        raise Refused(code(e))


def walk(root, dirs, make=False):
    """The descriptor of root/dirs..., every component a real directory."""
    fd = os.dup(root)
    try:
        for seg in dirs:
            try:
                nxt = open_dir(seg, fd)
            except Refused as r:
                if not (make and r.args[0] == "enoent"):
                    raise
                try:
                    os.mkdir(seg, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                except OSError as e:
                    raise Refused(code(e))
                nxt = open_dir(seg, fd)
            os.close(fd)
            fd = nxt
        return fd
    except BaseException:
        os.close(fd)
        raise


def lstat(name, dir_fd):
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except OSError as e:
        raise Refused(code(e))


def kind(st):
    if stat.S_ISREG(st.st_mode):
        return "regular"
    if stat.S_ISDIR(st.st_mode):
        return "directory"
    if stat.S_ISLNK(st.st_mode):
        return "symlink"
    return "other"


def op_read(root, op):
    path = segments(op)
    limit = op.get("limit")
    if not isinstance(limit, int) or isinstance(limit, bool) or not 0 <= limit <= MAX_READ:
        raise Refused("bad_limit")
    index = op.get("index") is True
    if not path and not index:
        raise Refused("not_found")
    try:
        fd = walk(root, path[:-1])
        try:
            name = path[-1] if path else "index.html"
            if index and path and is_dir(name, fd):
                sub = open_dir(name, fd)
                os.close(fd)
                fd, name = sub, "index.html"
            # O_NONBLOCK: a FIFO the bot left here must not hang the open.
            f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=fd)
        finally:
            os.close(fd)
    except FileNotFoundError:
        raise Refused("enoent")
    except Refused as r:
        # Nothing at that name is told from something that cannot be read.
        raise Refused("enoent" if r.args[0] == "enoent" else "not_found")
    except OSError:
        raise Refused("not_found")
    try:
        st = os.fstat(f)
        if not stat.S_ISREG(st.st_mode):
            raise Refused("not_found")
        want = limit + 4
        chunks = []
        while want > 0:
            chunk = os.read(f, want)
            if not chunk:
                break
            chunks.append(chunk)
            want -= len(chunk)
        data = b"".join(chunks)
    except OSError:
        raise Refused("not_found")
    finally:
        os.close(f)
    truncated = len(data) > limit
    return {
        "data": base64.b64encode(data[:limit]).decode("ascii"),
        "size": st.st_size,
        "mtime": int(st.st_mtime),
        "truncated": truncated,
    }


def is_dir(name, dir_fd):
    try:
        return stat.S_ISDIR(os.stat(name, dir_fd=dir_fd, follow_symlinks=False).st_mode)
    except OSError:
        return False


def op_stat(root, op):
    path = segments(op)
    if not path:
        st = os.fstat(root)
    else:
        fd = walk(root, path[:-1])
        try:
            st = lstat(path[-1], fd)
        finally:
            os.close(fd)
    return {
        "type": kind(st),
        "size": st.st_size,
        "mtime": int(st.st_mtime),
        "mode": stat.S_IMODE(st.st_mode),
    }


def op_ls(root, op):
    fd = walk(root, segments(op))
    try:
        return {"names": sorted(os.listdir(fd))}
    except OSError as e:
        raise Refused(code(e))
    finally:
        os.close(fd)


def op_is_dir(root, op):
    os.close(walk(root, segments(op)))
    return {}


def op_mkdir(root, op):
    os.close(walk(root, segments(op), make=True))
    return {}


def op_write(root, op):
    path = segments(op)
    if not path:
        raise Refused("bad_path")
    try:
        data = base64.b64decode(op.get("data"), validate=True)
    except (TypeError, ValueError):
        raise Refused("bad_data")
    create = op.get("create") is True
    new_mode = op.get("mode")
    if new_mode is None:
        new_mode = 0o644
    if not isinstance(new_mode, int) or isinstance(new_mode, bool) or not 0 <= new_mode <= 0o777:
        raise Refused("bad_mode")
    name = path[-1]
    fd = walk(root, path[:-1], make=True)
    try:
        try:
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            st = None
        except OSError as e:
            raise Refused(code(e))
        if st is not None and not stat.S_ISREG(st.st_mode):
            raise Refused("not_regular")
        if st is not None and create:
            return {"exists": True}
        mode = new_mode if st is None else stat.S_IMODE(st.st_mode)
        # Written under a name of our own, then renamed over the target
        # (rename replaces a link, never follows it) or, for a seed, linked
        # into place (link fails if anything is there).
        tmp = ".druzhok-tmp-" + os.urandom(12).hex()
        try:
            f = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
        except OSError as e:
            raise Refused(code(e))
        try:
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(f, view):]
                os.fchmod(f, mode)
                os.fsync(f)
            finally:
                os.close(f)
            if create:
                try:
                    os.link(tmp, name, src_dir_fd=fd, dst_dir_fd=fd, **NOFOLLOW_LINK)
                except FileExistsError:
                    return {"exists": True}
            else:
                os.rename(tmp, name, src_dir_fd=fd, dst_dir_fd=fd)
                tmp = None
        except OSError as e:
            raise Refused(code(e))
        finally:
            if tmp is not None:
                try:
                    os.unlink(tmp, dir_fd=fd)
                except OSError:
                    pass
        return {}
    finally:
        os.close(fd)


def op_delete(root, op):
    path = segments(op)
    if not path:
        raise Refused("bad_path")
    fd = walk(root, path[:-1])
    try:
        st = lstat(path[-1], fd)
        if not stat.S_ISREG(st.st_mode):
            raise Refused("not_regular")
        try:
            os.unlink(path[-1], dir_fd=fd)
        except OSError as e:
            raise Refused(code(e))
        return {}
    finally:
        os.close(fd)


def remove_tree(name, dir_fd):
    """Removes name below dir_fd: a directory with all in it, or one entry."""
    try:
        fd = os.open(name, DIR_FLAGS, dir_fd=dir_fd)
    except OSError as e:
        if e.errno == errno.ENOENT:
            return
        # Not a directory, or a link: one entry, unlinked and never followed.
        os.unlink(name, dir_fd=dir_fd)
        return
    try:
        for entry in os.listdir(fd):
            remove_tree(entry, fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=dir_fd)


def op_rmtree(root, op):
    path = segments(op)
    if not path:
        raise Refused("bad_path")
    try:
        fd = walk(root, path[:-1])
    except Refused as r:
        if r.args[0] == "enoent":
            return {}
        raise
    try:
        remove_tree(path[-1], fd)
    except OSError as e:
        raise Refused(code(e))
    finally:
        os.close(fd)
    return {}


OPS = {
    "read": op_read,
    "stat": op_stat,
    "ls": op_ls,
    "is_dir": op_is_dir,
    "mkdir": op_mkdir,
    "write": op_write,
    "delete": op_delete,
    "rmtree": op_rmtree,
}


def run_ops(tenant_dir, ops):
    try:
        root = os.open(tenant_dir, DIR_FLAGS)
    except FileNotFoundError:
        return {"ok": False, "error": "no_tenant_dir"}
    except OSError as e:
        # A dir that is there and cannot be opened (the bot chmodded it) is
        # not a missing one.
        return {"ok": False, "error": "tenant_dir_" + code(e)}
    results = []
    try:
        for op in ops:
            try:
                if not isinstance(op, dict) or op.get("op") not in OPS:
                    raise Refused("bad_op")
                answer = OPS[op["op"]](root, op)
                answer["ok"] = True
            except Refused as r:
                answer = {"ok": False, "error": r.args[0]}
            except OSError as e:
                answer = {"ok": False, "error": code(e)}
            results.append(answer)
    finally:
        os.close(root)
    return {"ok": True, "results": results}


def become(user):
    """This process acts as `user` from here on: its files, its permissions.

    Only the effective ids change. With the real and saved uid still root's
    the bot cannot signal this process (kill(2) matches those two), so it
    cannot stop a job half way; the kernel still drops every capability from
    the effective set when the effective uid leaves 0, which is checked.
    """
    os.setgroups([])
    os.setresgid(user.pw_gid, user.pw_gid, user.pw_gid)
    os.setresuid(0, user.pw_uid, 0)
    if os.geteuid() != user.pw_uid or os.getegid() != user.pw_gid or user.pw_uid == 0:
        raise RuntimeError("did not become the bot")
    with open("/proc/self/status") as status:
        caps = [line.split()[1] for line in status if line.startswith("CapEff:")]
    if len(caps) != 1 or int(caps[0], 16) != 0:
        raise RuntimeError("capabilities still in effect")


def read_answer(r, pid):
    """What the child wrote before the deadline, or None; the child is reaped."""
    deadline = JOB_TIMEOUT_S + 5
    chunks = []
    done = False
    try:
        end = os.times().elapsed + deadline
        while True:
            left = end - os.times().elapsed
            if left <= 0 or not select.select([r], [], [], left)[0]:
                break
            chunk = os.read(r, 1 << 16)
            if not chunk:
                done = True
                break
            chunks.append(chunk)
    finally:
        os.close(r)
        if not done:
            # Its own alarm should have ended it; SIGKILL ends a stopped one too.
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    _, status = os.waitpid(pid, 0)
    return b"".join(chunks) if done and status == 0 else None


def run_as_bot(name, ops):
    """Runs the job in a child acting as bot-<name>; its answer comes over a pipe."""
    try:
        user = pwd.getpwnam("bot-" + name)
    except KeyError:
        return {"ok": False, "error": "no_bot"}
    if user.pw_uid == 0:
        return {"ok": False, "error": "no_bot"}
    r, w = os.pipe()
    pid = os.fork()
    if pid == 0:
        status = 1
        try:
            os.close(r)
            signal.alarm(JOB_TIMEOUT_S)
            # The child answers over the pipe only: it keeps no descriptor
            # of the channel to druzhok while it acts as the bot.
            null = os.open(os.devnull, os.O_RDWR)
            os.dup2(null, 0)
            os.dup2(null, 1)
            os.close(null)
            become(user)
            os.umask(0)
            answer = json.dumps(run_ops(os.path.join(TENANTS, name), ops)).encode()
            with os.fdopen(w, "wb") as out:
                out.write(answer)
            status = 0
        finally:
            os._exit(status)
    os.close(w)
    raw = read_answer(r, pid)
    try:
        answer = json.loads(raw) if raw is not None else None
    except ValueError:
        answer = None
    return answer if isinstance(answer, dict) else {"ok": False, "error": "job_failed"}


def run_job(job, root):
    if not isinstance(job, dict) or not isinstance(job.get("ops"), list):
        return {"ok": False, "error": "bad_job"}
    if root:
        name = job.get("name")
        if "dir" in job or not isinstance(name, str) or not NAME_RE.fullmatch(name):
            return {"ok": False, "error": "bad_job"}
        return run_as_bot(name, job["ops"])
    tenant_dir = job.get("dir")
    if not isinstance(tenant_dir, str) or not os.path.isabs(tenant_dir):
        return {"ok": False, "error": "bad_job"}
    os.umask(0)
    return run_ops(tenant_dir, job["ops"])


def answer_to(raw):
    """The JSON answer to one JSON request, or None when it is not one."""
    try:
        jobs = json.loads(raw)["jobs"]
        if not isinstance(jobs, list):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        return None
    root = os.geteuid() == 0
    return json.dumps({"jobs": [run_job(job, root) for job in jobs]}).encode()


def read_exactly(stream, n):
    data = b""
    while len(data) < n:
        chunk = stream.read(n - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def serve():
    """Request after request on stdin, each a 4-byte big-endian length and the
    JSON, answered the same way; ends when stdin does (druzhok is gone)."""
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    while True:
        head = read_exactly(stdin, 4)
        if head is None:
            return 0
        raw = read_exactly(stdin, int.from_bytes(head, "big"))
        if raw is None:
            return 0
        answer = answer_to(raw)
        if answer is None:
            return 2
        stdout.write(len(answer).to_bytes(4, "big") + answer)
        stdout.flush()


def main():
    if sys.argv[1:] == ["--check"]:
        print("ok")
        return 0
    if sys.argv[1:] == ["--serve"]:
        return serve()
    answer = answer_to(sys.stdin.buffer.read())
    if answer is None:
        print("tenant-fs: bad request", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(answer)
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
