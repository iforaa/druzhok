"""One-off: publish the sites a bot already has in workspace/sites through the
site API. Run as the bot's uid by ops/publish-existing-sites.sh, which passes this
file's text to `druzhok-ctl exec <bot> python3 -I -c`, so the cwd is the bot's
workspace and FIRECRAWL_API_URL / FIRECRAWL_API_KEY come from its env file.

Without --apply it only reports. What druzhok's old site plug kept private (names
starting with "." or "_", symlinks) stays out of the archive; a site with no
index.html, or past the limits, is reported and not sent. One line per site; the
exit code is 1 when any site failed or was not sendable.
"""
import json
import os
import re
import stat
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request

SITE_NAME = re.compile(r"\A[a-z0-9][a-z0-9-]{0,49}\Z")
MAX_BYTES = 50 * 1024 * 1024
MAX_FILES = 100
UPLOAD_TIMEOUT_S = 600


def collect(root):
    """(files, skipped): files as (archive name, full path, size), never following a link."""
    files, skipped = [], 0
    for parent, dirs, names in os.walk(root, followlinks=False):
        kept = []
        for d in dirs:
            if d.startswith((".", "_")) or os.path.islink(os.path.join(parent, d)):
                skipped += 1
            else:
                kept.append(d)
        dirs[:] = kept
        for name in names:
            full = os.path.join(parent, name)
            info = os.lstat(full)
            if name.startswith((".", "_")) or not stat.S_ISREG(info.st_mode):
                skipped += 1
            else:
                files.append((os.path.relpath(full, root), full, info.st_size))
    files.sort()
    return files, skipped


def why_not(name, root, files):
    if not SITE_NAME.match(name):
        return "bad_name"
    if os.path.islink(root) or not os.path.isdir(root):
        return "not_a_directory"
    if not any(rel == "index.html" for rel, _, _ in files):
        return "no_index_html"
    if len(files) > MAX_FILES or sum(size for _, _, size in files) > MAX_BYTES:
        return "too_large"
    return None


def archive(files, out):
    with tarfile.open(fileobj=out, mode="w:gz") as tar:
        for rel, full, _ in files:
            fd = os.open(full, os.O_RDONLY | os.O_NOFOLLOW)
            with os.fdopen(fd, "rb") as f:
                info = tarfile.TarInfo(rel)
                info.size = os.fstat(f.fileno()).st_size
                info.mode = 0o644
                tar.addfile(info, f)


def publish(name, files):
    base = os.environ["FIRECRAWL_API_URL"].rstrip("/")
    key = os.environ["FIRECRAWL_API_KEY"]
    try:
        # In the workspace, on /data: the root filesystem here is small.
        with tempfile.TemporaryFile(dir=".") as out:
            archive(files, out)
            length = out.tell()
            out.seek(0)
            request = urllib.request.Request(
                f"{base}/v2/sites/{name}",
                data=out,
                method="PUT",
                headers={
                    "Authorization": f"Bearer {key}",
                    "Content-Type": "application/gzip",
                    "Content-Length": str(length),
                },
            )
            with urllib.request.urlopen(request, timeout=UPLOAD_TIMEOUT_S) as reply:
                return True, json.load(reply).get("url", "?")
    except urllib.error.HTTPError as err:
        try:
            return False, str(json.load(err).get("error", err.code))
        except ValueError:
            return False, f"HTTP {err.code}"
    except (OSError, tarfile.TarError) as err:
        return False, type(err).__name__


def main(apply):
    # The old plug served nothing through a linked sites dir, so nothing goes from one.
    if os.path.islink("sites"):
        print("  sites is a symlink: NOT SENDABLE")
        return 1
    if not os.path.isdir("sites"):
        print("  no sites")
        return 0
    failed = 0
    for name in sorted(os.listdir("sites")):
        root = os.path.join("sites", name)
        if name.startswith((".", "_")):
            continue
        try:
            files, skipped = ([], 0) if os.path.islink(root) else collect(root)
        except OSError as err:
            print(f"  {name}: NOT SENDABLE {type(err).__name__}")
            failed += 1
            continue
        reason = why_not(name, root, files)
        note = f"{len(files)} files, {sum(s for _, _, s in files)} bytes, {skipped} left out"
        if reason:
            print(f"  {name}: NOT SENDABLE {reason} ({note})")
            failed += 1
        elif not apply:
            print(f"  {name}: would publish ({note})")
        else:
            ok, detail = publish(name, files)
            print(f"  {name}: {'published ' if ok else 'FAILED '}{detail} ({note})")
            failed += 0 if ok else 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main("--apply" in sys.argv[1:]))
