"""Round trip against the real model. Run: .embed-venv/bin/python apps/druzhok/priv/embed-worker/test_worker.py .embed-model"""
import json
import math
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def start(model_dir):
    return subprocess.Popen([sys.executable, os.path.join(HERE, "worker.py"), model_dir],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def call(proc, obj):
    payload = json.dumps(obj).encode()
    proc.stdin.write(struct.pack(">I", len(payload)) + payload)
    proc.stdin.flush()
    (n,) = struct.unpack(">I", proc.stdout.read(4))
    return json.loads(proc.stdout.read(n))


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))


def main(model_dir):
    proc = start(model_dir)
    r = call(proc, {"texts": ["query: кошка", "passage: кот сидит на окне", "passage: квартальная бухгалтерская отчётность"]})
    vecs, tokens = r["vectors"], r["tokens"]
    assert len(vecs) == 3 and all(len(v) == 384 for v in vecs), "dim"
    assert all(abs(math.sqrt(cos(v, v)) - 1) < 1e-3 for v in vecs), "unit norm"
    assert tokens > 6, tokens
    assert cos(vecs[0], vecs[1]) > cos(vecs[0], vecs[2]), "cat closer than accounting"

    long = "passage: " + "слово " * 3000
    r = call(proc, {"texts": [long]})
    assert r["tokens"] == 512, r["tokens"]

    r = call(proc, {"texts": []})
    assert r == {"vectors": [], "tokens": 0}, r

    r = call(proc, {"texts": [123]})
    assert r == {"error": "embed_failed"}, r

    proc.stdin.close()
    assert proc.wait(timeout=10) == 0
    print("ok")


if __name__ == "__main__":
    main(sys.argv[1])
