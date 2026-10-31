"""Saves one page of the bot panel, as the bot's own user.

Spec: docs/superpowers/specs/2026-10-31-panel-editable-pages-design.md. Druzhok
(`Druzhok.Panel.Editor`) runs this through `druzhok-ctl exec` with `python -I`,
so the bot's workspace is not on sys.path, and reads back one line of JSON:

    {"sha256": "...", "modified_at": "..."}
    {"error": "<type>", ...}

    save.py <hand-over file>   JSON {target, kind, base_sha256, text, limit}
    save.py --check            imports every hermes name used; touches no file

Running as the bot's uid means a directory the bot swaps for a symlink reaches
only what the bot could write itself, and the save can hold hermes's own locks
and use its own checks. These are private hermes names: any failure to import
them is `save_failed`, so a renamed one fails closed, and ops/smoke.sh runs
--check so that an update of hermes catches it.
"""

import contextlib
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile
import time

sys.dont_write_bytecode = True

KINDS = ("soul", "memory", "user", "skill")
CURRENT_MAX_BYTES = 4 * 1024 * 1024


class Refused(Exception):
    def __init__(self, error, **extra):
        super().__init__(error)
        self.reply = {"error": error, **extra}


class Hermes:
    """The hermes names the save uses, imported with no effect on the bot's home.

    Importing tools.skill_manager_tool reaches hermes_cli.config, which creates
    the home's skeleton and a default SOUL.md there, and `Voice.sync_soul/2`
    would take that for the owner's own. So the import sees a throwaway home;
    each name below resolves the home when it is called, so the bot's own is
    back in place by then.
    """

    def __init__(self):
        real = os.environ.get("HERMES_HOME")
        scratch = tempfile.mkdtemp(prefix="panel-save-")
        os.environ["HERMES_HOME"] = scratch
        try:
            from agent.skill_utils import parse_frontmatter
            from tools import memory_tool  # MemoryStore._file_lock imports it when called
            from tools.memory_tool_store import MemoryStore, _scan_memory_content
            from tools.skill_manager_tool import (
                _read_frontmatter_name,
                _skill_mutation_locks,
                _validate_frontmatter,
            )
            from utils import atomic_write_bytes, atomic_write_text
        finally:
            if real is None:
                os.environ.pop("HERMES_HOME", None)
            else:
                os.environ["HERMES_HOME"] = real
            shutil.rmtree(scratch, ignore_errors=True)

        self.fcntl = memory_tool.fcntl
        self.parse_frontmatter = parse_frontmatter
        self.memory_lock = MemoryStore._file_lock
        self.parse_entries = MemoryStore._parse_entries
        self.scan_entry = _scan_memory_content
        self.read_skill_name = _read_frontmatter_name
        self.skill_locks = _skill_mutation_locks
        self.validate_skill = _validate_frontmatter
        self.write_bytes = atomic_write_bytes
        self.write_text = atomic_write_text


def read_job(path):
    with open(path, "rb") as f:
        raw = f.read()
    try:
        job = json.loads(raw.decode("utf-8"))
    except UnicodeDecodeError:
        raise Refused("invalid_text")
    if not isinstance(job, dict) or job.get("kind") not in KINDS:
        raise Refused("save_failed")
    target = job.get("target")
    if not isinstance(target, list) or not target:
        raise Refused("save_failed")
    for seg in target:
        if not isinstance(seg, str) or seg in ("", ".", "..") or "/" in seg or "\0" in seg:
            raise Refused("save_failed")
    if not isinstance(job.get("limit"), int):
        raise Refused("save_failed")
    return job


def target_path(home, segments):
    """The file's path. A directory on the way that is a link is refused; one a
    bot swaps in after this check still reaches only what its uid can write."""
    path = home
    for seg in segments[:-1]:
        path = os.path.join(path, seg)
        try:
            if not stat.S_ISDIR(os.lstat(path).st_mode):
                raise Refused("save_failed", reason="NotADirectory")
        except FileNotFoundError:
            pass
    return os.path.join(path, segments[-1])


def read_current(path):
    """The file's bytes, or None only when nothing at all is at that name: a
    link or a file of another owner is refused, never taken for absent."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    except OSError as err:
        raise Refused("save_failed", reason=type(err).__name__)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid():
            raise Refused("save_failed", reason="NotTheBotsFile")
        chunks = []
        size = 0
        while size <= CURRENT_MAX_BYTES:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
            size += len(chunk)
        raise Refused("save_failed", reason="TooLarge")
    finally:
        os.close(fd)


def skill_name(hermes, current, segments):
    """A skill's current name: the front matter's, else its directory's, as hermes falls back."""
    if current is not None:
        name = hermes.parse_frontmatter(current.decode("utf-8", "replace"))[0].get("name")
        if name:
            return str(name)
    return segments[-2]


def lock(hermes, kind, path, segments):
    from pathlib import Path

    if kind in ("memory", "user"):
        return hermes.memory_lock(Path(path))
    if kind == "skill":
        # Hermes locks a skill by the name it was called with: the directory's,
        # the front matter's, or that as its listing cuts it. Hold them all.
        names = {segments[-2], skill_name(hermes, read_current(path), segments)}
        alias = hermes.read_skill_name(Path(path))
        if alias:
            names.add(alias)
        return hermes.skill_locks(sorted(names))
    return contextlib.nullcontext()  # SOUL.md has no lock


def check_text(hermes, job, current, segments):
    kind, text, limit = job["kind"], job.get("text"), job["limit"]
    if not isinstance(text, str) or "\0" in text:
        raise Refused("invalid_text")
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        raise Refused("invalid_text")
    if len(text) > limit:
        raise Refused("too_long", limit=limit)
    if kind == "soul" and not text.strip():
        raise Refused("empty_soul")
    if kind in ("memory", "user"):
        # Hermes replaces a match with a [BLOCKED] notice when it loads the file.
        for entry in hermes.parse_entries(text):
            if hermes.scan_entry(entry):
                raise Refused("blocked_entry", entry=entry[:60])
    if kind == "skill":
        if hermes.validate_skill(text):
            raise Refused("invalid_skill")
        new = hermes.parse_frontmatter(text)[0].get("name")
        if str(new) != skill_name(hermes, current, segments):
            raise Refused("invalid_skill")


def save(hermes, job):
    home = os.environ["HERMES_HOME"]
    segments = job["target"]
    kind = job["kind"]
    path = target_path(home, segments)

    with lock(hermes, kind, path, segments):
        current = read_current(path)
        check_text(hermes, job, current, segments)

        # Only memory files may be created: a skill or SOUL.md that is gone was
        # removed since the page read it.
        sha = None if current is None else hashlib.sha256(current).hexdigest()
        if sha != job.get("base_sha256") or (current is None and kind not in ("memory", "user")):
            raise Refused("file_changed")

        if current is not None:
            hermes.write_bytes(path + ".panel-bak", current, tmp_prefix=".panel_", mode=0o600)

        data = job["text"].encode("utf-8")
        hermes.write_text(path, job["text"], tmp_prefix=".panel_", preserve_mode=True, create_mode=0o600)
        mtime = os.lstat(path).st_mtime

    return {
        "sha256": hashlib.sha256(data).hexdigest(),
        "modified_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(mtime)),
    }


def run(argv):
    hermes = Hermes()
    if argv[1:] == ["--check"]:
        if hermes.fcntl is None:
            raise Refused("save_failed")
        return {"ok": True}
    if len(argv) != 2:
        raise Refused("save_failed")
    return save(hermes, read_job(argv[1]))


def main(argv):
    # The answer is the only output: hermes's imports may log or warn, and
    # druzhok-ctl exec merges stderr into stdout.
    out = os.dup(1)
    quiet = os.open(os.devnull, os.O_WRONLY)
    os.dup2(quiet, 1)
    os.dup2(quiet, 2)
    try:
        reply = run(argv)
    except Refused as refused:
        reply = refused.reply
    except BaseException as err:
        # The class only, for druzhok's log: a message could quote the text.
        reply = {"error": "save_failed", "reason": type(err).__name__}
    os.write(out, (json.dumps(reply) + "\n").encode("ascii"))
    # No exit handlers: nothing of hermes's should run after the answer.
    os._exit(0)


if __name__ == "__main__":
    main(sys.argv)
