#!/usr/bin/env python3
"""Lets Mnemosyne send the tenant key to druzhok's proxy on 127.0.0.1.

Mnemosyne 4 refuses any credentialed embedding call that is not https, loopback
included, and has no setting for it: recall silently drops to keyword-only and new
rows get no vectors. Bots may only reach the proxy on loopback (nftables), so https
is not an option. Run after every `uv sync` of a hermes install; safe to rerun.

usage: patch-mnemosyne.py [--verify] <hermes install dir>
"""
import glob
import os
import py_compile
import sys

OLD = '''    return bool(_OPENAI_API_KEY) and not base_url.startswith("https://")
'''
NEW = '''    # Druzhok: loopback never leaves the machine (ops/patch-mnemosyne.py).
    from urllib.parse import urlsplit
    if urlsplit(base_url).hostname in ("127.0.0.1", "localhost", "::1"):
        return False
    return bool(_OPENAI_API_KEY) and not base_url.startswith("https://")
'''


def main(install, verify=False):
    found = glob.glob(os.path.join(
        install, ".venv/lib/python*/site-packages/mnemosyne/core/embeddings.py"))
    if len(found) != 1:
        sys.exit(f"expected one embeddings.py below {install}, found {len(found)}")
    path = found[0]
    with open(path, encoding="utf-8") as f:
        source = f.read()
    if verify:
        if NEW not in source:
            sys.exit(f"{path} is not patched: run ops/patch-mnemosyne.py")
        print("patched")
        return
    if NEW in source:
        print("already patched")
    elif source.count(OLD) == 1:
        with open(path, "w", encoding="utf-8") as f:
            f.write(source.replace(OLD, NEW))
        print("patched")
    else:
        sys.exit("the check changed upstream: read it and update this patch")
    # Bots cannot write __pycache__.
    py_compile.compile(path, doraise=True)


if __name__ == "__main__":
    main(sys.argv[-1], verify="--verify" in sys.argv[1:-1])
